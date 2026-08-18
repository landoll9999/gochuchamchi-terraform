import json
import logging
import os
import urllib.error
import urllib.request
from typing import Any

import boto3


logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_manager = boto3.client("secretsmanager")

DISCORD_SECRET_ARN = os.environ["DISCORD_SECRET_ARN"]

# Lambda 실행 환경이 재사용되면 Secret을 다시 조회하지 않도록 캐시
_cached_webhook_url: str | None = None


def get_discord_webhook_url() -> str:
    """AWS Secrets Manager에서 Discord Webhook URL을 읽습니다."""
    global _cached_webhook_url

    if _cached_webhook_url:
        return _cached_webhook_url

    response = secrets_manager.get_secret_value(
        SecretId=DISCORD_SECRET_ARN
    )

    secret_string = response["SecretString"].strip()

    # 현재 저장한 것처럼 URL 문자열 자체가 들어 있는 경우
    if secret_string.startswith("https://"):
        webhook_url = secret_string

    # 나중에 {"webhook_url": "..."} 형식으로 바꾸는 경우도 지원
    else:
        secret_json = json.loads(secret_string)
        webhook_url = str(secret_json.get("webhook_url", "")).strip()

    if not webhook_url.startswith(
        (
            "https://discord.com/api/webhooks/",
            "https://discordapp.com/api/webhooks/",
        )
    ):
        raise ValueError("Secrets Manager의 Discord Webhook URL이 올바르지 않습니다.")

    _cached_webhook_url = webhook_url
    return webhook_url


def state_color(state: str) -> int:
    """Discord Embed 색상값을 반환합니다."""
    colors = {
        "ALARM": 15158332,
        "OK": 3066993,
        "INSUFFICIENT_DATA": 15844367,
    }

    return colors.get(state, 9807270)


def state_icon(state: str) -> str:
    icons = {
        "ALARM": "🚨",
        "OK": "✅",
        "INSUFFICIENT_DATA": "⚠️",
    }

    return icons.get(state, "ℹ️")


def trim_text(value: Any, limit: int = 1000) -> str:
    """Discord 필드 제한을 넘지 않도록 문자열을 자릅니다."""
    text = str(value or "-")

    if len(text) <= limit:
        return text

    return text[: limit - 3] + "..."


def send_discord_message(
    webhook_url: str,
    payload: dict[str, Any],
) -> None:
    encoded_payload = json.dumps(
        payload,
        ensure_ascii=False,
    ).encode("utf-8")

    request = urllib.request.Request(
        webhook_url,
        data=encoded_payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "gochuchamchi-cloudwatch-lambda",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=10,
        ) as response:
            logger.info(
                "Discord 메시지 전송 완료: HTTP %s",
                response.status,
            )

    except urllib.error.HTTPError as error:
        error_body = error.read().decode(
            "utf-8",
            errors="replace",
        )

        logger.error(
            "Discord HTTP 오류: status=%s body=%s",
            error.code,
            error_body,
        )

        raise

    except urllib.error.URLError:
        logger.exception("Discord 연결 오류")
        raise


