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

    return [
        json.loads(record["Sns"]["Message"])
        for record in event["Records"]
        if record.get("EventSource") == "aws:sns"
    ]


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
        results.append(handle_alarm_event(bridge_event))

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


def handle_alarm_event(event: dict[str, Any]) -> dict[str, Any]:
    """EventBridge 원본 이벤트 1건을 Discord 메시지로 변환·전송합니다."""
    detail = event.get("detail", {})
    current_state = detail.get("state", {})
    previous_state = detail.get("previousState", {})

    alarm_name = detail.get("alarmName", "알 수 없는 CloudWatch Alarm")
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
                    f"CloudWatch Alarm: {alarm_name}"
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
    }