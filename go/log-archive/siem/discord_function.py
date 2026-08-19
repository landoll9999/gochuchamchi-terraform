"""Log 계정 SIEM 알림 → Discord 렌더러.

Workload 계정의 cloudwatch-notifications/lambda_function.py와 형제 관계지만
별도 함수다. 두 계정 사이에 신뢰 경로를 만들지 않는다는 log-archive의 전제
(providers.tf 상단)를 지키기 위해, Log 계정에서 탐지한 것은 Log 계정 안에서
끝까지 처리한다.

받는 메시지는 세 종류다.
    siem-rule-hit      상관 룰이 새로 잡은 것 (detector_function.py)
    siem-operational   탐지 파이프라인 자체의 고장 (같은 곳)
    CloudWatch 알람    DLQ 적재 알람 등 — SNS가 알람 JSON을 그대로 넣는다

어느 것으로도 파싱되지 않으면 원문을 그대로 띄운다. 렌더러가 모르는 형식이라고
알림을 버리면 안 된다 — Workload 쪽에서 평문 SNS 메시지에 json.loads를 걸었다가
IAM 활동 알림이 통째로 DLQ로 가던 사고가 그 형태였다 (2026-08-12-ai-triage.md §3-1).
"""

import json
import logging
import os
import urllib.error
import urllib.request

import boto3

LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

DISCORD_SECRET_ARN = os.environ["DISCORD_SECRET_ARN"]
DISCORD_SECRET_KEY = os.environ.get("DISCORD_SECRET_KEY", "webhook_url")
REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

secretsmanager = boto3.client("secretsmanager", region_name=REGION)

SEVERITY_STYLE = {
    "CRITICAL": ("🔴", 0xE01E5A),
    "HIGH": ("🟠", 0xED8936),
    "MEDIUM": ("🟡", 0xECC94B),
    "LOW": ("⚪", 0xA0AEC0),
}
# 판정 결과는 심각도보다 우선해 색을 정한다 — 사람이 먼저 보는 것이 색이다
VERDICT_STYLE = {
    "threat": ("🔴", "실제 위협 의심", 0xE01E5A),
    "suspicious": ("🟡", "확인 필요", 0xECC94B),
    "benign": ("⚪", "정상 패턴으로 보임", 0xA0AEC0),
}

OPERATIONAL_COLOR = 0x9F7AEA
ALARM_COLOR = 0xE01E5A
ALARM_OK_COLOR = 0x48BB78

# Discord 제한: embed description 4096, field value 1024, 총 6000자
MAX_DESCRIPTION = 3800
MAX_FIELD_VALUE = 1000
MAX_CELL = 44

_webhook_url = None


def webhook_url():
    """콜드 스타트 때 한 번만 읽는다. 값은 로그에 절대 남기지 않는다."""
    global _webhook_url
    if _webhook_url:
        return _webhook_url

    raw = secretsmanager.get_secret_value(SecretId=DISCORD_SECRET_ARN)["SecretString"].strip()

    # 시크릿을 JSON({"webhook_url": "..."})으로 넣었든 URL 한 줄로 넣었든 받는다.
    if raw.startswith("{"):
        _webhook_url = json.loads(raw)[DISCORD_SECRET_KEY]
    else:
        _webhook_url = raw

    return _webhook_url


def truncate(text, limit):
    text = "" if text is None else str(text)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def render_table(columns, rows):
    """결과 행을 고정폭 표로. Discord는 코드블록 안에서만 정렬이 유지된다."""
    if not columns or not rows:
        return ""

    cells = [[truncate(value, MAX_CELL) for value in row] for row in rows]
    widths = [
        max(len(columns[index]), *(len(row[index]) if index < len(row) else 0 for row in cells))
        if cells else len(columns[index])
        for index in range(len(columns))
    ]

    def line(values):
        return " | ".join(
            truncate(values[index] if index < len(values) else "", MAX_CELL).ljust(widths[index])
            for index in range(len(columns))
        )

    lines = [line(columns), "-+-".join("-" * width for width in widths)]
    lines.extend(line(row) for row in cells)

    table = "\n".join(lines)
    # 표가 길면 행을 줄인다. 컬럼을 자르면 무슨 값인지 알 수 없게 된다.
    while len(table) > MAX_DESCRIPTION - 200 and len(lines) > 3:
        lines.pop()
        table = "\n".join(lines) + "\n… (이하 생략, Athena 링크에서 전체 확인)"

    return table


