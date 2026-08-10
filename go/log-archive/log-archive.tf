# =============================================================================
# 중앙 로그 S3 아카이브 — 로그 계정 버전
#
# ../account-baseline/log-archive.tf 에서 이식. 달라진 것:
#   1. Object Lock COMPLIANCE — 구 버킷에서 "생성 시점에만 켤 수 있어 보류"였던
#      것을 신규 생성인 지금 반영. 버킷 정책 Deny는 정책이 지워지면 같이 사라지지만
#      Object Lock은 보존기간 동안 루트도 못 푼다.
#   2. 쓰기 허용 조건이 전부 크로스 계정 — CloudTrail은 org trail 경로(management
#      계정 + org ID 경로 둘 다), Flow Logs는 워크로드 계정 SourceAccount.
#   3. Log Destination 신설 — 워크로드 계정의 구독 필터는 다른 계정의 Firehose를
#      직접 못 가리키므로, 이 계정에 수신 창구(destination)를 만들고 destination
#      policy로 워크로드 계정을 인가한다.
# =============================================================================

locals {
  cloudwatch_log_archive_sources = toset(["application", "control-plane"])

  cloudwatch_log_archive_tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "central-log-archive"
  }

  # 불변성 Deny 예외 주체. 비워두면 현재 apply를 돌리는 주체(log-admin IAM user —
  # 직접 프로파일이라 ARN이 고정)가 들어간다. baseline과 같은 방식.
  cloudwatch_log_archive_admin_arns = length(var.cloudwatch_log_archive_admin_arns) > 0 ? var.cloudwatch_log_archive_admin_arns : [data.aws_caller_identity.current.arn]

  # Org Trail은 Management 계정 소유이며 ../management/audit에서 관리한다.
  # Log 계정의 버킷/KMS 정책은 Management 소유 Trail ARN만 신뢰한다.
  cloudtrail_name          = "gochuchamchi-org-trail"
  cloudtrail_s3_key_prefix = "cloudtrail"
  cloudtrail_arn           = "arn:aws:cloudtrail:${var.region}:${var.management_account_id}:trail/${local.cloudtrail_name}"

  vpc_flow_logs_s3_prefix = "vpc-flow-logs"
}


# =============================================================================
# 중앙 로그 S3 버킷
# =============================================================================

resource "aws_s3_bucket" "cloudwatch_log_archive" {
  # 구(舊) 워크로드 시절의 버킷(gochuchamchi-cloudwatch-log-archive-...)과 이름을
  # 다르게 둔다 — 구 인프라 teardown이 어디까지 되든 충돌하지 않도록.
  # 이 이름은 ../terraform/flow-logs.tf 가 ARN 조립으로 재현한다 — 바꾸면 같이 바꿀 것.
  bucket = "gochuchamchi-log-archive-${data.aws_caller_identity.current.account_id}"

  # Object Lock은 생성 시점에만 켤 수 있다 (구 버킷이 못 켠 이유).
  # 켜면 versioning이 강제된다.
  object_lock_enabled = true

  force_destroy = false

  tags = merge(
    local.cloudwatch_log_archive_tags,
    {
      Name = "gochuchamchi-log-archive"
    }
  )
}

resource "aws_s3_bucket_object_lock_configuration" "cloudwatch_log_archive" {
  bucket = aws_s3_bucket.cloudwatch_log_archive.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.log_archive_object_lock_days
    }
  }
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
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.logs.arn
    }
    bucket_key_enabled = true # 객체마다 KMS 호출하지 않도록 -> KMS 비용 절감
  }
}

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

    # Object Lock 보존기간(기본 30일)이 지난 버전만 실제로 정리된다 —
    # 수명주기는 잠긴 버전을 건너뛰었다가 잠금 해제 후 정리한다.
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [
    aws_s3_bucket_versioning.cloudwatch_log_archive
  ]
}


