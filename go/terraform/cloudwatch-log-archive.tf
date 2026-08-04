# =============================================================================
# CloudWatch Logs 중앙 S3 아카이브
#
# 실시간 조회는 기존 CloudWatch Logs/Grafana에서 계속 수행하고,
# 새로 유입되는 로그를 Firehose를 통해 S3에 장기 보관합니다.
# =============================================================================

locals {
  cloudwatch_log_archive_sources = {
    application   = aws_cloudwatch_log_group.container_insights_application.name
    control-plane = module.eks.cloudwatch_log_group_name
  }

  cloudwatch_log_archive_tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "central-log-archive"
  }
}


# =============================================================================
# 중앙 로그 S3 버킷
# =============================================================================

resource "aws_s3_bucket" "cloudwatch_log_archive" {
  bucket = "gochuchamchi-cloudwatch-log-archive-${data.aws_caller_identity.current.account_id}"

  # 중앙 로그는 실수로 함께 삭제되지 않도록 보호
  force_destroy = false

  tags = merge(
    local.cloudwatch_log_archive_tags,
    {
      Name = "gochuchamchi-cloudwatch-log-archive"
    }
  )
}

resource "aws_s3_bucket_ownership_controls" "cloudwatch_log_archive" {
  bucket = aws_s3_bucket.cloudwatch_log_archive.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudwatch_log_archive" {
  bucket = aws_s3_bucket.cloudwatch_log_archive.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "cloudwatch_log_archive" {
  bucket = aws_s3_bucket.cloudwatch_log_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudwatch_log_archive" {
  bucket = aws_s3_bucket.cloudwatch_log_archive.id

  rule {
    apply_server_side_encryption_by_default {
      # (2026-08-03 full-HA에서 복원) 로그 전용 CMK로 암호화 (kms.tf).
      # CloudTrail/Firehose/Flow Logs가 이 키를 쓸 수 있는 권한은 키 정책 쪽에 있다.
      # 기존 객체는 AES256 그대로 남고 신규 객체부터 KMS 적용 — in-place 변경.
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true # 객체마다 KMS 호출하지 않도록 -> KMS 비용 절감
  }
}

# (복원 보류) Object Lock — fin 라인은 버킷 생성 시 object_lock_enabled=true +
# COMPLIANCE 30일 잠금이었으나, Object Lock은 "생성 시점"에만 켤 수 있어 기존
# 버킷에 적용하면 버킷 교체(로그 소실 또는 이관 필요)가 계획된다.
# 다음 전체 재구축 사이클에서 반영할 것 (fin의 variables: log_archive_object_lock_*).
# 그때까지는 아래 버킷 정책의 DenyObjectDeletion이 API 경유 삭제를 차단한다.

resource "aws_s3_bucket_lifecycle_configuration" "cloudwatch_log_archive" {
  bucket = aws_s3_bucket.cloudwatch_log_archive.id

  rule {
    id     = "archive-cloudwatch-logs"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.cloudwatch_log_archive_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.cloudwatch_log_archive
  ]
}


# =============================================================================
# 중앙 로그 버킷 정책
# =============================================================================

data "aws_iam_policy_document" "cloudwatch_log_archive_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:*"
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn,
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AWSCloudTrailAclCheck"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "cloudtrail.amazonaws.com"
      ]
    }

    actions = [
      "s3:GetBucketAcl"
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.cloudtrail_arn]
    }
  }

  statement {
    sid    = "AWSCloudTrailWrite"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "cloudtrail.amazonaws.com"
      ]
    }

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/${local.cloudtrail_s3_key_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.cloudtrail_arn]
    }
  }

  # ---------------------------------------------------------------------------
  # (2026-08-03 full-HA에서 복원) VPC Flow Logs 전달 (flow-logs.tf)
  # delivery.logs 서비스가 쓴다
  # ---------------------------------------------------------------------------
  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions = [
      "s3:GetBucketAcl"
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions = [
      "s3:PutObject"
    ]

    resources = [
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/${local.vpc_flow_logs_s3_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  # ---------------------------------------------------------------------------
  # (2026-08-03 full-HA에서 복원) 로그 불변성 보강 — API 경유 삭제와 정책 변조를
  # 명시적으로 거부. 침해자가 admin 자격증명을 얻어도 증거 로그를 지우거나
  # 이 정책을 풀 수 없게 하는 목적.
  #
  # ⚠️ 복구 경로: 버킷 소유 계정의 "루트 사용자"만은 DeleteBucketPolicy를 항상
  # 호출할 수 있으므로(S3 명세), 정말 정책을 바꿔야 하면 루트로 정책을 지운 뒤
  # terraform apply로 다시 만든다. 이 정책이 적용된 후에는 Terraform도 이 버킷
  # 정책을 "수정"할 수 없다는 뜻이다 — 라이프사이클 만료는 S3 내부 동작이라
  # 이 Deny의 영향을 받지 않고 계속 정리된다.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "DenyObjectDeletion"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion"
    ]

    resources = [
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/*"
    ]
  }

  statement {
    sid    = "DenyPolicyTampering"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:PutBucketPolicy"
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn
    ]
  }
}

resource "aws_s3_bucket_policy" "cloudwatch_log_archive" {
  bucket = aws_s3_bucket.cloudwatch_log_archive.id
  policy = data.aws_iam_policy_document.cloudwatch_log_archive_bucket.json

  depends_on = [
    aws_s3_bucket_ownership_controls.cloudwatch_log_archive,
    aws_s3_bucket_public_access_block.cloudwatch_log_archive
  ]
}


# =============================================================================
# Firehose 자체 오류 로그
# =============================================================================

resource "aws_cloudwatch_log_group" "cloudwatch_log_archive_firehose" {
  for_each = local.cloudwatch_log_archive_sources

  name              = "/aws/kinesisfirehose/gochuchamchi-${each.key}-log-archive"
  retention_in_days = 14

  tags = local.cloudwatch_log_archive_tags
}

resource "aws_cloudwatch_log_stream" "cloudwatch_log_archive_firehose" {
  for_each = local.cloudwatch_log_archive_sources

  name           = "S3Delivery"
  log_group_name = aws_cloudwatch_log_group.cloudwatch_log_archive_firehose[each.key].name
}


# =============================================================================
# Firehose가 S3와 자체 CloudWatch 오류 로그에 접근할 IAM Role
# =============================================================================

data "aws_iam_policy_document" "cloudwatch_log_archive_firehose_assume_role" {
  statement {
    sid    = "AllowFirehose"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "firehose.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}

resource "aws_iam_role" "cloudwatch_log_archive_firehose" {
  name               = "gochuchamchi-cloudwatch-log-archive-firehose"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_log_archive_firehose_assume_role.json

  tags = local.cloudwatch_log_archive_tags
}

data "aws_iam_policy_document" "cloudwatch_log_archive_firehose" {
  statement {
    sid    = "WriteLogArchiveBucket"
    effect = "Allow"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject"
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn,
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/*"
    ]
  }

  statement {
    sid    = "WriteFirehoseErrorLogs"
    effect = "Allow"

    actions = [
      "logs:PutLogEvents"
    ]

    resources = [
      for log_group in values(aws_cloudwatch_log_group.cloudwatch_log_archive_firehose) :
      "${log_group.arn}:log-stream:*"
    ]
  }
}

resource "aws_iam_role_policy" "cloudwatch_log_archive_firehose" {
  name   = "gochuchamchi-cloudwatch-log-archive-firehose"
  role   = aws_iam_role.cloudwatch_log_archive_firehose.id
  policy = data.aws_iam_policy_document.cloudwatch_log_archive_firehose.json
}


# =============================================================================
# CloudWatch Logs -> Firehose -> S3
# =============================================================================

resource "aws_kinesis_firehose_delivery_stream" "cloudwatch_log_archive" {
  for_each = local.cloudwatch_log_archive_sources

  name        = "gochuchamchi-${each.key}-log-archive"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.cloudwatch_log_archive_firehose.arn
    bucket_arn = aws_s3_bucket.cloudwatch_log_archive.arn

    prefix = join("", [
      "cloudwatch/${each.key}/",
      "year=!{timestamp:yyyy}/",
      "month=!{timestamp:MM}/",
      "day=!{timestamp:dd}/",
      "hour=!{timestamp:HH}/"
    ])

    error_output_prefix = join("", [
      "firehose-errors/${each.key}/",
      "!{firehose:error-output-type}/",
      "year=!{timestamp:yyyy}/",
      "month=!{timestamp:MM}/",
      "day=!{timestamp:dd}/"
    ])

    buffering_size     = 5
    buffering_interval = 300
    compression_format = "GZIP"
    file_extension     = ".log.gz"

    # CloudWatch Logs의 gzip payload를 풀고 각 실제 로그 메시지만 추출
    processing_configuration {
      enabled = true

      processors {
        type = "Decompression"
      }

      processors {
        type = "CloudWatchLogProcessing"

        parameters {
          parameter_name  = "DataMessageExtraction"
          parameter_value = "true"
        }
      }
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.cloudwatch_log_archive_firehose[each.key].name
      log_stream_name = aws_cloudwatch_log_stream.cloudwatch_log_archive_firehose[each.key].name
    }
  }

  tags = local.cloudwatch_log_archive_tags

  depends_on = [
    aws_iam_role_policy.cloudwatch_log_archive_firehose,
    aws_s3_bucket_policy.cloudwatch_log_archive,
    aws_s3_bucket_server_side_encryption_configuration.cloudwatch_log_archive
  ]
}


# =============================================================================
# CloudWatch Logs가 Firehose로 전송할 IAM Role
# =============================================================================

data "aws_iam_policy_document" "cloudwatch_logs_to_firehose_assume_role" {
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "logs.${var.region}.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole"
    ]

    condition {
      test     = "StringLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:*"
      ]
    }
  }
}

resource "aws_iam_role" "cloudwatch_logs_to_firehose" {
  name               = "gochuchamchi-cloudwatch-logs-to-firehose"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_logs_to_firehose_assume_role.json

  tags = local.cloudwatch_log_archive_tags
}

data "aws_iam_policy_document" "cloudwatch_logs_to_firehose" {
  statement {
    sid    = "WriteFirehoseStreams"
    effect = "Allow"

    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch"
    ]

    resources = [
      for stream in values(aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive) :
      stream.arn
    ]
  }
}

resource "aws_iam_role_policy" "cloudwatch_logs_to_firehose" {
  name   = "gochuchamchi-cloudwatch-logs-to-firehose"
  role   = aws_iam_role.cloudwatch_logs_to_firehose.id
  policy = data.aws_iam_policy_document.cloudwatch_logs_to_firehose.json
}


# =============================================================================
# 애플리케이션/제어 플레인 로그 구독
# =============================================================================

resource "aws_cloudwatch_log_subscription_filter" "cloudwatch_log_archive" {
  for_each = local.cloudwatch_log_archive_sources

  name            = "gochuchamchi-${each.key}-s3-archive"
  log_group_name  = each.value
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive[each.key].arn
  role_arn        = aws_iam_role.cloudwatch_logs_to_firehose.arn

  depends_on = [
    aws_eks_addon.cloudwatch_observability,
    aws_iam_role_policy.cloudwatch_logs_to_firehose
  ]
}


# =============================================================================
# Outputs
# =============================================================================

output "cloudwatch_log_archive_bucket_name" {
  description = "CloudWatch Logs 중앙 아카이브 S3 버킷 이름"
  value       = aws_s3_bucket.cloudwatch_log_archive.bucket
}

output "cloudwatch_log_archive_bucket_arn" {
  description = "CloudWatch Logs 중앙 아카이브 S3 버킷 ARN"
  value       = aws_s3_bucket.cloudwatch_log_archive.arn
}

output "cloudwatch_log_archive_firehose_arns" {
  description = "로그 유형별 Firehose Delivery Stream ARN"
  value = {
    for name, stream in aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive :
    name => stream.arn
  }
}
