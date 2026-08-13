"""SIEM 탐지 엔진 — 상관 룰을 주기 실행하고 새 히트만 알린다.

배선
    EventBridge (rate) → 이 Lambda → Athena → [Groq 판정] → SNS → Discord / 이메일

볼륨이 줄어드는 지점이 어디인지가 이 설계의 전부다
    원시 로그  하루 수십만 건
       ↓ Athena 상관 룰 — 여기서 볼륨을 잡는다. LLM 관여 없음
    후보      하루 수십 건
       ↓ Groq 판정 — 호출량이 후보 수에 비례하므로 무료 티어로 감당된다
    알림      진짜로 봐야 할 것

    룰이 앞에서 볼륨을 잡아 주지 않으면 어떤 모델을 써도 비용이 성립하지 않는다.
    원시 로그가 모델로 흘러가는 경로는 이 파일 어디에도 없다.

    그리고 룰이 뒤에 판정을 두는 덕에 **임계값을 재현율 우선으로 낮게** 잡을 수
    있다. 룰이 혼자 정확해야 했다면 못 잡았을 것까지 후보로 올린 뒤, 소음 제거는
    판정이 한다.

한 번의 실행이 하는 일
    1. 통합 뷰 두 장을 CREATE OR REPLACE 한다 (DDL이라 스캔 0바이트 = 무료).
       사람이 저장 쿼리를 손으로 돌리는 걸 잊어서 탐지가 죽는 경로를 없앤다.
    2. 등록된 룰 SQL을 전부 동시에 던진다.
    3. 결과 행마다 alert_key로 중복을 걸러, 처음 보는 것만 남긴다.
    4. 남은 후보에 판정을 붙인다 (siem/judge.py).
    5. 판정이 benign이고 확신이 높을 때만 알림을 생략하고, 나머지는 전부 SNS로.
    6. 지표를 남긴다 (히트 / 스캔 바이트 / 추정 비용 / 판정 결과 / 실패 / 실행 성공).

설계에서 타협하지 않은 것

    ① 룰 SQL을 이 파일에 두지 않는다.
       Terraform이 만든 Athena 저장 쿼리(named query)의 ID만 환경변수로 받고,
       SQL은 실행 시점에 읽는다. 그래서 콘솔에서 사람이 튜닝하려고 보는 쿼리와
       매시간 자동 실행되는 쿼리가 같은 문자열임이 구조적으로 보장된다.
       룰을 고치거나 추가할 때 이 Lambda를 다시 배포할 일이 없다.

    ② 탐지 실패는 반드시 시끄럽게 만든다.
       SIEM에서 제일 나쁜 고장은 "아무 알림도 안 오는데 사실은 안 돌고 있는 것"
       이다. 쿼리 실패·뷰 생성 실패·타임아웃은 전부 운영 알림으로 발행하고,
       실행 자체가 죽으면 DetectionRunSuccess 지표가 안 찍혀 알람이 뜬다.
       워크그룹의 스캔 상한(1 GiB)에 걸린 경우는 원인을 따로 짚어 준다 —
       이게 조용한 탐지 중단의 가장 흔한 원인이다.

    ③ 이 Lambda는 아무것도 차단하지 않는다.
       알림만 만든다. 자동 대응(격리·키 비활성화)은 GuardDuty 경로가 따로
       담당하고, 상관 룰은 오탐 가능성이 구조적으로 더 높기 때문에 대응 권한을
       주지 않는다.

    ④ 판정이 없어도 알림은 나간다.
       Groq 장애·타임아웃·일일 한도 초과·스키마 위반 — 어느 경로로 빠져도
       "판정 없음"을 붙여 발행한다. 모델 가용성이 탐지 가용성을 좌우하면 안 된다.
       always_alert 룰(권한 상승·감사 무력화)은 benign 판정이 와도 알린다.
"""

import json
import logging
import os
import re
import time
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

import judge as judge_module

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
ATHENA_WORKGROUP = os.environ["ATHENA_WORKGROUP"]
ATHENA_DATABASE = os.environ["ATHENA_DATABASE"]
ALERT_TOPIC_ARN = os.environ["ALERT_TOPIC_ARN"]
DEDUP_TABLE_NAME = os.environ["DEDUP_TABLE_NAME"]

