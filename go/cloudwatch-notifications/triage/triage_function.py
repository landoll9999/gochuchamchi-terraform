"""GuardDuty finding AI 트리아지 — 필터 → 판정 → 정책 → 알림.

    GuardDuty finding
        │
        │  1. 기본 필터링 (무료. 여기서 걸리면 Groq 호출조차 없다)
        │     - 중복 finding      GuardDuty는 같은 사건을 count 올리며 재발행한다
        │     - 테스트/점검 IP    우리 스캐너를 위협으로 알리지 않는다
        │     - 명확한 LOW        AI 없이 저장만 (GuardDuty에 90일 남는다)
        │     - 판정 캐시         같은 타입 × 같은 리소스는 판정을 재사용
        │     - 일일 호출 상한
        │
        │  2. 화이트리스트 투영 + 마스킹 → Groq (judge.py)
        │
        │  3. 정책 엔진 (policy.py) — (심각도 × 판정) → 액션
        │
        └─→ SNS 허브 → Discord / 이메일

왜 이 순서인가
    필터가 앞에 있어야 비용이 성립한다. 판정은 finding 건당 호출이고, 필터에
    걸린 건 호출조차 없다. 멘토가 지적한 "전량 분석 시 토큰 비용"에 대한 답이
    이 배치다. **원시 로그는 이 파일 어디에서도 모델로 가지 않는다** — 탐지는
    GuardDuty가 이미 끝냈고 여기는 판단만 한다.

타협하지 않은 것

    ① AI에게 억제 권한을 주지 않는다.
       finding 원본은 GuardDuty에 그대로 남고, 바뀌는 것은 Discord 알림의
       우선순위와 설명뿐이다. 알림이 사라지는 칸은 정책 표에서 단 하나
       (MEDIUM × FALSE_POSITIVE)이고, 그것도 confidence 하한을 통과해야 한다.

    ② 판정 실패는 침묵이 아니다.
       Groq 장애·타임아웃·한도 초과·스키마 위반 — 어느 경로로 빠져도
       verdict=None이 되고 정책 엔진이 UNCERTAIN으로 처리해 알림을 낸다.
       "AI 판정 없음"이 Discord에 그대로 표시된다.

    ③ 대응 경로와 섞이지 않는다.
       EC2 격리는 별도 EventBridge 룰이 Lambda를 직접 호출한다(guardduty-
       response.tf). 대응이 모델 지연·장애·오판에 걸리면 안 되기 때문이다.
       이 파일은 통보 경로에만 있다.
"""

import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

import judge as judge_module
import policy as policy_module

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

REGION = os.environ.get("AWS_REGION", "ap-northeast-2")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
STATE_TABLE_NAME = os.environ["STATE_TABLE_NAME"]

# 판정 provider 가 groq 만이 아니게 된 뒤로 GROQ_ 접두사가 거짓말이 됐다
# (TRIAGE_PROVIDER=anthropic 인데 키를 GROQ_SECRET_ARN 에서 읽는 모양이 된다).
# judge.py 와 같은 이유로 TRIAGE_* 를 우선 읽고 옛 이름으로 물러선다 — 코드가
# 먼저 배포되고 Terraform 이 나중에 환경변수를 바꾸는 구간에도 살아 있어야 한다.
#
# 시크릿 자체의 이름(gochuchamchi/triage/groq-api-key)은 바꾸지 않았다.
# 이름을 바꾸면 리소스가 재생성되는데, 삭제된 시크릿 이름은 복구 대기창
# (recovery_window_in_days=7) 동안 재사용할 수 없어 전환이 7일 막힌다.
SECRET_ARN = os.environ.get("TRIAGE_SECRET_ARN") or os.environ.get("GROQ_SECRET_ARN", "")
SECRET_KEY = os.environ.get("TRIAGE_SECRET_KEY") or os.environ.get("GROQ_SECRET_KEY", "api_key")

JUDGE_ENABLED = os.environ.get("JUDGE_ENABLED", "true").lower() == "true"
STRICT_MASKING = os.environ.get("STRICT_MASKING", "false").lower() == "true"

