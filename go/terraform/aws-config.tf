# =============================================================================
# AWS Config -> 전용 S3 버킷 (2026-08-03 중앙 로그 버킷에서 분리)
#
# CloudTrail이 "누가 무엇을 했는가"를 남긴다면, AWS Config는 "리소스가 지금 어떤
# 상태이고 언제 어떻게 바뀌었는가"를 남깁니다.
# Security Hub 보안 표준 대부분이 이 Config 기록을 근거로 평가하므로,
# security-hub.tf보다 먼저 적용되어야 합니다(module.security_hub의 depends_on).
#
# ⚠️ 분리 사유 (2026-08-03 실제 장애):
#   원래는 중앙 로그 버킷(cloudwatch-log-archive.tf)에 prefix로 넣으려 했지만,
#   그 버킷의 불변성 통제(DenyObjectDeletion, DenyPolicyTampering, Object Lock
#   COMPLIANCE)가 Config의 전달 검사(PutDeliveryChannel writability check)와
#   충돌해서 InsufficientDeliveryPolicyException이 반복됐다. 역할 정책 ACL 조건
#   완화 → KMS 키 지정/권한 부여 → 버킷 정책 Config 허용 3문구 추가까지 해도
#   해소되지 않았고, 통제를 더 열면 불변성 장치 자체가 약해진다.
#   → 증적 등급이 다르다: CloudTrail/FlowLogs는 포렌식 증거(불변 보관 필수),
#     Config 이력은 재구성 가능한 구성 스냅샷. 등급이 다른 데이터를 같은
#     통제에 묶지 않고 버킷을 분리하는 것이 맞다고 판단 (표준 구성 회귀).
#   면접 포인트: "과도한 하드닝이 정당한 서비스 동작을 막는 것을 실제로 겪고,
#   데이터 등급별로 통제 수준을 분리했다"
#
# 저장 경로: s3://gochuchamchi-aws-config-<계정ID>/config/AWSLogs/<계정ID>/Config/
# =============================================================================

locals {
  aws_config_s3_key_prefix = "config"
}

# ---------------------------------------------------------------------------
# Config 전용 버킷 — 표준 구성 (불변성 Deny 없음, CMK 암호화는 유지)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "aws_config" {
  bucket = "gochuchamchi-aws-config-${data.aws_caller_identity.current.account_id}"

  # destroy/apply 재구축 주기에 맞춰 자동 비우기 (구성 이력은 재구성 가능한 데이터)
  force_destroy = true

  tags = merge(
    local.cloudwatch_log_archive_tags,
    { Name = "gochuchamchi-aws-config", Component = "aws-config" }
  )
}

resource "aws_s3_bucket_public_access_block" "aws_config" {
  bucket                  = aws_s3_bucket.aws_config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "aws_config" {
  bucket = aws_s3_bucket.aws_config.id

  rule {
    apply_server_side_encryption_by_default {
      # 전 구간 CMK 원칙 유지 — 로그 CMK 재사용 (키 정책이 config 서비스와
      # gochuchamchi-* 역할을 이미 허용함: kms.tf AllowLogDeliveryServices/AllowProjectRoles)
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "aws_config" {
  bucket = aws_s3_bucket.aws_config.id

  rule {
    id     = "expire-config-history"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }
  }
}

# AWS 문서 표준 버킷 정책 (Config 서비스 주체) + TLS 강제.
# 여기는 DenyObjectDeletion/DenyPolicyTampering을 일부러 넣지 않는다 — 분리 사유 참고.
data "aws_iam_policy_document" "aws_config_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.aws_config.arn,
      "${aws_s3_bucket.aws_config.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AWSConfigBucketPermissionsCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.aws_config.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSConfigBucketExistenceCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.aws_config.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSConfigBucketDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    actions = ["s3:PutObject"]

    resources = [
      "${aws_s3_bucket.aws_config.arn}/${local.aws_config_s3_key_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEqualsIfExists"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "aws_config" {
  bucket = aws_s3_bucket.aws_config.id
  policy = data.aws_iam_policy_document.aws_config_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.aws_config]
}

# ---------------------------------------------------------------------------
# Config 본체 (recorder + delivery channel) — module/aws-config
# ---------------------------------------------------------------------------
module "aws_config" {
  source = "./module/aws-config"

  name_prefix = "gochuchamchi"

  s3_bucket_name = aws_s3_bucket.aws_config.id
  s3_bucket_arn  = aws_s3_bucket.aws_config.arn
  s3_key_prefix  = local.aws_config_s3_key_prefix
  # 버킷이 이 CMK로 강제 암호화되므로 Config에도 알려주고 역할에 키 권한 부여
  kms_key_arn = aws_kms_key.logs.arn

  # IAM User/Role/Policy 같은 글로벌 리소스도 기록.
  # Security Hub의 IAM 관련 Control이 이 기록을 필요로 한다.
  include_global_resource_types = true

  snapshot_delivery_frequency = var.aws_config_snapshot_delivery_frequency

  tags = local.cloudwatch_log_archive_tags

  # 버킷 정책/암호화가 먼저 잡힌 뒤에 Delivery Channel이 만들어져야
  # Config의 전달 테스트(PutObject)가 통과한다. cloudtrail.tf와 동일한 이유.
  depends_on = [
    aws_s3_bucket_policy.aws_config,
    aws_s3_bucket_server_side_encryption_configuration.aws_config
  ]
}


# =============================================================================
# Outputs
# =============================================================================

output "aws_config_recorder_name" {
  description = "AWS Config Configuration Recorder 이름"
  value       = module.aws_config.configuration_recorder_name
}

output "aws_config_role_arn" {
  description = "AWS Config가 사용하는 IAM Role ARN"
  value       = module.aws_config.iam_role_arn
}

output "aws_config_s3_location" {
  description = "AWS Config 구성 이력/스냅샷이 저장되는 S3 기본 경로"
  value       = module.aws_config.s3_delivery_path
}