# 룰 목록은 배포 패키지 안의 rules.json으로 받는다 (Terraform이 zip에 넣는다).
#   {"views": [named query id, ...],
#    "rules": [{id, name, severity, title, why, query_id}, ...]}
#
# 환경변수를 안 쓰는 이유: Lambda 환경변수는 전체 합계 4 KB 제한이고, 룰의
# why 문구가 한글이라 3바이트/자다. 룰이 몇 개만 늘어도 조용히 상한을 넘어
# 배포가 깨진다. 패키지 안에 두면 그 제약이 없고, 룰이 바뀌면 zip 해시가
# 바뀌어 Lambda가 자동으로 갱신된다.
with open(os.path.join(os.path.dirname(__file__), "rules.json"), encoding="utf-8") as manifest_file:
    _MANIFEST = json.load(manifest_file)

RULES = _MANIFEST.get("rules", [])
VIEW_QUERY_IDS = _MANIFEST.get("views", [])

DEDUP_HOURS = int(os.environ.get("DEDUP_HOURS", "6"))
LOOKBACK_MINUTES = int(os.environ.get("LOOKBACK_MINUTES", "75"))
MAX_ROWS_IN_ALERT = int(os.environ.get("MAX_ROWS_IN_ALERT", "10"))
QUERY_TIMEOUT_SECONDS = int(os.environ.get("QUERY_TIMEOUT_SECONDS", "240"))
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "Gochuchamchi/SIEM")

# Athena 정가($5/TB) 기준 추정치. 실제 청구는 Cost Explorer에서 확인할 것 —
# 이 지표는 "오늘 얼마나 태웠나"를 대시보드에서 감으로 잡는 용도다.
# (cloudwatch-notifications 쪽 EstimatedCostUsd와 같은 성격의 값)
ATHENA_PRICE_PER_TB_USD = float(os.environ.get("ATHENA_PRICE_PER_TB_USD", "5.0"))

# Athena는 최소 10 MB 단위로 과금한다
ATHENA_MIN_BILLED_BYTES = 10 * 1024 * 1024

# --- Groq 판정 계층 ---------------------------------------------------------
JUDGE_ENABLED = os.environ.get("JUDGE_ENABLED", "true").lower() == "true"
GROQ_SECRET_ARN = os.environ.get("GROQ_SECRET_ARN", "")
GROQ_SECRET_KEY = os.environ.get("GROQ_SECRET_KEY", "api_key")
JUDGE_STRICT_MASKING = os.environ.get("JUDGE_STRICT_MASKING", "false").lower() == "true"
# 무료 티어 한도를 넘겨 429를 맞기 전에 우리가 먼저 멈춘다. 한도에 걸린 뒤로는
# 판정 없이 알림만 나가므로 탐지에는 구멍이 안 생긴다.
JUDGE_DAILY_CALL_LIMIT = int(os.environ.get("JUDGE_DAILY_CALL_LIMIT", "300"))
# benign 판정으로 알림을 없애려면 이만큼의 확신이 있어야 한다. 낮추면 알림이
# 조용해지는 대신 모델 오판이 곧 미탐이 된다.
JUDGE_BENIGN_MIN_CONFIDENCE = float(os.environ.get("JUDGE_BENIGN_MIN_CONFIDENCE", "0.7"))

_BOTO_CONFIG = Config(retries={"max_attempts": 5, "mode": "standard"})

athena = boto3.client("athena", region_name=REGION, config=_BOTO_CONFIG)
sns = boto3.client("sns", region_name=REGION, config=_BOTO_CONFIG)
cloudwatch = boto3.client("cloudwatch", region_name=REGION, config=_BOTO_CONFIG)
dynamodb = boto3.resource("dynamodb", region_name=REGION, config=_BOTO_CONFIG)
secretsmanager = boto3.client("secretsmanager", region_name=REGION, config=_BOTO_CONFIG)

TERMINAL_STATES = ("SUCCEEDED", "FAILED", "CANCELLED")

_groq_api_key = None