POLICY_MATRIX = json.loads(os.environ.get("POLICY_MATRIX", "{}"))
ALWAYS_NOTIFY_PREFIXES = json.loads(os.environ.get("ALWAYS_NOTIFY_PREFIXES", "[]"))
TYPE_PREFIX_MIN_TIER = os.environ.get("TYPE_PREFIX_MIN_TIER", "HIGH")
SUPPRESS_MIN_CONFIDENCE = float(os.environ.get("SUPPRESS_MIN_CONFIDENCE", "0.7"))
SKIP_JUDGE_TIERS = set(json.loads(os.environ.get("SKIP_JUDGE_TIERS", '["LOW"]')))

DEDUP_HOURS = int(os.environ.get("DEDUP_HOURS", "6"))
VERDICT_CACHE_HOURS = int(os.environ.get("VERDICT_CACHE_HOURS", "6"))
DAILY_CALL_LIMIT = int(os.environ.get("DAILY_CALL_LIMIT", "300"))
TEST_IPS = set(json.loads(os.environ.get("TEST_IPS", "[]")))

METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "Gochuchamchi/Triage")

_BOTO_CONFIG = Config(retries={"max_attempts": 5, "mode": "standard"})

sns = boto3.client("sns", region_name=REGION, config=_BOTO_CONFIG)
cloudwatch = boto3.client("cloudwatch", region_name=REGION, config=_BOTO_CONFIG)
dynamodb = boto3.resource("dynamodb", region_name=REGION, config=_BOTO_CONFIG)
secretsmanager = boto3.client("secretsmanager", region_name=REGION, config=_BOTO_CONFIG)

_api_key = None


def judge_api_key():
    """콜드 스타트 때 한 번만 읽는다. 값은 로그에 절대 남기지 않는다."""
    global _api_key
    if _api_key is not None:
        return _api_key

    if not SECRET_ARN:
        _api_key = ""
        return _api_key

    try:
        raw = secretsmanager.get_secret_value(SecretId=SECRET_ARN)["SecretString"].strip()
        _api_key = json.loads(raw)[SECRET_KEY] if raw.startswith("{") else raw
    except (ClientError, ValueError, KeyError) as error:
        # 키가 없어도 알림은 계속된다. 판정만 "판정 없음"이 된다.
        LOG.warning("판정 API 키를 읽지 못했습니다(판정 없이 진행): %s", error)
        _api_key = ""

    return _api_key


# ---------------------------------------------------------------------------
# 지표
# ---------------------------------------------------------------------------

def metric(name, value, unit="Count", **dimensions):
    datum = {"MetricName": name, "Value": value, "Unit": unit}
    if dimensions:
        datum["Dimensions"] = [
            {"Name": key, "Value": str(dim_value)}
            for key, dim_value in dimensions.items()
            if dim_value
        ]
    return datum


def put_metrics(metrics):
    if not metrics:
        return
    try:
        for offset in range(0, len(metrics), 20):
            cloudwatch.put_metric_data(Namespace=METRIC_NAMESPACE, MetricData=metrics[offset:offset + 20])
    except ClientError as error:
        # 지표 실패가 알림을 막지는 않는다
        LOG.warning("지표 기록 실패: %s", error)


# ---------------------------------------------------------------------------
# 상태 (중복 억제 / 판정 캐시 / 호출 상한)
# ---------------------------------------------------------------------------

def resource_key(detail):
    """판정 캐시의 단위. 같은 타입이 같은 리소스에 또 떴으면 판단도 같다."""
    resource = detail.get("resource") or {}
    return (
        (resource.get("instanceDetails") or {}).get("instanceId")
        or (resource.get("accessKeyDetails") or {}).get("userName")
        or ((resource.get("s3BucketDetails") or [{}])[0] or {}).get("name")
        or (resource.get("eksClusterDetails") or {}).get("name")
        or resource.get("resourceType")
        or "-"
    )


