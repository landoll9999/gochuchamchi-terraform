# =============================================================================
# CloudFront 액세스 로그 버킷 — 상시 계층
#
# 왜 여기 있나 (2026-08-12 이전)
#   원래 ../terraform(일일 계층)에 있었다. 그런데 일일 계층은 매일 밤 destroy 되는
#   곳이라, 버킷이 그 안에 있으면 로그가 매일 밤 같이 사라진다. 그걸 막으려고
#   force_destroy = false 가 걸려 있었는데, 그건 보존 장치가 아니라 **teardown 을
#   실패시키는 장치**였다. 실제로 2026-08-12 저녁 daily-down 이
#     BucketNotEmpty: The bucket you tried to delete is not empty
#   로 멈췄다. 8/11 로그가 그때까지 남아 있던 것도 "보존이 됐다"가 아니라
#   "destroy 가 계속 실패했다"는 뜻이었다.
#
#   증적을 남기는 것이 목적이므로 버킷을 상시 계층으로 옮긴다. 이제 로그는 날짜를
#   넘겨 누적되고, 일일 계층은 깨끗하게 지워진다.
#
# 일일 계층과의 인터페이스
#   ../terraform 은 이 버킷을 data "aws_s3_bucket" 으로 읽기만 한다(edge-logs.tf).
#   따라서 **이 루트를 먼저 apply 해야 일일 계층 apply 가 성립한다** — ecr.tf,
#   kms-data.tf 와 같은 계약이다.
#
#   버킷 정책이 CloudFront 배포 ARN 을 참조하지 않는 것이 이 분리가 가능한 이유다.
#   delivery-source 를 와일드카드로 허용하므로, 배포가 매일 새로 만들어져도 정책은
#   그대로 유효하다.
# =============================================================================

locals {
  cloudfront_log_tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "edge-logs"
  }
}

resource "aws_s3_bucket" "cloudfront_logs" {
  bucket = "gochuchamchi-cloudfront-logs-${data.aws_caller_identity.current.account_id}"

  # 상시 계층이라 실수로 지워지면 증적이 사라진다. 비우고 지우는 것은 의도적으로
  # 어렵게 둔다(일일 계층에 있을 때와 달리 여기서는 teardown 을 막지 않는다).
  force_destroy = false

  tags = merge(local.cloudfront_log_tags, {
    Name      = "gochuchamchi-cloudfront-logs"
    Component = "cloudfront-logs"
  })
}

resource "aws_s3_bucket_ownership_controls" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    id     = "archive-cloudfront-access-logs"
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
      days = var.cdn_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "cloudfront_logs" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cloudfront_logs.arn,
      "${aws_s3_bucket.cloudfront_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.cloudfront_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:delivery-source:*"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudfront_logs.arn}/*"]

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

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:delivery-source:*"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id
  policy = data.aws_iam_policy_document.cloudfront_logs.json

  depends_on = [
    aws_s3_bucket_ownership_controls.cloudfront_logs,
    aws_s3_bucket_public_access_block.cloudfront_logs
  ]
}

output "cloudfront_log_bucket_name" {
  description = "CloudFront 액세스 로그를 받는 S3 버킷 (일일 계층이 data 로 읽는다)"
  value       = aws_s3_bucket.cloudfront_logs.id
}

output "cloudfront_log_bucket_arn" {
  description = "CloudFront 액세스 로그 버킷 ARN"
  value       = aws_s3_bucket.cloudfront_logs.arn
}