def unwrap_events(event: dict[str, Any]) -> list[dict[str, Any]]:
    """수신 이벤트에서 EventBridge 원본 이벤트 목록을 꺼냅니다.

    - SNS 경유(현재 구조): Records[].Sns.Message 안에 EventBridge 이벤트가
      JSON 문자열로 들어 있음 -> 봉투를 벗겨서 반환
    - 직접 호출(콘솔 테스트/과거 구조): event 자체가 EventBridge 이벤트
      -> 그대로 반환. 두 형식을 모두 받아 전환·수동 테스트를 안전하게 함
    """
    if "Records" not in event:
        return [event]

    events: list[dict[str, Any]] = []

    for record in event["Records"]:
        if record.get("EventSource") != "aws:sns":
            continue

        message = record["Sns"]["Message"]

        try:
            events.append(json.loads(message))
        except json.JSONDecodeError:
            # 모든 발행자가 JSON을 보내는 건 아니다. iam-activity.tf의
            # input_transformer는 이메일 가독성을 위해 평문 여러 줄을 보내는데,
            # 예전 구현은 여기서 JSONDecodeError로 죽었다 → SNS 3회 재시도 →
            # DLQ 적재 → DLQ 알람. 이메일 구독자는 멀쩡히 받는데 Discord만
            # 조용히 실패하는, 알아채기 가장 어려운 형태의 고장이었다.
            # 평문은 평문대로 렌더링하도록 봉투를 씌워 넘긴다.
            events.append(
                {
                    "source": "gochuchamchi.plaintext",
                    "detail": {
                        "subject": record["Sns"].get("Subject") or "알림",
                        "message": message,
                    },
                }
            )

    return events


def lambda_handler(
    event: dict[str, Any],
    context: Any,
) -> dict[str, Any]:
    """SNS 허브가 전달한 CloudWatch Alarm 상태 변경 이벤트를 처리합니다."""
    logger.info(
        "수신 이벤트: %s",
        json.dumps(event, ensure_ascii=False),
    )

    results = []

    for bridge_event in unwrap_events(event):
        results.append(route_event(bridge_event))

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "message": "Discord notification sent",
                "alarms": results,
            },
            ensure_ascii=False,
        ),
    }


def route_event(event: dict[str, Any]) -> dict[str, Any]:
    """이벤트 source별로 렌더러를 분기합니다.

    SNS 허브에 소스가 늘면서(CloudWatch Alarm / GuardDuty / 격리 결과)
    하나의 Lambda가 여러 형식을 받는다. 렌더러 함수만 추가하면 채널
    확장이 되도록 라우팅을 한 곳에 모은다.
    """
    source = event.get("source", "")

    if source == "gochuchamchi.triage":
        return handle_triage_event(event)

    # 트리아지가 켜져 있으면 finding은 위 경로로 들어온다. 이 분기는
    # enable_triage=false 롤백 시(EventBridge → SNS 직결)를 위해 남는다.
    if source == "aws.guardduty":
        return handle_guardduty_event(event)

    if source == "gochuchamchi.isolation":
        return handle_isolation_event(event)

    if source == "gochuchamchi.plaintext":
        return handle_plaintext_event(event)

    if event.get("detail-type") in (
        "AWS API Call via CloudTrail",
        "AWS Console Sign In via CloudTrail",
    ):
        return handle_cloudtrail_change_event(event)

    return handle_alarm_event(event)


def severity_label(severity: float) -> str:
    """GuardDuty 숫자 severity를 등급 문자열로 변환합니다."""
    if severity >= 9:
        return "CRITICAL"
    if severity >= 7:
        return "HIGH"
    if severity >= 4:
        return "MEDIUM"
    return "LOW"


def severity_color(severity: float) -> int:
    """GuardDuty 등급별 Discord Embed 색상."""
    if severity >= 7:
        return 10038562  # 진한 빨강
    if severity >= 4:
        return 15105570  # 주황
    return 9807270  # 회색


def incident_tier_for_guardduty(detail: dict[str, Any], severity: float) -> str:
    """Map GuardDuty findings to the operator-facing P1-P4 response tier."""
    finding_type = str(detail.get("type", ""))
    p1_prefixes = (
        "Policy:IAMUser/Root", "CredentialAccess:", "Exfiltration:",
        "Backdoor:", "Trojan:", "CryptoCurrency:", "Impact:",
    )
    if severity >= 7 or finding_type.startswith(p1_prefixes):
        return "P1"
    if severity >= 4:
        return "P2"
    return "P3"


