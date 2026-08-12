"""GuardDuty High 이상 finding에 대한 EC2 네트워크 자동 격리.

동작:
    1. finding에서 대상 인스턴스 ID를 꺼낸다 (EC2 대상 finding만 격리 가능)
    2. 인스턴스가 속한 VPC에서 검역 SG를 찾고, 없으면 만든다
       (인바운드 0 + 기본 아웃바운드 규칙 제거 = 전면 차단)
    3. 인스턴스의 모든 ENI에 붙은 SG를 검역 SG 하나로 교체한다
    4. 인스턴스에 포렌식 태그를 남긴다 (누가/왜/언제 격리했는지)
    5. 결과를 SNS 알림 허브로 발행한다 → Discord/이메일로 전파

설계 노트:
    - 검역 SG를 Terraform이 아니라 여기서 즉석 생성하는 이유: VPC가 매일
      destroy/apply 되므로 SG ARN을 배포 시점에 알 수 없다. Terraform으로
      만들면 상시 계층이 일일 계층을 참조하게 돼 한 방향 원칙이 깨진다.
    - 인스턴스가 이미 없으면(매일 destroy 환경에선 흔함) 조용히 skip 처리하고
      그 사실을 통보한다.
    - SG 교체는 노드를 죽이지 않는다. kubelet이 API 서버와 끊겨 노드가
      NotReady로 빠지고 파드는 다른 노드로 재스케줄된다. 인스턴스 자체는
      살아 있어 EBS/메모리 포렌식이 가능하다 — terminate보다 격리를 쓰는 이유.
"""

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
MIN_SEVERITY = float(os.environ.get("MIN_SEVERITY", "7"))
QUARANTINE_SG_NAME = os.environ.get("QUARANTINE_SG_NAME", "gochuchamchi-quarantine")
ISOLATION_ENABLED = os.environ.get("ISOLATION_ENABLED", "true").lower() == "true"