def groq_api_key():
    """콜드 스타트 때 한 번만 읽는다. 값은 로그에 절대 남기지 않는다."""
    global _groq_api_key
    if _groq_api_key is not None:
        return _groq_api_key

    if not GROQ_SECRET_ARN:
        _groq_api_key = ""
        return _groq_api_key

    try:
        raw = secretsmanager.get_secret_value(SecretId=GROQ_SECRET_ARN)["SecretString"].strip()
        _groq_api_key = json.loads(raw)[GROQ_SECRET_KEY] if raw.startswith("{") else raw
    except (ClientError, ValueError, KeyError) as error:
        # 키가 없어도 탐지는 계속된다. 판정만 "판정 없음"이 된다.
        LOG.warning("Groq API 키를 읽지 못했습니다(판정 없이 진행): %s", error)
        _groq_api_key = ""

    return _groq_api_key


# ---------------------------------------------------------------------------
# Athena
# ---------------------------------------------------------------------------

def fetch_query_strings(query_ids):
    """named query ID → SQL 문자열. 50개씩 나눠 조회한다."""
    sql_by_id = {}
    unique_ids = [qid for qid in dict.fromkeys(query_ids) if qid]

    for offset in range(0, len(unique_ids), 50):
        chunk = unique_ids[offset:offset + 50]
        response = athena.batch_get_named_query(NamedQueryIds=chunk)

        for named_query in response.get("NamedQueries", []):
            # 저장 쿼리는 콘솔 실행을 전제로 세미콜론이 붙어 있을 수 있는데
            # start_query_execution은 이를 구문 오류로 본다.
            sql_by_id[named_query["NamedQueryId"]] = named_query["QueryString"].strip().rstrip(";")

        for missing in response.get("UnprocessedNamedQueryIds", []):
            LOG.error("named query 조회 실패: %s", missing)

    return sql_by_id


def start_query(sql):
    response = athena.start_query_execution(
        QueryString=sql,
        QueryExecutionContext={"Database": ATHENA_DATABASE},
        WorkGroup=ATHENA_WORKGROUP,
    )
    return response["QueryExecutionId"]


def wait_for_queries(execution_ids, timeout_seconds):
    """여러 쿼리를 한꺼번에 폴링한다. {execution_id: query_execution dict}"""
    pending = set(execution_ids)
    finished = {}
    deadline = time.monotonic() + timeout_seconds
    delay = 1.0

    while pending and time.monotonic() < deadline:
        batch = list(pending)[:50]
        response = athena.batch_get_query_execution(QueryExecutionIds=batch)

        for execution in response.get("QueryExecutions", []):
            state = execution["Status"]["State"]
            if state in TERMINAL_STATES:
                finished[execution["QueryExecutionId"]] = execution
                pending.discard(execution["QueryExecutionId"])

        if pending:
            time.sleep(delay)
            delay = min(delay * 1.5, 10.0)

    for execution_id in pending:
        LOG.error("쿼리 타임아웃: %s", execution_id)
        # 남은 쿼리는 결과를 못 쓰므로 취소해 비용을 끊는다
        try:
            athena.stop_query_execution(QueryExecutionId=execution_id)
        except ClientError as error:
            LOG.warning("쿼리 취소 실패 %s: %s", execution_id, error)

    return finished, pending


