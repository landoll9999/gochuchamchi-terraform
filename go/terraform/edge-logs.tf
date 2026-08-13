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

# 버킷 본체는 ../persistent/cloudfront-logs.tf 로 옮겼다 (2026-08-12).
#   이 루트는 매일 밤 destroy 되는 일일 계층이라, 버킷이 여기 있으면 로그가 매일
#   같이 사라진다. 그것을 막으려고 걸어둔 force_destroy = false 는 보존 장치가
#   아니라 teardown 을 실패시키는 장치였고, 실제로 8/12 저녁 daily-down 이
#   BucketNotEmpty 로 멈췄다. 증적을 남기는 것이 목적이므로 상시 계층으로 옮겼다.
#
#   여기서는 읽기만 한다. 따라서 ../persistent 를 먼저 apply 해야 한다
#   (ecr.tf, kms-data.tf 와 같은 계약).
data "aws_s3_bucket" "cloudfront_logs" {
  bucket = "gochuchamchi-cloudfront-logs-${data.aws_caller_identity.current.account_id}"
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
    destination_resource_arn = data.aws_s3_bucket.cloudfront_logs.arn
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

  # 예전에는 aws_s3_bucket_policy.cloudfront_logs 를 depends_on 으로 걸었다. 로그
  # 전송이 만들어지기 전에 버킷 정책이 delivery.logs.amazonaws.com 을 허용하고 있어야
  # 하기 때문이다. 정책이 ../persistent 로 옮겨간 지금은 계층 순서(상시 먼저 apply)가
  # 그 보장을 대신한다.
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
  description = "S3 bucket receiving CloudFront standard access logs (owned by ../persistent)"
  value       = data.aws_s3_bucket.cloudfront_logs.id
}