# 격리 직전 각 ENI의 원래 SG 목록을 이 태그에 저장한다. 복구는 이 값만 보고
# 원상복구하므로, 이 태그가 없으면(=격리 이력이 없거나 인스턴스가 재생성됨)
# 복구할 게 없다고 판단한다.
PRE_QUARANTINE_TAG = "gochuchamchi:pre-quarantine-sgs"


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """GuardDuty finding(격리) 또는 수동 복구 요청을 처리합니다.

    격리:  EventBridge 가 GuardDuty finding 으로 직접 호출 (기존 경로).
    복구:  사람이 오격리를 확인한 뒤 아래처럼 수동 호출 (멘토: 오격리 원상복구):
      aws lambda invoke --function-name gochuchamchi-guardduty-isolation \\
        --payload '{"action":"recover","instanceId":"i-xxxx"}' \\
        --cli-binary-format raw-in-base64-out out.json --region ap-northeast-2 \\
        --profile workload-admin
    복구를 자동화하지 않는 이유: "정말 오탐인가"의 판단은 사람이 해야 한다.
    자동 원복은 진짜 침해를 자동으로 풀어주는 역방향 위험을 만든다.
    """
    logger.info("수신 이벤트: %s", json.dumps(event, ensure_ascii=False))

    # ── 수동 복구 분기 ────────────────────────────────────────────────
    if event.get("action") == "recover":
        return recover_instance(event.get("instanceId", ""))

    detail = event.get("detail", {})
    finding_id = detail.get("id", "unknown")
    finding_type = detail.get("type", "unknown")
    severity = float(detail.get("severity", 0))

    result: dict[str, Any] = {
        "findingId": finding_id,
        "findingType": finding_type,
        "severity": severity,
        "action": "none",
        "detail": "",
    }

    try:
        # ── 1. 발동 조건 확인 ────────────────────────────────────────
        if severity < MIN_SEVERITY:
            # EventBridge rule에서 이미 걸렀지만, rule 패턴이 실수로 넓어져도
            # 여기서 한 번 더 막는다 (이중 방어)
            result["detail"] = f"severity {severity} < 기준 {MIN_SEVERITY}"
            return finish(result)

        instance_id = extract_instance_id(detail)
        if not instance_id:
            # IAM/S3/EKS 컨트롤플레인 대상 finding — SG 격리로 대응 불가.
            # 통보 경로(Rule 1)가 이미 Discord로 알렸으므로 여기선 기록만.
            result["detail"] = "EC2 인스턴스 대상 finding이 아님 — 격리 생략, 수동 대응 필요"
            return finish(result)

        result["instanceId"] = instance_id

        # ── 2. 인스턴스 조회 ─────────────────────────────────────────
        instance = describe_instance(instance_id)
        if instance is None:
            result["action"] = "skipped"
            result["detail"] = "인스턴스가 이미 없음 (일일 destroy 환경에선 정상 가능)"
            return finish(result)

        state = instance["State"]["Name"]
        if state in ("terminated", "shutting-down"):
            result["action"] = "skipped"
            result["detail"] = f"인스턴스 상태 {state} — 격리 불필요"
            return finish(result)

        vpc_id = instance["VpcId"]
        enis = [ni["NetworkInterfaceId"] for ni in instance["NetworkInterfaces"]]

        # ── 3. 드라이런 스위치 ───────────────────────────────────────
        if not ISOLATION_ENABLED:
            result["action"] = "dry-run"
            result["detail"] = (
                f"ISOLATION_ENABLED=false — 실제였다면 {instance_id}의 "
                f"ENI {len(enis)}개를 검역 SG로 교체했음"
            )
            return finish(result)

        # ── 4. 검역 SG 확보 ─────────────────────────────────────────
        quarantine_sg = ensure_quarantine_sg(vpc_id)

        # ── 5. 멱등성: 이미 격리돼 있으면 재작업 없이 종료 ──────────
        current_sgs = {sg["GroupId"] for sg in instance["SecurityGroups"]}
        if current_sgs == {quarantine_sg}:
            result["action"] = "already-isolated"
            result["detail"] = "모든 ENI가 이미 검역 SG만 사용 중"
            return finish(result)

        # ── 6. 격리 실행: ENI 단위로 SG 전량 교체 ───────────────────
        #     교체 전에 각 ENI의 원래 SG를 그 ENI 태그에 기록한다 — 복구의 유일한
        #     근거다. 인스턴스 태그 하나에 몰아넣지 않는 이유: ENI가 여러 개면
        #     JSON이 태그값 256자 한도를 넘을 수 있어서. ENI별로 나누면 각 값이 작다.
        for ni in instance["NetworkInterfaces"]:
            eni_id = ni["NetworkInterfaceId"]
            original_sgs = [g["GroupId"] for g in ni.get("Groups", [])]
            # 이미 검역 SG만 있는 ENI는 원본을 덮어쓰지 않는다(재실행 안전 —
            # 5번에서 걸러지지만 ENI별 부분 격리 상태도 방어)
            if original_sgs and original_sgs != [quarantine_sg]:
                ec2.create_tags(
                    Resources=[eni_id],
                    Tags=[{"Key": PRE_QUARANTINE_TAG, "Value": ",".join(original_sgs)}],
                )
            ec2.modify_network_interface_attribute(
                NetworkInterfaceId=eni_id,
                Groups=[quarantine_sg],
            )
            logger.info("ENI %s → 검역 SG %s 교체 완료 (원본 %s 기록)", eni_id, quarantine_sg, original_sgs)

        # ── 7. 포렌식 태깅 ──────────────────────────────────────────
        ec2.create_tags(
            Resources=[instance_id],
            Tags=[
                {"Key": "gochuchamchi:quarantined", "Value": "true"},
                {"Key": "gochuchamchi:quarantine-finding", "Value": finding_id[:255]},
                {
                    "Key": "gochuchamchi:quarantine-time",
                    "Value": datetime.now(timezone.utc).isoformat(),
                },
            ],
        )

        result["action"] = "isolated"
        result["detail"] = (
            f"ENI {len(enis)}개를 검역 SG {quarantine_sg}로 교체, "
            f"기존 SG: {sorted(current_sgs)}"
        )
        return finish(result)

    except Exception as error:  # noqa: BLE001 — 실패도 반드시 통보돼야 함
        logger.exception("격리 실행 실패")
        result["action"] = "failed"
        result["detail"] = f"{type(error).__name__}: {error}"
        finish(result)
        # EventBridge 재시도가 동작하도록 예외를 다시 던진다
        raise


def recover_instance(instance_id: str) -> dict[str, Any]:
    """오격리된 인스턴스를 원래 SG로 되돌립니다(멘토: 오격리 원상복구).

    각 ENI의 pre-quarantine 태그에 저장된 원본 SG를 읽어 복원하고, 격리
    태그를 지운다. 태그가 없으면 복구할 근거가 없으므로 그 사실을 통보한다.
    """
    result: dict[str, Any] = {
        "action": "recover",
        "instanceId": instance_id,
        "detail": "",
    }

    if not instance_id:
        result["action"] = "failed"
        result["detail"] = "instanceId 가 비어 있음 — {\"action\":\"recover\",\"instanceId\":\"i-...\"} 형식으로 호출"
        return finish(result)

    try:
        instance = describe_instance(instance_id)
        if instance is None:
            result["action"] = "skipped"
            result["detail"] = "인스턴스가 이미 없음 — 복구 불필요(일일 destroy 환경에선 다음 재구축이 정상 SG로 생성)"
            return finish(result)

        restored: list[str] = []
        missing: list[str] = []
        for ni in instance["NetworkInterfaces"]:
            eni_id = ni["NetworkInterfaceId"]
            tags = {t["Key"]: t["Value"] for t in ni.get("TagSet", [])}
            original = tags.get(PRE_QUARANTINE_TAG)
            if not original:
                missing.append(eni_id)
                continue
            original_sgs = [s for s in original.split(",") if s]
            ec2.modify_network_interface_attribute(
                NetworkInterfaceId=eni_id,
                Groups=original_sgs,
            )
            ec2.delete_tags(Resources=[eni_id], Tags=[{"Key": PRE_QUARANTINE_TAG}])
            restored.append(f"{eni_id}→{original_sgs}")
            logger.info("ENI %s 원본 SG %s 복원", eni_id, original_sgs)

        if not restored:
            result["action"] = "skipped"
            result["detail"] = (
                f"복원할 pre-quarantine 태그가 없음(ENI: {missing}) — "
                "이 인스턴스는 격리 이력이 없거나 이미 복구됨"
            )
            return finish(result)

        # 인스턴스의 격리 포렌식 태그 제거
        ec2.delete_tags(
            Resources=[instance_id],
            Tags=[
                {"Key": "gochuchamchi:quarantined"},
                {"Key": "gochuchamchi:quarantine-finding"},
                {"Key": "gochuchamchi:quarantine-time"},
            ],
        )

        result["action"] = "recovered"
        result["detail"] = f"복원 {len(restored)}개 ENI: {restored}"
        if missing:
            result["detail"] += f" / 태그 없어 건너뜀: {missing}"
        return finish(result)

    except Exception as error:  # noqa: BLE001 — 복구 실패도 반드시 통보
        logger.exception("복구 실행 실패")
        result["action"] = "failed"
        result["detail"] = f"{type(error).__name__}: {error}"
        return finish(result)


