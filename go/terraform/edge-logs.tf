# =============================================================================
# Edge logs for the CloudFront + WAF resources defined in edge.tf
#
# This file intentionally does not create another distribution or Web ACL.
# WAF request logs are stored in CloudWatch Logs, and CloudFront standard
# access logs (v2) are delivered to a private, encrypted S3 bucket.
# =============================================================================

locals {
  edge_log_tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "edge-logs"
  }
}

# -----------------------------------------------------------------------------
# WAF request logs -> CloudWatch Logs (CloudFront-scoped WAF uses us-east-1)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "waf" {
  provider = aws.us_east_1

  # AWS WAF log destinations must start with aws-waf-logs-.
  name              = "aws-waf-logs-gochuchamchi-edge"
  retention_in_days = var.waf_log_retention_days

  tags = merge(local.edge_log_tags, { Component = "waf-logs" })
}

resource "aws_wafv2_web_acl_logging_configuration" "edge" {
  provider = aws.us_east_1

  resource_arn            = aws_wafv2_web_acl.edge.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]

  # Keep credentials and session data out of request logs.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}


# -----------------------------------------------------------------------------
# WAF 공격 알람 (CloudFront WAF metric/log는 us-east-1에 존재)
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "waf_total_blocked" {
  provider = aws.us_east_1

  alarm_name        = "gochuchamchi-waf-total-blocked"
  alarm_description = "5분 동안 WAF 전체 차단 요청이 임계값을 초과했습니다. WAF 로그에서 IP, URI, terminatingRuleId를 확인하세요."

  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.waf_total_blocked_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = "gochuchamchi-edge-waf"
    Rule   = "ALL"
  }

  tags = merge(local.edge_log_tags, { Component = "waf-alarm" })
}

resource "aws_cloudwatch_metric_alarm" "waf_rate_blocked" {
  provider = aws.us_east_1

  alarm_name        = "gochuchamchi-waf-rate-limit-blocked"
  alarm_description = "WAF Rate Limit 규칙이 요청을 차단했습니다. 자동화 공격 또는 L7 요청 폭주 여부를 확인하세요."

  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = var.waf_rate_blocked_alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = "gochuchamchi-edge-waf"
    Rule   = "gochuchamchi-rate-limit"
  }

  tags = merge(local.edge_log_tags, { Component = "waf-alarm" })
}

resource "aws_cloudwatch_metric_alarm" "waf_sqli_blocked" {
  provider = aws.us_east_1

  alarm_name        = "gochuchamchi-waf-sqli-blocked"
  alarm_description = "AWS Managed SQLi Rule Group이 공격성 요청을 차단했습니다. 차단된 공격 시도로 분류하고 앱/DB 영향 여부를 조사하세요."

  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = "gochuchamchi-edge-waf"
    Rule   = "gochuchamchi-sqli"
  }

  tags = merge(local.edge_log_tags, { Component = "waf-alarm" })
}

resource "aws_cloudwatch_metric_alarm" "waf_known_bad_blocked" {
  provider = aws.us_east_1

  alarm_name        = "gochuchamchi-waf-known-bad-blocked"
  alarm_description = "AWS Known Bad Inputs Rule Group이 알려진 악성 입력을 차단했습니다. 반복 IP와 대상 URI를 조사하세요."

  namespace           = "AWS/WAFV2"
  metric_name         = "BlockedRequests"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    WebACL = "gochuchamchi-edge-waf"
    Rule   = "gochuchamchi-known-bad-inputs"
  }

  tags = merge(local.edge_log_tags, { Component = "waf-alarm" })
}


# -----------------------------------------------------------------------------
# us-east-1 WAF 알람 상태 변경 -> 서울 리전 기존 SNS/Discord 알림 허브
# -----------------------------------------------------------------------------

data "aws_caller_identity" "edge_current" {
  provider = aws.us_east_1
}

data "aws_iam_policy_document" "eventbridge_assume_role_waf" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "waf_alarm_region_forwarder" {
  name               = "gochuchamchi-waf-alarm-region-forwarder"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume_role_waf.json

  tags = merge(local.edge_log_tags, { Component = "waf-alarm-forwarder" })
}

data "aws_iam_policy_document" "waf_alarm_region_forwarder" {
  statement {
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = ["arn:aws:events:${var.region}:${data.aws_caller_identity.edge_current.account_id}:event-bus/default"]
  }
}

resource "aws_iam_role_policy" "waf_alarm_region_forwarder" {
  name   = "gochuchamchi-waf-alarm-region-forwarder"
  role   = aws_iam_role.waf_alarm_region_forwarder.id
  policy = data.aws_iam_policy_document.waf_alarm_region_forwarder.json
}

resource "aws_cloudwatch_event_rule" "waf_alarm_state_change" {
  provider = aws.us_east_1

  name        = "gochuchamchi-waf-alarm-state-change"
  description = "WAF CloudWatch Alarm 상태 변경을 서울 리전 알림 허브로 전달합니다."

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = "gochuchamchi-waf-" }]
      state = {
        value = ["ALARM", "OK"]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "waf_alarm_seoul_event_bus" {
  provider = aws.us_east_1

  rule      = aws_cloudwatch_event_rule.waf_alarm_state_change.name
  target_id = "ForwardWafAlarmToSeoul"
  arn       = "arn:aws:events:${var.region}:${data.aws_caller_identity.edge_current.account_id}:event-bus/default"
  role_arn  = aws_iam_role.waf_alarm_region_forwarder.arn
}

# -----------------------------------------------------------------------------
# CloudFront standard access logs (v2) -> encrypted private S3
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "cloudfront_logs" {
  bucket        = "gochuchamchi-cloudfront-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = merge(local.edge_log_tags, {
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

# CloudFront standard logging v2 is configured through the CloudWatch Logs API
# in us-east-1, even when the S3 destination bucket is in another Region.
resource "aws_cloudwatch_log_delivery_source" "cloudfront" {
  provider = aws.us_east_1
  count    = var.enable_edge ? 1 : 0

  name         = "gochuchamchi-cloudfront-access-logs"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.edge[0].arn
}

resource "aws_cloudwatch_log_delivery_destination" "cloudfront_s3" {
  provider = aws.us_east_1

  name          = "gochuchamchi-cloudfront-s3"
  output_format = "parquet"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.cloudfront_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "cloudfront_s3" {
  provider = aws.us_east_1
  count    = var.enable_edge ? 1 : 0

  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront_s3.arn

  s3_delivery_configuration {
    enable_hive_compatible_path = true
    suffix_path                 = "/{distributionid}/{yyyy}/{MM}/{dd}/{HH}"
  }

  depends_on = [aws_s3_bucket_policy.cloudfront_logs]
}

# -----------------------------------------------------------------------------
# Log outputs (the edge resource outputs remain in edge.tf)
# -----------------------------------------------------------------------------

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID; null while enable_edge is false"
  value       = try(aws_cloudfront_distribution.edge[0].id, null)
}

output "waf_log_group_name" {
  description = "CloudWatch Logs group receiving WAF request logs"
  value       = aws_cloudwatch_log_group.waf.name
}

output "cloudfront_log_bucket_name" {
  description = "S3 bucket receiving CloudFront standard access logs"
  value       = aws_s3_bucket.cloudfront_logs.id
}