def embed_rule_hit(payload):
    severity = str(payload.get("severity", "MEDIUM")).upper()
    icon, color = SEVERITY_STYLE.get(severity, SEVERITY_STYLE["MEDIUM"])

    new_hits = payload.get("new_hits", 0)
    total_hits = payload.get("total_hits", new_hits)
    suppressed = payload.get("suppressed_hits", 0)
    verdict = payload.get("verdict") or {}

    description = []

    # 판정이 있으면 제일 위에 온다 — 새벽에 받은 사람이 첫 줄만 읽어도
    # 다음 행동을 정할 수 있어야 한다. 판정 색이 심각도 색을 덮는다.
    if verdict.get("verdict"):
        verdict_icon, verdict_label, verdict_color = VERDICT_STYLE.get(
            verdict["verdict"], VERDICT_STYLE["suspicious"]
        )
        color = verdict_color
        confidence = verdict.get("confidence", 0.0)
        description.append(f"### {verdict_icon} {verdict_label}  ·  확신 {confidence:.0%}")
        if verdict.get("summary"):
            description.append(truncate(verdict["summary"], 500))
        description.append("")

    if verdict.get("injection_suspected"):
        description.append(
            "⚠️ **로그 값에 프롬프트 인젝션 시도로 보이는 내용이 있습니다.** "
            "누군가 탐지 판정을 조작하려 했다는 뜻이므로, 룰 내용과 별개로 "
            "이 사실 자체를 침해 신호로 다루십시오."
        )
        description.append("")

    description.append(f"**{truncate(payload.get('why', ''), 700)}**")
    description.append("")

    table = render_table(payload.get("columns", []), payload.get("rows", []))
    if table:
        description.append(f"```\n{table}\n```")

    shown = payload.get("shown_rows", 0)
    if new_hits > shown:
        description.append(f"신규 {new_hits}건 중 상위 {shown}건만 표시했습니다.")

    fields = [
        {
            "name": "탐지 범위",
            "value": f"최근 {payload.get('lookback_minutes', '?')}분",
            "inline": True,
        },
        {
            "name": "신규 / 전체",
            "value": f"{new_hits}건 / {total_hits}건"
            + (f"\n(중복 억제 {suppressed}건)" if suppressed else ""),
            "inline": True,
        },
        {
            "name": "재알림 억제",
            "value": f"같은 대상 {payload.get('dedup_hours', '?')}시간",
            "inline": True,
        },
        {
            "name": "첫 확인",
            "value": truncate(
                f"[Athena 실행 결과]({payload.get('console_url', '')})\n"
                f"저장 쿼리: `{payload.get('rule_name', '')}`",
                MAX_FIELD_VALUE,
            ),
            "inline": False,
        },
    ]

    if verdict.get("reasoning"):
        fields.append({
            "name": "판정 근거",
            "value": truncate(verdict["reasoning"], MAX_FIELD_VALUE),
            "inline": False,
        })

    if verdict.get("recommended_action"):
        fields.append({
            "name": "권장 조치",
            "value": truncate(verdict["recommended_action"], MAX_FIELD_VALUE),
            "inline": False,
        })

    # 판정이 어디서 왔는지(또는 왜 없는지)를 항상 밝힌다. 판정 없이 온 알림을
    # "AI가 정상이라고 했다"로 오해하면 안 되기 때문이다.
    if verdict.get("verdict"):
        source = f"모델 판정 ({verdict.get('model', '?')})"
        if payload.get("always_alert"):
            source += "\n※ 이 룰은 판정과 무관하게 항상 통보됩니다"
    else:
        source = f"**판정 없음** — {verdict.get('unavailable_reason', '사유 미상')}\n판정이 없어 그대로 통보했습니다. 내용은 직접 확인하십시오."

    fields.append({"name": "판정 출처", "value": truncate(source, MAX_FIELD_VALUE), "inline": False})

    return {
        "title": truncate(f"{icon} [SEC][{severity}] {payload.get('title', payload.get('rule_id', 'SIEM'))}", 256),
        "description": truncate("\n".join(description), MAX_DESCRIPTION),
        "color": color,
        "fields": fields,
        "footer": {"text": f"SIEM 상관 탐지 · {payload.get('rule_id', '')} · Log 계정"},
        "timestamp": payload.get("detected_at"),
    }