def incident_tier_for_alarm(alarm_name: str) -> str:
    """Classify CloudWatch security alarms without turning routine signals into P1."""
    if "high-security-event" in alarm_name:
        return "P2"
    if "firehose-" in alarm_name and "delivery-error" in alarm_name:
        return "P2"
    if any(marker in alarm_name for marker in ("http-5xx", "login-failure", "access-denied", "waf-sqli")):
        return "P2"
    if any(marker in alarm_name for marker in ("waf-", "http-4xx", "target-4xx", "firehose")):
        return "P3"
    return "P4"


def handle_guardduty_event(event: dict[str, Any]) -> dict[str, Any]:
    """GuardDuty finding 1건을 Discord 메시지로 변환·전송합니다."""
    detail = event.get("detail", {})

    finding_type = detail.get("type", "알 수 없는 finding")
    severity = float(detail.get("severity", 0))
    title = detail.get("title", finding_type)
    description = detail.get("description", "상세 설명 없음")

    resource = detail.get("resource", {})
    resource_type = resource.get("resourceType", "알 수 없음")
    instance_id = (
        resource.get("instanceDetails", {}).get("instanceId", "-")
        if resource_type == "Instance"
        else "-"
    )

    label = severity_label(severity)
    incident_tier = incident_tier_for_guardduty(detail, severity)
    will_isolate = severity >= 7

    discord_payload = {
        "username": "Gochuchamchi GuardDuty",
        "embeds": [
            {
                "title": f"🛡️ [{label}] {trim_text(title, 200)}",
                "color": severity_color(severity),
                "fields": [
                    {
                        "name": "Finding 유형",
                        "value": f"`{trim_text(finding_type, 200)}`",
                        "inline": False,
                    },
                    {
                        "name": "Severity",
                        "value": f"`{severity}` ({label})",
                        "inline": True,
                    },
                    {
                        "name": "Incident tier",
                        "value": f"`{incident_tier}`",
                        "inline": True,
                    },
                    {
                        "name": "대상 리소스",
                        "value": f"`{resource_type}` / `{instance_id}`",
                        "inline": True,
                    },
                    {
                        "name": "자동 대응",
                        "value": (
                            "⚡ High 이상 + EC2 대상 → 격리 Lambda 발동됨 (결과 별도 통보)"
                            if will_isolate
                            else "통보만 — 격리 조건(High 이상 + EC2) 미충족"
                        ),
                        "inline": False,
                    },
                    {
                        "name": "설명",
                        "value": trim_text(description),
                        "inline": False,
                    },
                ],
                "footer": {
                    "text": "GuardDuty → EventBridge → SNS → Lambda → Discord"
                },
            }
        ],
    }

    send_discord_message(get_discord_webhook_url(), discord_payload)

    return {"findingType": finding_type, "severity": severity, "incidentTier": incident_tier}


