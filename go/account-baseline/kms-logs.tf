# =============================================================================
# KMS CMK — "전 구간 KMS CMK 암호화" (격차분석 §2.4, 계획 D12)
#
# 기존 상태: S3=AES256(S3 관리 키), EFS=AWS 관리 키, RDS/Redis 키 미지정.
# 암호화 자체는 되어 있었지만 키 관리 주체가 AWS였다 — 아키텍처 그림의
# "전 구간 KMS CMK" 문구와 맞추기 위해 고객 관리 키(CMK)로 전환한다.
#
# 키 분리 원칙 (용도별 2개):
#   - logs: 중앙 로그 버킷 전용. CloudTrail/Config/Firehose/Flow Logs 서비스가
#           쓸 수 있도록 키 정책에 명시적 허용이 필요해서 분리.
#   - data: RDS/EFS 등 워크로드 데이터. 서비스 통합(grant) 방식이라
#           기본 키 정책(계정 루트 위임)으로 충분.
#
# ⚠️ 적용 시 재생성되는 리소스 (기존 스택에 그대로 apply하면 안 되는 항목):
#   - RDS: 암호화 키 변경은 인스턴스 교체를 유발 → DB 데이터 소실
#     (rds-schema-init.tf가 스키마는 자동 복구하지만 "데이터"는 아님)
#   - EFS: 파일시스템 교체 → 저장 파일 소실
#   다음 전체 재구축(destroy→apply) 사이클에서 함께 반영하는 것을 권장.
#
# 예외로 남긴 것 (사유 문서화):
#   - images S3 버킷: 상품 이미지를 익명(public read)으로 서빙 중인데,
#     SSE-KMS 객체는 익명 읽기가 불가능하다 → AES256 유지 (보안점검 때
#     "S3 이미지 퍼블릭 읽기 의도적 유지"로 이미 문서화된 항목의 연장)
#   - Redis: aws_elasticache_cluster 리소스는 at-rest KMS 지정을 지원하지
#     않는다(replication_group 전환 필요) → redis.tf의 주석 참고
#   - ECR: 암호화 방식 변경은 저장소 교체를 유발하는데, 저장소 교체는 이미지
#     소실 → ImagePullBackOff 503 사고(07/30·07/31 2회 재발)를 그대로 다시
#     일으킨다 → AES256 유지
# =============================================================================

resource "aws_kms_key" "logs" {
  description             = "gochuchamchi 중앙 로그 아카이브 암호화 (CloudTrail/Config/Firehose/Flow Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # 실습 환경 최소값. 운영 전환 시 30일 권장

  policy = data.aws_iam_policy_document.kms_logs.json

  tags = merge(
    local.cloudwatch_log_archive_tags,
    { Name = "gochuchamchi-logs-cmk" }
  )
}

resource "aws_kms_alias" "logs" {
  name          = "alias/gochuchamchi-logs"
  target_key_id = aws_kms_key.logs.key_id
}

data "aws_iam_policy_document" "kms_logs" {
  # 계정 루트 위임 — IAM 정책 기반 접근(관리자, Athena 조회 등)을 가능하게 하는
  # 표준 문구. 이게 없으면 키가 "관리 불가" 상태가 될 수 있다.
  statement {
    sid    = "EnableIAMPolicies"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # CloudTrail이 로그 객체를 암호화할 때
  statement {
    sid    = "AllowCloudTrailEncrypt"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.cloudtrail_arn]
    }
  }

  # VPC Flow Logs(S3 전달)와 AWS Config의 S3 기록
  statement {
    sid    = "AllowLogDeliveryServices"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "delivery.logs.amazonaws.com",
        "config.amazonaws.com"
      ]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # 이 계정의 gochuchamchi-* IAM 역할(Firehose 전달 역할, Config 커스텀 역할 등)이
  # 로그 버킷에 쓰기/읽기할 때. 역할 ARN을 직접 참조하면 module.aws_config와
  # 순환 의존이 생겨서(버킷 암호화 -> 키 -> Config 역할 -> Config 모듈 -> 버킷
  # 암호화 depends_on) 이름 패턴 조건으로 푼다.
  statement {
    sid    = "AllowProjectRoles"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt"
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/gochuchamchi-*"]
    }
  }
}


# =============================================================================
# Outputs
# =============================================================================

output "kms_logs_key_arn" {
  description = "중앙 로그 아카이브 CMK ARN"
  value       = aws_kms_key.logs.arn
}