def embed_operational(payload):
    """탐지가 멈춘 상태. 내용이 없는 알림이 아니라 '알림이 없는 이유'다."""
    fields = [
        {
            "name": "첫 확인",
            "value": "CloudWatch → SIEM Detector Lambda 로그·Athena 실행 상태",
            "inline": False,
        },
        {"name": "상세", "value": truncate(payload.get("detail", "-"), MAX_FIELD_VALUE), "inline": False}
    ]
    if payload.get("hint"):
        fields.append({"name": "확인할 것", "value": truncate(payload["hint"], MAX_FIELD_VALUE), "inline": False})

    return {
        "title": truncate(f"⚙️ [PIPELINE][P2] {payload.get('title', '탐지 파이프라인 고장')}", 256),
        "description": (
            "**탐지 자체가 정상 동작하지 않았습니다.** 이 시간대는 관제 공백으로 봐야 합니다."
        ),
        "color": OPERATIONAL_COLOR,
        "fields": fields,
        "footer": {"text": "SIEM 운영 알림 · Log 계정"},
        "timestamp": payload.get("detected_at"),
    }


def embed_cloudwatch_alarm(payload):
    is_alarm = payload.get("NewStateValue") == "ALARM"

    return {
        "title": truncate(
            f"{'🚨' if is_alarm else '✅'} [PIPELINE][P2] {payload.get('AlarmName', '이름 없음')}", 256
        ),
        "description": truncate(payload.get("AlarmDescription") or "설명 없음", MAX_DESCRIPTION),
        "color": ALARM_COLOR if is_alarm else ALARM_OK_COLOR,
        "fields": [
            {"name": "상태", "value": payload.get("NewStateValue", "-"), "inline": True},
            {"name": "계정", "value": payload.get("AWSAccountId", "-"), "inline": True},
            {
                "name": "첫 확인",
                "value": "CloudWatch → Lambda·SQS DLQ·마지막 정상 탐지 실행",
                "inline": False,
            },
            {
                "name": "권장 조치",
                "value": "관제 공백 여부를 확인하고 실패 메시지·권한·시크릿 상태를 점검하세요.",
                "inline": False,
            },
            {
                "name": "사유",
                "value": truncate(payload.get("NewStateReason", "-"), MAX_FIELD_VALUE),
                "inline": False,
            },
        ],
        "footer": {"text": "CloudWatch 알람 · Log 계정"},
    }


def embed_unknown(raw_message, subject):
    """모르는 형식이어도 버리지 않는다."""
    return {
        "title": truncate(f"📄 [UNCLASSIFIED][P3] {subject or 'SNS 메시지'}", 256),
        "description": truncate(f"```\n{raw_message}\n```", MAX_DESCRIPTION),
        "color": 0xA0AEC0,
        "footer": {"text": "미분류 메시지 · 렌더러 확인 필요 · Log 계정"},
    }


def build_embed(raw_message, subject):
    try:
        payload = json.loads(raw_message)
    except (ValueError, TypeError):
        return embed_unknown(raw_message, subject)

    if not isinstance(payload, dict):
        return embed_unknown(raw_message, subject)

    kind = payload.get("kind")
    if kind == "siem-rule-hit":
        return embed_rule_hit(payload)
    if kind == "siem-operational":
        return embed_operational(payload)
    if "AlarmName" in payload and "NewStateValue" in payload:
        return embed_cloudwatch_alarm(payload)

    return embed_unknown(raw_message, subject)


def post(embed):
    request = urllib.request.Request(
        webhook_url(),
        data=json.dumps({"embeds": [embed]}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status


def lambda_handler(event, context):  # noqa: ARG001
    delivered = 0

    for record in event.get("Records", []):
        sns_payload = record.get("Sns", {})
        embed = build_embed(sns_payload.get("Message", ""), sns_payload.get("Subject", ""))

        try:
            post(embed)
            delivered += 1
        except urllib.error.HTTPError as error:
            # 예외를 삼키면 SNS가 재시도하지 않아 알림이 조용히 사라진다.
            # 그대로 올려 SNS 재시도 → DLQ → DLQ 알람 경로를 타게 한다.
            LOG.error("Discord 전송 실패 status=%s body=%s", error.code, error.read()[:500])
            raise

    return {"delivered": delivered}