def handle_triage_event(event: dict[str, Any]) -> dict[str, Any]:
    """AI 트리아지를 거친 GuardDuty finding을 렌더링합니다.

    색과 아이콘은 **정책 액션**이 정합니다(판정이 아니라). 받는 사람이 먼저
    알아야 하는 것은 "이게 얼마나 급한가"이지 "모델이 뭐라 했나"가 아니기
    때문입니다.

    판정이 없을 때(Groq 장애·한도 초과 등)도 이 렌더러로 옵니다. 그 경우
    "판정 출처"에 이유가 찍히므로, 판정 없이 온 알림을 "AI가 정상이라고 했다"로
    오해하지 않습니다.
    """
    finding = event.get("finding", {})
    verdict = event.get("verdict") or {}

    finding_type = finding.get("type", "알 수 없는 finding")
    severity = finding.get("severity", "-")
    tier = event.get("tier", "-")
    action = event.get("action", "-")
    icon = event.get("icon", "❔")
    label = event.get("label", action)

    verdict_value = verdict.get("verdict")
    if verdict_value:
        source_text = f"모델 판정 ({verdict.get('model', '?')})"
        if event.get("judged_from") == "cache":
            source_text = f"이전 동일 finding 판정 재사용 ({verdict.get('model', '?')})"
    else:
        source_text = (
            f"**판정 없음** — {verdict.get('unavailable_reason', '사유 미상')}\n"
            "판정 없이 그대로 통보했습니다. 내용은 직접 확인하십시오."
        )

    fields = [
        {"name": "Finding 유형", "value": f"`{trim_text(finding_type, 200)}`", "inline": False},
        {"name": "등급 / Severity", "value": f"`{tier}` (severity `{severity}`)", "inline": True},
        {
            "name": "AI 판정",
            "value": (
                f"`{verdict_value or '없음'}`"
                + (f" · 확신 {verdict.get('confidence', 0):.0%}" if verdict_value else "")
            ),
            "inline": True,
        },
        {"name": "위험도", "value": f"`{verdict.get('risk_score', '-')}` / 100", "inline": True},
    ]

    if verdict.get("reason"):
        fields.append({"name": "판단", "value": trim_text(verdict["reason"]), "inline": False})
    if verdict.get("evidence"):
        fields.append({"name": "근거", "value": trim_text(verdict["evidence"]), "inline": False})
    if verdict.get("recommended_action"):
        fields.append({"name": "권장 조치", "value": trim_text(verdict["recommended_action"]), "inline": False})

    # 강등은 반드시 밝힌다 — "모델은 오탐이라 했는데 왜 검토로 왔나"에 답할 수 있어야 한다.
    if event.get("verdict_demoted"):
        fields.append({
            "name": "⚠️ 판정 강등됨",
            "value": (
                "모델은 FALSE_POSITIVE로 봤지만 확신이 기준(`triage_suppress_min_confidence`) "
                "미만이라 UNCERTAIN으로 낮춰 통보했습니다."
            ),
            "inline": False,
        })

    if verdict.get("injection_suspected"):
        fields.append({
            "name": "🚨 프롬프트 인젝션 의심",
            "value": (
                "finding 값에 판정을 조작하려는 문자열이 있습니다. **그 자체가 침해 신호**이므로 "
                "룰 내용과 별개로 다루십시오."
            ),
            "inline": False,
        })

    fields.extend([
        {
            "name": "대상 / 출발지",
            "value": f"`{finding.get('resource', '-')}` ← `{finding.get('remote_ip') or '-'}`",
            "inline": False,
        },
        {"name": "판정 출처", "value": trim_text(source_text), "inline": False},
        {
            "name": "원본 확인",
            "value": f"[GuardDuty 콘솔]({event.get('console_url', '')}) · 발생 `{finding.get('count', '-')}`회",
            "inline": False,
        },
    ])

    discord_payload = {
        "username": "Gochuchamchi GuardDuty",
        "embeds": [
            {
                "title": f"{icon} [{label}] {trim_text(finding.get('title', finding_type), 180)}",
                "description": trim_text(finding.get("description", ""), 500),
                "color": event.get("color", 9807270),
                "fields": fields,
                "footer": {"text": "GuardDuty → EventBridge → AI 트리아지 → SNS → Discord"},
                "timestamp": event.get("detected_at"),
            }
        ],
    }

    send_discord_message(get_discord_webhook_url(), discord_payload)

    return {
        "findingType": finding_type,
        "tier": tier,
        "verdict": verdict_value or "none",
        "action": action,
    }


def handle_plaintext_event(event: dict[str, Any]) -> dict[str, Any]:
    """JSON이 아닌 SNS 메시지를 그대로 보여줍니다.

    EventBridge input_transformer로 사람이 읽을 문장을 만들어 보내는 발행자
    (iam-activity.tf)를 위한 경로. 파싱할 구조가 없으니 꾸미지 않고 원문을
    그대로 싣는다 — 여기서 정규식으로 필드를 뽑으려 들면 발행자 템플릿이
    바뀔 때마다 조용히 깨진다.
    """
    detail = event.get("detail", {})

    discord_payload = {
        "username": "Gochuchamchi Alert",
        "embeds": [
            {
                "title": f"📣 {trim_text(detail.get('subject', '알림'), 180)}",
                "color": 15105570,
                "description": trim_text(detail.get("message", ""), 3800),
                "footer": {"text": "EventBridge → SNS → Discord (평문 메시지)"},
            }
        ],
    }

    send_discord_message(get_discord_webhook_url(), discord_payload)

    return {"plaintext": True}