def claim_once(table, key, now_epoch, window_hours):
    """처음 보는(또는 창이 지난) 키면 True.

    TTL 삭제는 최대 48시간 지연될 수 있어 "항목이 있다"만으로는 판단할 수 없다.
    그래서 seen_at 비교를 조건식에 같이 건다.
    """
    cutoff = now_epoch - window_hours * 3600

    try:
        table.put_item(
            Item={
                "state_key": key,
                "seen_at": now_epoch,
                "expires_at": now_epoch + window_hours * 3600 + 86400,
            },
            ConditionExpression="attribute_not_exists(state_key) OR seen_at < :cutoff",
            ExpressionAttributeValues={":cutoff": cutoff},
        )
        return True
    except ClientError as error:
        if error.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def read_cached_verdict(table, key):
    try:
        item = table.get_item(Key={"state_key": key}).get("Item")
    except ClientError as error:
        LOG.warning("판정 캐시 조회 실패(캐시 없이 진행): %s", error)
        return None

    if not item or "verdict_json" not in item:
        return None
    if int(item.get("expires_at", 0)) <= int(time.time()):
        return None

    try:
        return json.loads(item["verdict_json"])
    except ValueError:
        return None


def write_cached_verdict(table, key, verdict, now_epoch):
    try:
        table.put_item(Item={
            "state_key": key,
            "seen_at": now_epoch,
            "expires_at": now_epoch + VERDICT_CACHE_HOURS * 3600,
            "verdict_json": json.dumps(verdict, ensure_ascii=False),
        })
    except ClientError as error:
        LOG.warning("판정 캐시 기록 실패(무시): %s", error)


def consume_quota(table, now_epoch):
    """오늘 판정 호출 수를 원자적으로 올리고 한도 안인지 돌려준다.

    무료 티어에서 429를 맞기 전에 우리가 먼저 멈춘다. 한도를 넘겨도 **알림은
    계속 나간다** — 상한이 통보를 끄는 게 아니라 설명을 끄는 것이다.
    """
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    try:
        response = table.update_item(
            Key={"state_key": f"quota#{day}"},
            UpdateExpression="SET expires_at = if_not_exists(expires_at, :ttl) ADD calls :one",
            ExpressionAttributeValues={":one": 1, ":ttl": now_epoch + 172800},
            ReturnValues="UPDATED_NEW",
        )
        return int(response["Attributes"]["calls"]) <= DAILY_CALL_LIMIT
    except ClientError as error:
        # 카운터가 고장 났다고 판정을 막지 않는다. 상한은 비용 안전장치이지
        # 정확성 요건이 아니다.
        LOG.warning("호출 상한 카운터 갱신 실패(판정은 진행): %s", error)
        return True


# ---------------------------------------------------------------------------
# 기본 필터링
# ---------------------------------------------------------------------------

def remote_ip(detail):
    action = ((detail.get("service") or {}).get("action") or {})
    for key in ("awsApiCallAction", "networkConnectionAction"):
        ip = ((action.get(key) or {}).get("remoteIpDetails") or {}).get("ipAddressV4")
        if ip:
            return ip

    for probe in ((action.get("portProbeAction") or {}).get("portProbeDetails") or []):
        ip = (probe.get("remoteIpDetails") or {}).get("ipAddressV4")
        if ip:
            return ip

    return None


def prefilter(detail, table, now_epoch, tier):
    """(통과 여부, 사유). 통과 못 하면 Groq 호출도 알림도 없다."""
    finding_id = detail.get("id", "")

    # --- 테스트/점검 IP ------------------------------------------------------
    # 우리가 돌린 스캐너를 위협으로 알리면 알림 신뢰도가 먼저 무너진다.
    source_ip = remote_ip(detail)
    if source_ip and source_ip in TEST_IPS:
        return False, f"테스트/점검 IP({source_ip})에서 발생"

    # --- 중복 finding --------------------------------------------------------
    # GuardDuty는 같은 사건을 count를 올리며 반복 발행한다. 매번 알리면
    # 한 사건으로 알림이 수십 번 온다.
    if not claim_once(table, f"finding#{finding_id}", now_epoch, DEDUP_HOURS):
        return False, f"중복 finding (최근 {DEDUP_HOURS}시간 내 동일 id 통보됨)"

    # --- 명확한 LOW ----------------------------------------------------------
    # 여기서 걸러도 증거는 안 사라진다. GuardDuty가 90일 보관하고,
    # Security Hub를 켜면 거기에도 남는다. 새로 만들 저장소가 없다.
    #
    # ⚠️ 이 tier는 severity가 아니라 policy.effective_tier가 계산한 값이다.
    #    루트 사용·자격증명 탈취 같은 타입은 severity가 낮아도 HIGH로 올라오므로
    #    여기서 안 걸린다. severity만 봤다면 이 환경에서 가장 중요한 finding이
    #    전부 여기서 잘렸을 것이다(2026-08-12-ai-triage.md §5).
    if tier in SKIP_JUDGE_TIERS:
        return False, f"{tier} 등급 — 판정 없이 저장만 (GuardDuty에 보관됨)"

    return True, ""


