"""AWS Config 네트워크 비준수 상태를 매시간 재통보한다.

자동 복구는 하지 않는다. AWS Config가 판단한 결과를 읽고 다음만 수행한다.
  * NON_COMPLIANT가 하나라도 있으면 실행할 때마다 SNS로 요약 통보
  * 이전 실행이 NON_COMPLIANT였는데 모두 복구되면 RESOLVED를 한 번 통보
  * 검사 자체가 실패하면 파이프라인 장애를 SNS로 통보한 뒤 예외를 다시 던짐
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import boto3


LOG = logging.getLogger()
LOG.setLevel(logging.INFO)

CONFIG_RULE_NAMES = [
    name.strip()
    for name in os.environ["CONFIG_RULE_NAMES"].split(",")
    if name.strip()
]
STATE_TABLE_NAME = os.environ["STATE_TABLE_NAME"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

config = boto3.client("config")
dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
state_table = dynamodb.Table(STATE_TABLE_NAME)

STATE_KEY = "network-compliance-summary"


def _noncompliant_resources(rule_name: str) -> list[dict[str, str]]:
    resources: list[dict[str, str]] = []
    next_token: str | None = None

    while True:
        request: dict[str, Any] = {
            "ConfigRuleName": rule_name,
            "ComplianceTypes": ["NON_COMPLIANT"],
            "Limit": 100,
        }
        if next_token:
            request["NextToken"] = next_token

        response = config.get_compliance_details_by_config_rule(**request)
        for result in response.get("EvaluationResults", []):
            qualifier = result["EvaluationResultIdentifier"]["EvaluationResultQualifier"]
            resources.append(
                {
                    "type": qualifier.get("ResourceType", "unknown"),
                    "id": qualifier.get("ResourceId", "unknown"),
                    "annotation": result.get("Annotation", ""),
                }
            )

        next_token = response.get("NextToken")
        if not next_token:
            return resources


def _read_noncompliant() -> tuple[dict[str, list[dict[str, str]]], list[str]]:
    response = config.describe_compliance_by_config_rule(
        ConfigRuleNames=CONFIG_RULE_NAMES,
    )

    compliance_by_name = {
        item["ConfigRuleName"]: item.get("Compliance", {}).get("ComplianceType", "NOT_APPLICABLE")
        for item in response.get("ComplianceByConfigRules", [])
    }

    noncompliant: dict[str, list[dict[str, str]]] = {}
    unevaluated: list[str] = []

    for rule_name in CONFIG_RULE_NAMES:
        state = compliance_by_name.get(rule_name, "MISSING")
        if state == "NON_COMPLIANT":
            noncompliant[rule_name] = _noncompliant_resources(rule_name)
        elif state not in ("COMPLIANT", "NOT_APPLICABLE"):
            unevaluated.append(f"{rule_name}={state}")

    return noncompliant, unevaluated


def _fingerprint(noncompliant: dict[str, list[dict[str, str]]]) -> str:
    canonical = json.dumps(noncompliant, ensure_ascii=True, sort_keys=True)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _previous_state() -> dict[str, Any]:
    response = state_table.get_item(Key={"stateKey": STATE_KEY}, ConsistentRead=True)
    return response.get("Item", {})


def _write_state(noncompliant: dict[str, list[dict[str, str]]]) -> None:
    state_table.put_item(
        Item={
            "stateKey": STATE_KEY,
            "wasNoncompliant": bool(noncompliant),
            "fingerprint": _fingerprint(noncompliant),
            "lastCheckedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
    )


def _publish(subject: str, message: str) -> None:
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject[:100],
        Message=message,
    )


def _format_noncompliant(
    noncompliant: dict[str, list[dict[str, str]]],
    unevaluated: list[str],
) -> str:
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    lines = [
        "[NETWORK COMPLIANCE - NON_COMPLIANT]",
        f"확인 시각(UTC): {now}",
        "자동 복구는 수행하지 않았습니다. 위험 상태를 수동으로 확인해 주세요.",
        "",
    ]

    for rule_name, resources in sorted(noncompliant.items()):
        lines.append(f"- {rule_name}: {len(resources)}개 리소스")
        for resource in resources[:20]:
            detail = f"  · {resource['type']} / {resource['id']}"
            if resource["annotation"]:
                detail += f" / {resource['annotation']}"
            lines.append(detail)
        if len(resources) > 20:
            lines.append(f"  · 외 {len(resources) - 20}개")

    if unevaluated:
        lines.extend(["", "평가 대기/확인 필요: " + ", ".join(unevaluated)])

    lines.extend(
        [
            "",
            "이 알림은 위반 내용이 바뀌거나 상태가 복구될 때 다시 통보됩니다.",
        ]
    )
    return "\n".join(lines)


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:  # noqa: ARG001
    LOG.info("네트워크 Config 준수 검사 시작: %s", CONFIG_RULE_NAMES)
    previous = _previous_state()

    try:
        noncompliant, unevaluated = _read_noncompliant()
    except Exception as error:  # noqa: BLE001 — 검사 장애도 반드시 통보
        LOG.exception("AWS Config 준수 검사 실패")
        _publish(
            "[PIPELINE][P1] Network compliance check failed",
            "[NETWORK COMPLIANCE CHECK FAILED]\n"
            f"AWS Config 상태를 확인하지 못했습니다: {type(error).__name__}: {error}\n"
            "자동 복구는 수행하지 않았습니다. Lambda와 AWS Config 상태를 확인하세요.",
        )
        raise

    if noncompliant:
        current_fingerprint = _fingerprint(noncompliant)
        # 같은 비준수 상태가 이어지는 동안에는 매시간 재통보하지 않는다.
        # 처음 비준수로 바뀌었거나(직전이 준수) 위반 리소스 구성이 달라졌을 때만 통보한다.
        if (
            not previous.get("wasNoncompliant")
            or previous.get("fingerprint") != current_fingerprint
        ):
            _publish(
                "[SEC][P1] Network state remains noncompliant",
                _format_noncompliant(noncompliant, unevaluated),
            )
        else:
            LOG.info("동일한 비준수 상태 지속 — 재통보 생략(fingerprint 일치)")
    elif unevaluated:
        # 평가 대기/누락 상태를 COMPLIANT로 간주하면 이전 위험 상태를 거짓으로
        # RESOLVED 처리하게 된다. 직전 상태는 보존하고 검사 불완전만 통보한다.
        _publish(
            "[PIPELINE][P2] Network compliance evaluation incomplete",
            "[NETWORK COMPLIANCE - EVALUATION INCOMPLETE]\n"
            "다음 AWS Config 규칙의 평가 결과를 확인할 수 없습니다:\n"
            + "\n".join(f"- {item}" for item in unevaluated)
            + "\n\n이전 준수 상태를 유지하며 자동 복구는 수행하지 않았습니다.",
        )
        return {
            "status": "evaluation-incomplete",
            "rules": [],
            "resourceCount": 0,
            "unevaluated": unevaluated,
        }
    elif previous.get("wasNoncompliant"):
        _publish(
            "[SEC][P1][RESOLVED] Network compliance restored",
            "[NETWORK COMPLIANCE - RESOLVED]\n"
            "이전 실행에서 발견된 네트워크 위험 상태가 모두 복구되었습니다.\n"
            f"확인 시각(UTC): {datetime.now(timezone.utc).isoformat(timespec='seconds')}",
        )

    _write_state(noncompliant)

    return {
        "status": "noncompliant" if noncompliant else "compliant",
        "rules": sorted(noncompliant),
        "resourceCount": sum(len(resources) for resources in noncompliant.values()),
        "unevaluated": unevaluated,
    }