def handle_cloudtrail_change_event(event: dict[str, Any]) -> dict[str, Any]:
    """콘솔/IAM/루트 변경 이벤트를 변경 주체 중심으로 표시한다.

    drift-detection.tf의 EventBridge 룰은 CloudTrail 원본 JSON을 SNS로 보낸다.
    이를 CloudWatch Alarm 형식으로 오해하면 제목과 상태가 UNKNOWN으로 표시되므로
    변경 API, 주체, 출발 IP, 성공/실패를 직접 렌더링한다.
    """
    detail = event.get("detail", {})
    identity = detail.get("userIdentity", {})
    session_issuer = identity.get("sessionContext", {}).get("sessionIssuer", {})

    actor = (
        identity.get("arn")
        or session_issuer.get("arn")
        or identity.get("principalId")
        or "unknown"
    )
    event_name = detail.get("eventName", "unknown")
    event_source = detail.get("eventSource", event.get("source", "unknown"))
    source_ip = detail.get("sourceIPAddress", "unknown")
    error_code = detail.get("errorCode")
    outcome = f"실패: {error_code}" if error_code else "성공"
    is_root = identity.get("type") == "Root"

    title_prefix = "🚨 루트 활동" if is_root else "⚠️ 인프라 수동 변경"
    color = 15158332 if is_root or error_code else 15105570

    discord_payload = {
        "username": "Gochuchamchi Drift Detection",
        "embeds": [
            {
                "title": f"{title_prefix}: {trim_text(event_name, 140)}",
                "color": color,
                "fields": [
                    {"name": "서비스", "value": f"`{trim_text(event_source, 200)}`", "inline": True},
                    {"name": "결과", "value": f"`{trim_text(outcome, 200)}`", "inline": True},
                    {"name": "변경 주체", "value": trim_text(actor), "inline": False},
                    {"name": "출발 IP", "value": f"`{trim_text(source_ip, 200)}`", "inline": True},
                    {"name": "변경 시각", "value": trim_text(event.get("time", "unknown")), "inline": True},
                ],
                "footer": {"text": "CloudTrail → EventBridge → SNS → Discord"},
            }
        ],
    }

    send_discord_message(get_discord_webhook_url(), discord_payload)
    return {"cloudTrailEvent": event_name, "actor": actor, "outcome": outcome}