# ---------------------------------------------------------------------------
# 알림
# ---------------------------------------------------------------------------

def console_url(detail):
    region = detail.get("region") or REGION
    return (
        f"https://{region}.console.aws.amazon.com/guardduty/home"
        f"?region={region}#/findings?macros=current&fId={detail.get('id', '')}"
    )


def publish(detail, decision, verdict, judged_from):
    payload = {
        # Discord Lambda의 route_event가 source로 렌더러를 고른다
        # (lambda_function.py). 기존 발행자들과 같은 관용구를 쓴다.
        "source": "gochuchamchi.triage",
        "action": decision["action"],
        "label": decision["label"],
        "icon": decision["icon"],
        "color": decision["color"],
        "tier": decision["tier"],
        "verdict_demoted": decision["verdict_demoted"],

        "finding": {
            "id": detail.get("id"),
            "type": detail.get("type"),
            "title": detail.get("title"),
            "description": detail.get("description"),
            "severity": detail.get("severity"),
            "account": detail.get("accountId"),
            "region": detail.get("region"),
            "count": (detail.get("service") or {}).get("count"),
            "resource": resource_key(detail),
            "remote_ip": remote_ip(detail),
        },

        "verdict": verdict,
        "judged_from": judged_from,
        "console_url": console_url(detail),
        "detected_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }

    # SNS Subject는 ASCII만 허용한다(한글을 넣으면 발행이 거부된다).
    # 본문(JSON)이 진짜 내용이고 Subject는 이메일 목록에서 훑기 위한 것이다.
    subject = (
        f"[GuardDuty][{decision['tier']}] {detail.get('type', 'finding')} "
        f"- {decision['action']}"
    )
    subject = subject.encode("ascii", "ignore").decode("ascii").strip()[:99] or "GuardDuty finding"

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=json.dumps(payload, ensure_ascii=False, default=str),
    )


# ---------------------------------------------------------------------------
# 본체
# ---------------------------------------------------------------------------

