data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  normalized_s3_key_prefix = trim(var.s3_key_prefix, "/")
  config_s3_object_prefix = local.normalized_s3_key_prefix == "" ? (
    "AWSLogs/${data.aws_caller_identity.current.account_id}/Config"
    ) : (
    "${local.normalized_s3_key_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config"
  )
}

# AWS Config가 계정 내 리소스 구성을 조회하고 S3로 전달할 때 사용할 역할

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid    = "AllowAWSConfigAssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        "arn:${data.aws_partition.current.partition}:config:*:${data.aws_caller_identity.current.account_id}:*"
      ]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-aws-config"
  description        = "Allows AWS Config to record resources and deliver history to S3"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(
    var.tags,
    {
      Name      = "${var.name_prefix}-aws-config"
      Component = "aws-config"
    }
  )
}

resource "aws_iam_role_policy_attachment" "config_role" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

# 같은 계정의 기존 중앙 로그 버킷에 Config 이력과 스냅샷을 기록

data "aws_iam_policy_document" "s3_delivery" {
  statement {
    sid    = "CheckConfigDeliveryBucket"
    effect = "Allow"

    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketLocation",
      "s3:ListBucket"
    ]

    resources = [var.s3_bucket_arn]
  }

  statement {
    sid    = "WriteConfigHistory"
    effect = "Allow"

    actions = ["s3:PutObject"]

    resources = [
      "${var.s3_bucket_arn}/${local.config_s3_object_prefix}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_iam_role_policy" "s3_delivery" {
  name   = "${var.name_prefix}-aws-config-s3-delivery"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.s3_delivery.json
}

# 모든 현재/미래 지원 리소스를 지속적으로 기록

resource "aws_config_configuration_recorder" "this" {
  name     = "${var.name_prefix}-configuration-recorder"
  role_arn = aws_iam_role.this.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = var.include_global_resource_types

    recording_strategy {
      use_only = "ALL_SUPPORTED_RESOURCE_TYPES"
    }
  }

  recording_mode {
    recording_frequency = "CONTINUOUS"
  }

  depends_on = [
    aws_iam_role_policy_attachment.config_role,
    aws_iam_role_policy.s3_delivery
  ]
}

# Configuration Recorder가 수집한 이력/스냅샷을 중앙 S3로 전달

resource "aws_config_delivery_channel" "this" {
  name           = "${var.name_prefix}-delivery-channel"
  s3_bucket_name = var.s3_bucket_name
  s3_key_prefix  = local.normalized_s3_key_prefix == "" ? null : local.normalized_s3_key_prefix

  snapshot_delivery_properties {
    delivery_frequency = var.snapshot_delivery_frequency
  }

  depends_on = [
    aws_config_configuration_recorder.this,
    aws_iam_role_policy.s3_delivery
  ]
}

# Delivery Channel이 만들어진 뒤 Recorder를 시작해야 함

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true

  depends_on = [
    aws_config_delivery_channel.this
  ]
}