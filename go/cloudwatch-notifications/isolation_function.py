"""GuardDuty High 이상 finding에 대한 자동 대응 (격리 / 자격증명 무효화 / 감사).

진입점은 셋이다:
    - EventBridge(GuardDuty finding)  → 격리 또는 액세스키 비활성화
    - 수동 invoke {"action":"recover"} → 오격리 원상복구
    - EventBridge(rate 1 hour) {"action":"audit"} → 미복구 격리 재통보

대응 유형이 대상에 따라 갈리는 이유:
    EC2 대상이면 네트워크를 끊는 것(SG 교체)이 유효하지만, 자격증명(AccessKey)
    대상이면 탈취된 키를 "어디서든" 쓸 수 있어 인스턴스를 가둬도 소용이 없다.
    그래서 키 자체를 Inactive 로 무효화한다.

모든 대응 결과는 DynamoDB 이력 테이블에 남는다 — SNS 통보는 흘러가면 사라지고
인스턴스 포렌식 태그는 인스턴스가 destroy 되면 함께 사라지기 때문이다.

동작(격리 경로):
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
from datetime import datetime, timedelta, timezone
from typing import Any

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client("ec2")
sns = boto3.client("sns")
iam = boto3.client("iam")
dynamodb = boto3.client("dynamodb")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
MIN_SEVERITY = float(os.environ.get("MIN_SEVERITY", "7"))
QUARANTINE_SG_NAME = os.environ.get("QUARANTINE_SG_NAME", "gochuchamchi-quarantine")
ISOLATION_ENABLED = os.environ.get("ISOLATION_ENABLED", "true").lower() == "true"

# --- (2026-08-12) 자동대응 확장 설정 -----------------------------------------
HISTORY_TABLE = os.environ.get("HISTORY_TABLE", "")
HISTORY_RETENTION_DAYS = int(os.environ.get("HISTORY_RETENTION_DAYS", "90"))
CREDENTIAL_RESPONSE_ENABLED = (
    os.environ.get("CREDENTIAL_RESPONSE_ENABLED", "true").lower() == "true"
)
PROTECTED_ACCESS_KEY_IDS = {
    k.strip() for k in os.environ.get("PROTECTED_ACCESS_KEY_IDS", "").split(",") if k.strip()
}
QUARANTINE_STALE_HOURS = float(os.environ.get("QUARANTINE_STALE_HOURS", "12"))

QUARANTINE_TAG = "gochuchamchi:quarantined"
QUARANTINE_TIME_TAG = "gochuchamchi:quarantine-time"


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

    # ── 미복구 격리 감시 분기 (EventBridge 스케줄이 매시간 호출) ──────
    if event.get("action") == "audit":
        return audit_stale_quarantines()

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

        # ── 1-b. 자격증명 대상 finding: 액세스키 비활성화로 대응 ─────
        #     네트워크 격리(SG 교체)가 통하지 않는 유형이다. 탈취된 키는
        #     "어디서든" 쓸 수 있어 인스턴스를 가둬도 소용이 없으므로,
        #     자격증명 자체를 무효화하는 것이 유일한 실효 대응이다.
        access_key_id, key_user, user_type = extract_access_key(detail)
        if access_key_id:
            return disable_access_key(access_key_id, key_user, user_type, result)

        instance_id = extract_instance_id(detail)
        if not instance_id:
            # S3/EKS 컨트롤플레인 등 — SG 격리로도 키 무효화로도 대응 불가.
            # 통보 경로(Rule 1)가 이미 Discord로 알렸으므로 여기선 기록만.
            result["detail"] = "EC2·자격증명 대상이 아닌 finding — 자동대응 불가, 수동 확인 필요"
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


def extract_access_key(detail: dict[str, Any]) -> tuple[str | None, str | None, str | None]:
    """자격증명 대상 finding 에서 (액세스키ID, 사용자명, 주체유형)을 꺼냅니다.

    GuardDuty 는 resource.accessKeyDetails 에 이 정보를 담는다. userType 이
    IAMUser 일 때만 정적 액세스키라 비활성화가 가능하고, AssumedRole/Root 는
    임시 자격증명이거나 루트라 이 API 로 끌 수 없다.
    """
    resource = detail.get("resource", {})
    if resource.get("resourceType") != "AccessKey":
        return None, None, None

    details = resource.get("accessKeyDetails", {})
    return (
        details.get("accessKeyId"),
        details.get("userName"),
        details.get("userType"),
    )


def disable_access_key(
    access_key_id: str,
    user_name: str | None,
    user_type: str | None,
    result: dict[str, Any],
) -> dict[str, Any]:
    """탈취 의심 액세스키를 Inactive 로 전환합니다(삭제하지 않음).

    삭제가 아니라 비활성화인 이유: 즉시 효력이 있으면서 되돌릴 수 있고, 키
    메타데이터가 남아 포렌식(언제 만들어졌고 마지막에 언제 쓰였나)이 가능하다.
    """
    result["accessKeyId"] = access_key_id
    result["userName"] = user_name or "(unknown)"
    result["userType"] = user_type or "(unknown)"

    # 정적 키가 아니면 이 API 로 손댈 수 없다 — SSO/AssumedRole 이 여기 해당.
    if user_type != "IAMUser" or not user_name:
        result["action"] = "manual-required"
        result["detail"] = (
            f"userType={user_type} — 정적 IAM 액세스키가 아니라 자동 비활성화 불가. "
            "임시 자격증명이면 원 주체(역할/SSO 세션) 차단이 필요하다."
        )
        return finish(result)

    if access_key_id in PROTECTED_ACCESS_KEY_IDS:
        result["action"] = "skipped"
        result["detail"] = f"보호 목록(PROTECTED_ACCESS_KEY_IDS)에 있는 키 — 자동 비활성화 생략, 수동 판단 필요"
        return finish(result)

    if not CREDENTIAL_RESPONSE_ENABLED:
        result["action"] = "dry-run"
        result["detail"] = (
            f"CREDENTIAL_RESPONSE_ENABLED=false — 실제였다면 {user_name} 의 "
            f"{access_key_id} 를 Inactive 로 전환했음"
        )
        return finish(result)

    try:
        iam.update_access_key(
            UserName=user_name,
            AccessKeyId=access_key_id,
            Status="Inactive",
        )
    except iam.exceptions.NoSuchEntityException:
        result["action"] = "skipped"
        result["detail"] = "키 또는 사용자가 이미 없음 — 대응 불필요"
        return finish(result)

    result["action"] = "key-disabled"
    result["detail"] = f"IAM 사용자 {user_name} 의 액세스키 {access_key_id} 를 Inactive 로 전환"
    logger.info("액세스키 %s 비활성화 완료 (user=%s)", access_key_id, user_name)
    return finish(result)


def audit_stale_quarantines() -> dict[str, Any]:
    """격리된 채 오래 방치된 인스턴스를 찾아 재통보합니다.

    격리는 서비스 중단을 동반하므로(노드가 NotReady 로 빠짐) 사람이 잊으면
    안 된다. 매시간 깨어나 quarantine 태그의 격리 시각을 보고 임계를 넘긴
    것만 알린다. 넘긴 게 없으면 조용히 끝난다 — 알림 피로를 만들지 않는다.
    """
    result: dict[str, Any] = {"action": "audit", "detail": ""}

    try:
        response = ec2.describe_instances(
            Filters=[
                {"Name": f"tag:{QUARANTINE_TAG}", "Values": ["true"]},
                {"Name": "instance-state-name", "Values": ["running", "stopping", "stopped"]},
            ]
        )
    except Exception as error:  # noqa: BLE001
        logger.exception("격리 인스턴스 조회 실패")
        result["action"] = "failed"
        result["detail"] = f"{type(error).__name__}: {error}"
        return finish(result)

    now = datetime.now(timezone.utc)
    stale: list[str] = []

    for reservation in response.get("Reservations", []):
        for instance in reservation.get("Instances", []):
            tags = {t["Key"]: t["Value"] for t in instance.get("Tags", [])}
            quarantined_at = tags.get(QUARANTINE_TIME_TAG)
            if not quarantined_at:
                continue
            try:
                started = datetime.fromisoformat(quarantined_at)
            except ValueError:
                continue
            hours = (now - started).total_seconds() / 3600
            if hours >= QUARANTINE_STALE_HOURS:
                stale.append(f"{instance['InstanceId']}({hours:.1f}h)")

    if not stale:
        # 정상 상태 — SNS 로 알리지 않는다(매시간 "이상 없음"은 소음이다)
        result["action"] = "audit-clean"
        result["detail"] = "임계를 넘긴 격리 인스턴스 없음"
        logger.info("격리 감사: 이상 없음")
        return result

    result["action"] = "stale-quarantine"
    result["detail"] = (
        f"{QUARANTINE_STALE_HOURS}시간 이상 격리된 채 방치된 인스턴스 {len(stale)}대: "
        f"{', '.join(stale)} — 조사 후 복구하거나(recover) 종료할 것"
    )
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


def record_history(result: dict[str, Any]) -> None:
    """격리/복구/자격증명 대응 이력을 DynamoDB 에 적재합니다.

    통보(SNS)는 흘러가면 사라진다. "언제 무엇을 왜 격리·복구했는가"가 남아야
    사후 조사와 감사가 가능하다. 적재 실패가 대응 자체를 뒤집으면 안 되므로
    예외는 로그만 남기고 삼킨다.
    """
    if not HISTORY_TABLE:
        return

    now = datetime.now(timezone.utc)
    target = (
        result.get("instanceId")
        or result.get("accessKeyId")
        or result.get("findingId")
        or "unknown"
    )

    item: dict[str, Any] = {
        "targetId": {"S": str(target)},
        "eventTime": {"S": now.isoformat()},
        "action": {"S": str(result.get("action", "none"))},
        "detail": {"S": str(result.get("detail", ""))[:1024]},
        # TTL: 보존 기간이 지나면 DynamoDB 가 자동 삭제 (비용 무한 증가 방지)
        "expiresAt": {"N": str(int((now + timedelta(days=HISTORY_RETENTION_DAYS)).timestamp()))},
    }
    for key in ("findingId", "findingType", "severity", "instanceId", "accessKeyId", "userName"):
        value = result.get(key)
        if value is None:
            continue
        item[key] = {"N": str(value)} if key == "severity" else {"S": str(value)}

    try:
        dynamodb.put_item(TableName=HISTORY_TABLE, Item=item)
    except Exception:  # noqa: BLE001 — 이력 적재 실패가 대응을 뒤집지 않는다
        logger.exception("격리 이력 적재 실패 (대응 자체는 이미 수행됨)")


def finish(result: dict[str, Any]) -> dict[str, Any]:
    """결과를 이력에 남기고 SNS 허브로 발행합니다. Discord Lambda가 렌더링합니다.

    lambda_function.py의 unwrap_events가 SNS Message를 EventBridge 이벤트로
    해석하므로, 같은 봉투 형식(source/detail-type/detail)으로 발행한다.
    """
    record_history(result)

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