def lambda_handler(event, context):  # noqa: ARG001
    detail = event.get("detail") or {}
    finding_type = detail.get("type", "")
    finding_id = detail.get("id", "")

    if not finding_id:
        LOG.error("finding id가 없는 이벤트입니다. 무시합니다: %s", json.dumps(event)[:500])
        return {"status": "ignored", "reason": "no finding id"}

    now_epoch = int(time.time())
    table = dynamodb.Table(STATE_TABLE_NAME)
    metrics = []

    # --- 티어 결정 -----------------------------------------------------------
    # severity만으로 정하지 않는다. 이유는 policy.py 상단 ②.
    tier = policy_module.effective_tier(
        detail.get("severity"), finding_type, ALWAYS_NOTIFY_PREFIXES, TYPE_PREFIX_MIN_TIER
    )

    # --- 1. 기본 필터링 -------------------------------------------------------
    passed, reason = prefilter(detail, table, now_epoch, tier)
    if not passed:
        LOG.info("[%s] 필터에서 제외: %s", finding_type, reason)
        put_metrics([
            metric("Filtered", 1, Tier=tier),
            metric("Received", 1, Tier=tier),
        ])
        return {"status": "filtered", "reason": reason, "tier": tier}

    # --- 2. 판정 -------------------------------------------------------------
    cache_key = f"verdict#{finding_type}#{resource_key(detail)}"
    verdict = None
    judged_from = ""

    if not JUDGE_ENABLED:
        verdict = judge_module.unjudged("판정 계층이 꺼져 있습니다 (JUDGE_ENABLED=false)")
        judged_from = "disabled"
    else:
        cached = read_cached_verdict(table, cache_key)
        if cached:
            verdict = cached
            judged_from = "cache"
            metrics.append(metric("JudgeCacheHit", 1))
        elif not consume_quota(table, now_epoch):
            verdict = judge_module.unjudged(f"일일 판정 호출 상한({DAILY_CALL_LIMIT}회)을 넘었습니다")
            judged_from = "quota-exceeded"
            metrics.append(metric("JudgeQuotaExceeded", 1))
        else:
            verdict = judge_module.judge(detail, judge_api_key(), strict_masking=STRICT_MASKING)
            judged_from = "model"
            metrics.append(metric("JudgeCalls", 1))

            if verdict.get("verdict"):
                write_cached_verdict(table, cache_key, verdict, now_epoch)
                metrics.append(metric("JudgeInputTokens", verdict.get("input_tokens", 0)))
                metrics.append(metric("JudgeOutputTokens", verdict.get("output_tokens", 0)))
            else:
                metrics.append(metric("JudgeUnavailable", 1))

    if verdict.get("injection_suspected"):
        metrics.append(metric("InjectionSuspected", 1, Type=finding_type))

    # --- 3. 정책 -------------------------------------------------------------
    decision = policy_module.decide(
        tier,
        verdict.get("verdict"),
        verdict.get("confidence", 0.0),
        POLICY_MATRIX,
        SUPPRESS_MIN_CONFIDENCE,
    )

    metrics.extend([
        metric("Received", 1, Tier=tier),
        metric("Verdict", 1, Verdict=decision["verdict_used"]),
        metric("Action", 1, Action=decision["action"]),
        metric("RiskScore", verdict.get("risk_score", 50), unit="None", Tier=tier),
    ])

    # --- 4. 판정 기록 --------------------------------------------------------
    # 통보 여부와 무관하게 **모든 finding의 판정을 한 줄로 남긴다.**
    #
    # 통보된 건의 판정 근거가 Discord에만 있으면, 메시지가 지워지거나 채널이
    # 바뀌는 순간 "그때 AI가 왜 그렇게 판단했나"에 답할 수 없다. 사고 조사에서
    # 그건 치명적이다. 로그 그룹은 30일 보존이고 Logs Insights로 질의된다.
    #
    # 접두사 triage_result 로 시작하는 JSON 한 줄 — 사람이 읽기보다 질의를
    # 전제로 한 형식이다:
    #   fields @timestamp, @message
    #   | filter @message like /triage_result/
    #   | parse @message 'triage_result *' as body
    LOG.info("triage_result %s", json.dumps({
        "finding_id": finding_id,
        "finding_type": finding_type,
        "severity": detail.get("severity"),
        "tier": tier,
        "resource": resource_key(detail),
        "remote_ip": remote_ip(detail),
        "action": decision["action"],
        "notified": decision["notify"],
        "judged_from": judged_from,
        "verdict": verdict.get("verdict"),
        "verdict_used": decision["verdict_used"],
        "verdict_demoted": decision["verdict_demoted"],
        "confidence": verdict.get("confidence"),
        "risk_score": verdict.get("risk_score"),
        "reason": verdict.get("reason"),
        "evidence": verdict.get("evidence"),
        "recommended_action": verdict.get("recommended_action"),
        "injection_suspected": verdict.get("injection_suspected"),
        "unavailable_reason": verdict.get("unavailable_reason"),
        "model": verdict.get("model"),
        "input_tokens": verdict.get("input_tokens"),
        "output_tokens": verdict.get("output_tokens"),
    }, ensure_ascii=False, default=str))

    # --- 5. 알림 -------------------------------------------------------------
    if decision["notify"]:
        publish(detail, decision, verdict, judged_from)
        metrics.append(metric("Notified", 1, Action=decision["action"]))
    else:
        # 억제돼도 증거는 안 사라진다 — 위 로그와 GuardDuty 원본이 남는다.
        metrics.append(metric("Suppressed", 1, Tier=tier))

    put_metrics(metrics)

    return {
        "status": "ok",
        "finding_type": finding_type,
        "tier": tier,
        "verdict": decision["verdict_used"],
        "verdict_demoted": decision["verdict_demoted"],
        "confidence": verdict.get("confidence", 0.0),
        "risk_score": verdict.get("risk_score"),
        "action": decision["action"],
        "notified": decision["notify"],
        "judged_from": judged_from,
    }