# =============================================================================
# 중앙 로그 버킷 정책 — 쓰기 주체가 전부 "다른 계정"인 것이 baseline과의 차이
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

  # org trail의 배달 경로는 두 갈래다:
  #   management 계정 자신의 이벤트         -> AWSLogs/<management계정ID>/*
  #   멤버 계정(워크로드) 이벤트            -> AWSLogs/<org-ID>/<워크로드계정ID>/*
  # 둘 다 열어야 org trail 생성이 통과된다. 조사 대상인 워크로드 이벤트는
  # 두 번째 경로(org 경로)로 온다 — Athena 테이블(athena.tf)이 그걸 본다.
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
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/${local.cloudtrail_s3_key_prefix}/AWSLogs/${var.management_account_id}/*",
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/${local.cloudtrail_s3_key_prefix}/AWSLogs/${local.org_id}/*"
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

  # VPC Flow Logs — 보내는 쪽이 이제 워크로드 계정이다
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
      values   = [local.workload_account_id]
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
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/${local.vpc_flow_logs_s3_prefix}/AWSLogs/${local.workload_account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.workload_account_id]
    }
  }

  # ---------------------------------------------------------------------------
  # 불변성 Deny — Object Lock이 1차 방어가 됐지만 그대로 유지한다.
  # Object Lock은 "보존기간 내 버전 삭제"만 막고, 이 Deny는 정책 변조와
  # 보존기간 지난 객체의 API 삭제까지 막는다 (수명주기 만료는 영향 없음).
  # 워크로드 계정 주체는 여기 예외 목록에 없으므로 구조적으로 차단된다 —
  # 이 계층을 분리한 목적 그 자체.
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

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.cloudwatch_log_archive_admin_arns
    }
  }

  statement {
    sid    = "DenyPolicyTampering"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = [
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy"
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn
    ]

    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.cloudwatch_log_archive_admin_arns
    }
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
# Firehose -> S3
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
# Log Destination — 워크로드 계정의 구독 필터가 가리킬 수신 창구 (크로스 계정 신설분)
#
# 같은 계정일 때는 구독 필터가 Firehose ARN을 직접 가리켰지만(구 baseline 방식),
# 크로스 계정에서는 반드시 destination을 거쳐야 한다. 인가도 두 단계로 갈린다:
#   - destination policy: "워크로드 계정이 이 destination을 구독해도 된다"
#   - destination의 role: "logs 서비스가 이 계정의 Firehose에 넣어도 된다"
# 워크로드 쪽 구독 필터에는 role_arn을 넣지 않는다.
# =============================================================================

data "aws_iam_policy_document" "logs_destination_assume_role" {
  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type = "Service"
      identifiers = [
        "logs.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole"
    ]

    # 발신자(워크로드 계정)의 로그 그룹에서 온 요청만 이 롤을 쓸 수 있다
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:logs:${var.region}:${local.workload_account_id}:*"
      ]
    }
  }
}

resource "aws_iam_role" "logs_destination" {
  name               = "gochuchamchi-logs-destination"
  assume_role_policy = data.aws_iam_policy_document.logs_destination_assume_role.json

  tags = local.cloudwatch_log_archive_tags
}

data "aws_iam_policy_document" "logs_destination" {
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

resource "aws_iam_role_policy" "logs_destination" {
  name   = "gochuchamchi-logs-destination"
  role   = aws_iam_role.logs_destination.id
  policy = data.aws_iam_policy_document.logs_destination.json
}

# 이름은 ../terraform/log-archive-subscriptions.tf 가 ARN 조립으로 참조한다 —
# 바꾸면 그쪽 조립식도 함께 바꿀 것.
resource "aws_cloudwatch_log_destination" "cloudwatch_log_archive" {
  for_each = local.cloudwatch_log_archive_sources

  name       = "gochuchamchi-${each.key}-log-archive"
  role_arn   = aws_iam_role.logs_destination.arn
  target_arn = aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive[each.key].arn

  depends_on = [aws_iam_role_policy.logs_destination]
}

data "aws_iam_policy_document" "logs_destination_access" {
  statement {
    sid    = "AllowWorkloadAccountSubscription"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [local.workload_account_id]
    }

    actions = [
      "logs:PutSubscriptionFilter"
    ]

    resources = [
      for dest in values(aws_cloudwatch_log_destination.cloudwatch_log_archive) :
      dest.arn
    ]
  }
}

resource "aws_cloudwatch_log_destination_policy" "cloudwatch_log_archive" {
  for_each = aws_cloudwatch_log_destination.cloudwatch_log_archive

  destination_name = each.value.name
  access_policy    = data.aws_iam_policy_document.logs_destination_access.json
}


# =============================================================================
# Outputs
# =============================================================================

output "cloudwatch_log_archive_bucket_name" {
  description = "중앙 아카이브 S3 버킷 이름"
  value       = aws_s3_bucket.cloudwatch_log_archive.bucket
}

output "cloudwatch_log_archive_bucket_arn" {
  description = "중앙 아카이브 S3 버킷 ARN"
  value       = aws_s3_bucket.cloudwatch_log_archive.arn
}

output "cloudwatch_log_destination_arns" {
  description = "워크로드 계정 구독 필터가 가리킬 destination ARN (terraform/은 이걸 ARN 조립으로 재현한다)"
  value = {
    for name, dest in aws_cloudwatch_log_destination.cloudwatch_log_archive :
    name => dest.arn
  }
}