def extract_instance_id(detail: dict[str, Any]) -> str | None:
    """finding의 resource 블록에서 EC2 인스턴스 ID를 꺼냅니다."""
    resource = detail.get("resource", {})

    if resource.get("resourceType") != "Instance":
        return None

    return resource.get("instanceDetails", {}).get("instanceId")


def describe_instance(instance_id: str) -> dict[str, Any] | None:
    """인스턴스 상세를 반환합니다. 존재하지 않으면 None."""
    try:
        response = ec2.describe_instances(InstanceIds=[instance_id])
    except ec2.exceptions.ClientError as error:
        if error.response["Error"]["Code"] == "InvalidInstanceID.NotFound":
            return None
        raise

    reservations = response.get("Reservations", [])
    if not reservations or not reservations[0].get("Instances"):
        return None

    return reservations[0]["Instances"][0]


def ensure_quarantine_sg(vpc_id: str) -> str:
    """대상 VPC의 검역 SG ID를 반환합니다. 없으면 만들고 기본 egress를 제거."""
    existing = ec2.describe_security_groups(
        Filters=[
            {"Name": "vpc-id", "Values": [vpc_id]},
            {"Name": "group-name", "Values": [QUARANTINE_SG_NAME]},
        ]
    )["SecurityGroups"]

    if existing:
        return existing[0]["GroupId"]

    created = ec2.create_security_group(
        GroupName=QUARANTINE_SG_NAME,
        Description="gochuchamchi auto-isolation quarantine (no rules = deny all)",
        VpcId=vpc_id,
        TagSpecifications=[
            {
                "ResourceType": "security-group",
                # IAM 정책의 RevokeSecurityGroupEgress 조건이 이 태그를 요구함
                "Tags": [
                    {"Key": "gochuchamchi:role", "Value": "quarantine"},
                    {"Key": "Name", "Value": QUARANTINE_SG_NAME},
                ],
            }
        ],
    )
    sg_id = created["GroupId"]

    # SG는 생성 시 "모든 아웃바운드 허용" 규칙이 기본으로 붙는다.
    # 이걸 지워야 진짜 전면 차단이 된다 (인바운드는 원래 0).
    ec2.revoke_security_group_egress(
        GroupId=sg_id,
        IpPermissions=[
            {
                "IpProtocol": "-1",
                "IpRanges": [{"CidrIp": "0.0.0.0/0"}],
            }
        ],
    )

    logger.info("검역 SG 신규 생성: %s (vpc=%s)", sg_id, vpc_id)
    return sg_id


def finish(result: dict[str, Any]) -> dict[str, Any]:
    """결과를 SNS 허브로 발행합니다. Discord Lambda가 렌더링합니다.

    lambda_function.py의 unwrap_events가 SNS Message를 EventBridge 이벤트로
    해석하므로, 같은 봉투 형식(source/detail-type/detail)으로 발행한다.
    """
    synthetic_event = {
        "source": "gochuchamchi.isolation",
        "detail-type": "GuardDuty Isolation Result",
        "time": datetime.now(timezone.utc).isoformat(),
        "region": os.environ.get("AWS_REGION", "ap-northeast-2"),
        "detail": result,
    }

    try:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[gochuchamchi] GuardDuty 자동 격리 결과",
            Message=json.dumps(synthetic_event, ensure_ascii=False),
        )
    except Exception:  # noqa: BLE001
        # 통보 실패가 격리 결과 자체를 뒤집으면 안 됨 — 로그만 남긴다
        logger.exception("격리 결과 SNS 발행 실패")

    logger.info("격리 결과: %s", json.dumps(result, ensure_ascii=False))
    return result