def read_rows(execution_id):
    """SELECT 결과를 (컬럼명 리스트, 행 리스트)로 반환. 첫 행은 헤더라 버린다."""
    # 룰은 전부 LIMIT 50이라 한 페이지로 끝난다. 1000은 Athena가 허용하는
    # 페이지 최대값 — 룰의 LIMIT를 올려도 조용히 잘리지 않게 여유를 둔다.
    response = athena.get_query_results(QueryExecutionId=execution_id, MaxResults=1000)

    metadata = response["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]
    columns = [column["Name"] for column in metadata]

    raw_rows = response["ResultSet"].get("Rows", [])
    rows = []
    for raw_row in raw_rows[1:]:
        rows.append([cell.get("VarCharValue") for cell in raw_row.get("Data", [])])

    return columns, rows


def failure_reason(execution):
    return execution.get("Status", {}).get("StateChangeReason", "(사유 없음)")


def scanned_bytes(execution):
    return execution.get("Statistics", {}).get("DataScannedInBytes", 0) or 0


# ---------------------------------------------------------------------------
# 중복 억제
# ---------------------------------------------------------------------------

def claim_alert_key(table, rule_id, alert_key, now_epoch):
    """처음 보는(또는 억제 기간이 지난) alert_key면 True.

    TTL 삭제는 최대 48시간까지 지연될 수 있어 "항목이 남아 있다"만으로는
    억제 여부를 판단할 수 없다. 그래서 alerted_at 비교를 조건식에 같이 건다.
    """
    cutoff = now_epoch - DEDUP_HOURS * 3600

    try:
        table.put_item(
            Item={
                "alert_key": f"{rule_id}#{alert_key}",
                "rule_id": rule_id,
                "alerted_at": now_epoch,
                # TTL은 억제 기간보다 하루 넉넉히 — 경계에서 항목이 먼저 사라져
                # 억제가 풀리는 일이 없게 한다.
                "expires_at": now_epoch + DEDUP_HOURS * 3600 + 86400,
            },
            ConditionExpression="attribute_not_exists(alert_key) OR alerted_at < :cutoff",
            ExpressionAttributeValues={":cutoff": cutoff},
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def consume_judge_quota(table, now_epoch):
    """오늘의 판정 호출 수를 원자적으로 올리고 한도 안인지 돌려준다.

    무료 티어에서 429를 맞기 전에 우리가 먼저 멈추기 위한 것이다. 한도를
    넘긴 뒤로는 판정 없이 알림만 나가므로 **탐지에는 구멍이 안 생긴다** —
    상한이 탐지를 끄는 게 아니라 설명을 끄는 것이다.
    """
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    try:
        response = table.update_item(
            Key={"alert_key": f"judge-quota#{day}"},
            UpdateExpression="SET expires_at = if_not_exists(expires_at, :ttl) ADD calls :one",
            ExpressionAttributeValues={":one": 1, ":ttl": now_epoch + 172800},
            ReturnValues="UPDATED_NEW",
        )
        return int(response["Attributes"]["calls"]) <= JUDGE_DAILY_CALL_LIMIT
    except ClientError as error:
        # 카운터가 고장 났다고 판정을 막지는 않는다. 상한은 비용 안전장치이지
        # 정확성 요건이 아니다.
        LOG.warning("판정 호출 카운터 갱신 실패(판정은 진행): %s", error)
        return True


def evaluate(rule, columns, rows, table, now_epoch, metrics):
    """후보에 판정을 붙인다. 어떤 경로로 실패해도 예외를 던지지 않는다."""
    if not JUDGE_ENABLED:
        return judge_module.unjudged("판정 계층이 꺼져 있습니다 (JUDGE_ENABLED=false)")

    if not consume_judge_quota(table, now_epoch):
        metrics.append(metric("JudgeQuotaExceeded", 1))
        return judge_module.unjudged(f"일일 판정 호출 상한({JUDGE_DAILY_CALL_LIMIT}회)을 넘었습니다")

    rule_for_judge = dict(rule)
    rule_for_judge["lookback_minutes"] = LOOKBACK_MINUTES

    verdict = judge_module.judge(
        rule_for_judge, columns, rows, groq_api_key(), strict_masking=JUDGE_STRICT_MASKING
    )

    metrics.append(metric("JudgeCalls", 1, RuleId=rule["id"]))

    if verdict.get("verdict"):
        metrics.append(metric("JudgeVerdict", 1, Verdict=verdict["verdict"]))
        metrics.append(metric("JudgeInputTokens", verdict.get("input_tokens", 0)))
        metrics.append(metric("JudgeOutputTokens", verdict.get("output_tokens", 0)))
        if verdict.get("injection_suspected"):
            metrics.append(metric("JudgeInjectionSuspected", 1, RuleId=rule["id"]))
    else:
        metrics.append(metric("JudgeUnavailable", 1, RuleId=rule["id"]))

    return verdict


def should_alert(rule, verdict):
    """알릴지 말지. 애매하면 무조건 알리는 쪽으로 기운다.

    benign 판정이 알림을 없애는 구조라, 여기 조건을 느슨하게 두면 모델 오판이
    그대로 미탐이 된다. 그래서 빠져나가는 문을 셋만 남겼다.
    """
    # ① always_alert 룰(권한 상승·감사 무력화 등)은 판정과 무관하게 통과
    if rule.get("always_alert"):
        return True

    # ② 판정을 못 붙였으면 알린다 — 모델 가용성이 탐지 가용성이 되면 안 된다
    if not verdict.get("verdict"):
        return True

    # ③ benign이어도 확신이 낮으면 알린다
    if verdict["verdict"] == "benign" and verdict.get("confidence", 0.0) >= JUDGE_BENIGN_MIN_CONFIDENCE:
        return False

    return True


# ---------------------------------------------------------------------------
# 알림
# ---------------------------------------------------------------------------

def console_url(execution_id):
    return (
        f"https://{REGION}.console.aws.amazon.com/athena/home"
        f"?region={REGION}#/query-editor/history/{execution_id}"
    )


def publish(payload, subject):
    # SNS Subject는 ASCII만 허용한다(한글을 넣으면 발행 자체가 거부된다).
    # 그래서 호출자가 처음부터 ASCII로 만들어 넘긴다 — 한글 제목을 넘기고
    # 여기서 깎으면 "[SIEM][OPERATIONAL]   1  " 처럼 뜻이 사라진 제목이 된다.
    # 본문(JSON)이 진짜 내용이고 Subject는 이메일 목록에서 훑기 위한 것이다.
    ascii_subject = subject.encode("ascii", "ignore").decode("ascii").strip()
    ascii_subject = re.sub(r"\s{2,}", " ", ascii_subject)[:99] or "SIEM alert"

    sns.publish(
        TopicArn=ALERT_TOPIC_ARN,
        Subject=ascii_subject,
        Message=json.dumps(payload, ensure_ascii=False, default=str),
    )


def publish_rule_hit(rule, columns, rows, total_rows, execution, execution_id, verdict):
    # alert_key는 중복 억제용 내부 값이라 사람이 볼 표에서는 뺀다.
    try:
        key_index = columns.index("alert_key")
    except ValueError:
        key_index = None

    display_columns = [name for index, name in enumerate(columns) if index != key_index]
    display_rows = [
        [value for index, value in enumerate(row) if index != key_index]
        for row in rows[:MAX_ROWS_IN_ALERT]
    ]

    publish(
        {
            "kind": "siem-rule-hit",
            "rule_id": rule["id"],
            "rule_name": rule["name"],
            "severity": rule["severity"],
            "title": rule["title"],
            "why": rule["why"],
            "lookback_minutes": LOOKBACK_MINUTES,
            "dedup_hours": DEDUP_HOURS,
            "detected_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "new_hits": len(rows),
            "total_hits": total_rows,
            "suppressed_hits": max(total_rows - len(rows), 0),
            "columns": display_columns,
            "rows": display_rows,
            "shown_rows": len(display_rows),
            "scanned_bytes": scanned_bytes(execution),
            "console_url": console_url(execution_id),
            # 판정은 설명이지 근거가 아니다. 룰이 왜 걸렸는지는 위의 표가
            # 그대로 말해 주고, 판정이 없어도 알림은 스스로 완결돼야 한다.
            "verdict": verdict,
            "always_alert": bool(rule.get("always_alert")),
        },
        f"[SIEM][{rule['severity']}] {rule['id']} - {len(rows)} new"
        + (f" - {verdict['verdict']}" if verdict.get("verdict") else " - unjudged"),
    )


def publish_operational(title, detail, hint="", subject="pipeline failure"):
    """탐지 파이프라인 자체의 고장. 이게 조용하면 SIEM이 있으나 마나다.

    title은 Discord용(한글), subject는 이메일 제목용(ASCII)으로 따로 받는다.
    """
    LOG.error("운영 알림: %s / %s", title, detail)

    publish(
        {
            "kind": "siem-operational",
            "severity": "HIGH",
            "title": title,
            "detail": detail,
            "hint": hint,
            "detected_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        },
        f"[SIEM][OPERATIONAL] {subject}",
    )


def scan_limit_hint(reason):
    """워크그룹 스캔 상한에 걸린 경우를 따로 짚어 준다."""
    lowered = reason.lower()
    if "bytes scanned" in lowered or "exhausted" in lowered:
        return (
            "워크그룹의 쿼리당 스캔 상한(athena.tf의 bytes_scanned_cutoff_per_query)에 "
            "걸렸을 가능성이 높습니다. security_events_detection_window_days를 줄이거나 "
            "룰의 lookback을 줄이세요. 이 상태를 방치하면 해당 룰은 조용히 탐지를 멈춥니다."
        )
    if "does not exist" in lowered or "not found" in lowered:
        return (
            "탐지용 뷰가 없습니다. 뷰 재생성 단계가 먼저 실패했는지 이 실행의 앞쪽 "
            "로그를 확인하세요."
        )
    return ""


# ---------------------------------------------------------------------------
# 지표
# ---------------------------------------------------------------------------

def put_metrics(metrics):
    if not metrics:
        return
    for offset in range(0, len(metrics), 20):
        cloudwatch.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=metrics[offset:offset + 20])


def metric(name, value, unit="Count", **dimensions):
    datum = {"MetricName": name, "Value": value, "Unit": unit}
    if dimensions:
        datum["Dimensions"] = [
            {"Name": key, "Value": str(dim_value)}
            for key, dim_value in dimensions.items()
            if dim_value
        ]
    return datum


# ---------------------------------------------------------------------------
# 본체
# ---------------------------------------------------------------------------

def lambda_handler(event, context):  # noqa: ARG001 - EventBridge 스케줄 페이로드는 쓰지 않는다
    started = time.monotonic()
    table = dynamodb.Table(DEDUP_TABLE_NAME)
    now_epoch = int(time.time())

    metrics = []
    total_scanned = 0
    failures = []

    sql_by_id = fetch_query_strings([rule["query_id"] for rule in RULES] + VIEW_QUERY_IDS)

    # --- 1. 통합 뷰 재생성 (DDL, 스캔 0바이트) -----------------------------
    view_execution_ids = []
    for query_id in VIEW_QUERY_IDS:
        sql = sql_by_id.get(query_id)
        if not sql:
            failures.append(f"뷰 정의 SQL을 읽지 못했습니다 (named query {query_id})")
            continue
        try:
            view_execution_ids.append(start_query(sql))
        except ClientError as error:
            failures.append(f"뷰 재생성 시작 실패 ({query_id}): {error}")

    if view_execution_ids:
        finished, timed_out = wait_for_queries(view_execution_ids, 90)
        for execution_id in view_execution_ids:
            execution = finished.get(execution_id)
            if execution is None:
                failures.append(f"뷰 재생성 타임아웃 ({execution_id})")
            elif execution["Status"]["State"] != "SUCCEEDED":
                failures.append(f"뷰 재생성 실패 ({execution_id}): {failure_reason(execution)}")

    # 뷰가 없으면 모든 룰이 줄줄이 실패한다. 여기서 끊고 원인을 하나로 보고한다.
    if failures:
        publish_operational(
            "탐지용 뷰 재생성 실패",
            " / ".join(failures),
            "Glue 테이블 스키마가 바뀌었거나 Lambda 실행 역할의 Glue 권한이 부족합니다. "
            "security-events-view.tf의 저장 쿼리를 콘솔에서 직접 실행해 오류 메시지를 확인하세요.",
            subject="view refresh failed - detection is down",
        )
        put_metrics([metric("RuleQueryFailures", len(failures)), metric("DetectionRunSuccess", 0)])
        return {"status": "view-refresh-failed", "failures": failures}

    # --- 2. 룰 동시 실행 ---------------------------------------------------
    execution_by_rule = {}
    for rule in RULES:
        sql = sql_by_id.get(rule["query_id"])
        if not sql:
            failures.append(f"[{rule['id']}] 룰 SQL을 읽지 못했습니다 (named query {rule['query_id']})")
            continue
        try:
            execution_by_rule[rule["id"]] = start_query(sql)
        except ClientError as error:
            failures.append(f"[{rule['id']}] 쿼리 시작 실패: {error}")

    finished, timed_out = wait_for_queries(list(execution_by_rule.values()), QUERY_TIMEOUT_SECONDS)

    # --- 3. 결과 처리 ------------------------------------------------------
    summary = {}

    for rule in RULES:
        execution_id = execution_by_rule.get(rule["id"])
        if execution_id is None:
            continue

        execution = finished.get(execution_id)

        if execution is None:
            failures.append(
                f"[{rule['id']}] 쿼리 타임아웃 ({QUERY_TIMEOUT_SECONDS}초). 실행 ID {execution_id}"
            )
            metrics.append(metric("RuleQueryFailures", 1, RuleId=rule["id"]))
            continue

        total_scanned += scanned_bytes(execution)
        metrics.append(metric("RuleScannedBytes", scanned_bytes(execution), unit="Bytes", RuleId=rule["id"]))

        state = execution["Status"]["State"]
        if state != "SUCCEEDED":
            reason = failure_reason(execution)
            failures.append(f"[{rule['id']}] 쿼리 {state}: {reason} | {console_url(execution_id)} {scan_limit_hint(reason)}")
            metrics.append(metric("RuleQueryFailures", 1, RuleId=rule["id"]))
            continue

        try:
            columns, rows = read_rows(execution_id)
        except ClientError as error:
            failures.append(f"[{rule['id']}] 결과 조회 실패: {error}")
            metrics.append(metric("RuleQueryFailures", 1, RuleId=rule["id"]))
            continue

        if "alert_key" not in columns:
            # 룰 계약 위반. 중복 억제를 걸 수 없으므로 알림 대신 운영 문제로 다룬다
            # (그냥 알려 버리면 매시간 같은 내용이 반복된다).
            failures.append(
                f"[{rule['id']}] 룰 결과에 alert_key 컬럼이 없습니다. "
                "siem-detection-rules.tf의 룰 계약 ①을 확인하세요."
            )
            metrics.append(metric("RuleQueryFailures", 1, RuleId=rule["id"]))
            continue

        key_index = columns.index("alert_key")
        new_rows = []
        for row in rows:
            alert_key = row[key_index] if key_index < len(row) else None
            if not alert_key:
                continue
            if claim_alert_key(table, rule["id"], alert_key, now_epoch):
                new_rows.append(row)

        metrics.append(metric("RuleFindings", len(rows), RuleId=rule["id"]))
        metrics.append(metric("RuleHits", len(new_rows), RuleId=rule["id"]))

        summary[rule["id"]] = {"findings": len(rows), "new": len(new_rows)}

        if not new_rows:
            continue

        verdict = evaluate(rule, columns, new_rows, table, now_epoch, metrics)
        summary[rule["id"]]["verdict"] = verdict.get("verdict") or "unjudged"

        if should_alert(rule, verdict):
            publish_rule_hit(rule, columns, new_rows, len(rows), execution, execution_id, verdict)
        else:
            # 알림만 생략한다. 원본은 Athena에 그대로 있고, 지표에 남으므로
            # "모델이 무엇을 걸러냈나"를 나중에 되짚을 수 있다.
            metrics.append(metric("SuppressedByJudge", len(new_rows), RuleId=rule["id"]))
            LOG.info(
                "[%s] benign(확신 %.2f) 판정으로 알림 생략: %s",
                rule["id"], verdict.get("confidence", 0.0), verdict.get("summary", ""),
            )

    # --- 4. 마무리: 운영 알림 + 지표 ---------------------------------------
    if failures:
        publish_operational(
            f"탐지 룰 {len(failures)}건 실행 실패",
            " / ".join(failures),
            "실패한 룰은 이번 주기 동안 탐지 공백입니다. 위 Athena 실행 링크에서 원인을 확인하세요.",
            subject=f"{len(failures)} rule(s) failed - detection gap",
        )

    billed_bytes = max(total_scanned, ATHENA_MIN_BILLED_BYTES) if total_scanned else 0
    estimated_cost = billed_bytes / (1024 ** 4) * ATHENA_PRICE_PER_TB_USD

    metrics.extend([
        metric("ScannedBytes", total_scanned, unit="Bytes"),
        metric("EstimatedCostUsd", estimated_cost, unit="None"),
        metric("RuleQueryFailures", len(failures)),
        metric("RulesEvaluated", len(execution_by_rule)),
        metric("DetectionRunSuccess", 0 if failures else 1),
        metric("DetectionRunSeconds", time.monotonic() - started, unit="Seconds"),
    ])
    put_metrics(metrics)

    LOG.info(
        "탐지 완료 rules=%d scanned=%dB cost=$%.4f failures=%d summary=%s",
        len(execution_by_rule), total_scanned, estimated_cost, len(failures), summary,
    )

    return {
        "status": "ok" if not failures else "partial",
        "rules_evaluated": len(execution_by_rule),
        "scanned_bytes": total_scanned,
        "estimated_cost_usd": round(estimated_cost, 6),
        "failures": failures,
        "summary": summary,
    }