def handle_isolation_event(event: dict[str, Any]) -> dict[str, Any]:
    """격리 Lambda의 실행 결과를 Discord 메시지로 변환·전송합니다."""
    detail = event.get("detail", {})

    action = detail.get("action", "unknown")
    instance_id = detail.get("instanceId", "-")
    finding_type = detail.get("findingType", "-")
    action_detail = detail.get("detail", "")

    # 자격증명 대응 경로는 인스턴스가 아니라 액세스키가 대상이라 instanceId가 없다.
    # 그대로 두면 제목이 "🔑 ...: -"가 되어 무엇에 대한 조치인지 안 보인다.
    if detail.get("accessKeyId"):
        target = f"{detail.get('userName', '?')} / {detail['accessKeyId']}"
    else:
        target = instance_id

    action_render = {
        "manual-review": ("P1 manual containment required", 15158332),
        "isolated": ("🔒 격리 완료", 10038562),
        "already-isolated": ("🔒 이미 격리됨", 9807270),
        "dry-run": ("🧪 드라이런 (실제 미실행)", 15105570),
        "skipped": ("⏭️ 격리 생략", 9807270),
        "failed": ("❌ 격리 실패 — 수동 개입 필요", 15158332),
        "none": ("ℹ️ 조치 없음", 9807270),
        # (2026-08-12) 자동대응 3종 확장이 내보내는 action들.
        # 없으면 "❓ key-disabled" 회색으로 떠서, 가장 강한 대응인 자격증명
        # 무효화가 가장 눈에 안 띄는 알림이 된다.
        "recovered": ("♻️ 격리 원상복구 완료", 3066993),
        "manual-required": ("🛠️ 자동 복구 불가 — 수동 확인 필요", 15105570),
        "key-disabled": ("🔑 탈취 의심 액세스키 비활성화됨", 10038562),
        "stale-quarantine": ("⏰ 격리 후 장기 미복구 — 정리 필요", 15105570),
        "audit-clean": ("✅ 격리 감사 이상 없음", 3066993),
    }
    action_text, color = action_render.get(action, (f"❓ {action}", 9807270))

    discord_payload = {
        "username": "Gochuchamchi Isolation",
        "embeds": [
            {
                "title": f"{action_text}: {target}",
                "color": color,
                "fields": [
                    {
                        "name": "발동 Finding",
                        "value": f"`{trim_text(finding_type, 200)}`",
                        "inline": False,
                    },
                    {
                        "name": "상세",
                        "value": trim_text(action_detail),
                        "inline": False,
                    },
                ],
                "footer": {
                    "text": "GuardDuty → EventBridge → 격리 Lambda → SNS → Discord"
                },
            }
        ],
    }

    send_discord_message(get_discord_webhook_url(), discord_payload)

    return {"isolationAction": action, "instanceId": instance_id}


def handle_alarm_event(event: dict[str, Any]) -> dict[str, Any]:
    """EventBridge 원본 이벤트 1건을 Discord 메시지로 변환·전송합니다."""
    detail = event.get("detail", {})
    current_state = detail.get("state", {})
    previous_state = detail.get("previousState", {})

    alarm_name = detail.get("alarmName", "알 수 없는 CloudWatch Alarm")
    incident_tier = incident_tier_for_alarm(alarm_name)
    new_state = current_state.get("value", "UNKNOWN")
    old_state = previous_state.get("value", "UNKNOWN")
    reason = current_state.get("reason", "상태 변경 원인 없음")

    region = event.get("region", "알 수 없음")
    account = event.get("account", "알 수 없음")
    changed_at = event.get("time", "알 수 없음")

    discord_payload = {
        "username": "Gochuchamchi CloudWatch",
        "embeds": [
            {
                "title": (
                    f"{state_icon(new_state)} "
                    f"[{incident_tier}] CloudWatch Alarm: {alarm_name}"
                ),
                "color": state_color(new_state),
                "fields": [
                    {
                        "name": "상태 변경",
                        "value": f"`{old_state}` → `{new_state}`",
                        "inline": True,
                    },
                    {
                        "name": "AWS 리전",
                        "value": f"`{region}`",
                        "inline": True,
                    },
                    {
                        "name": "AWS 계정",
                        "value": f"`{account}`",
                        "inline": True,
                    },
                    {
                        "name": "변경 시각",
                        "value": trim_text(changed_at),
                        "inline": False,
                    },
                    {
                        "name": "상세 원인",
                        "value": trim_text(reason),
                        "inline": False,
                    },
                ],
                "footer": {
                    "text": (
                        "AWS CloudWatch → EventBridge "
                        "→ SNS → Lambda → Discord"
                    )
                },
            }
        ],
    }

    webhook_url = get_discord_webhook_url()

    send_discord_message(
        webhook_url,
        discord_payload,
    )

    return {
        "alarmName": alarm_name,
        "state": new_state,
        "incidentTier": incident_tier,
    }
