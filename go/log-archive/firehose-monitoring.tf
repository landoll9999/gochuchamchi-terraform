# =============================================================================
# Central log delivery health monitoring
#
# Firehose failures are written to service-owned CloudWatch log groups. Convert
# them to metrics and alarm on both hard errors and delivery backlog/throttling.
# Alarm events are forwarded to the Workload account's existing SNS -> Discord
# notification pipeline; no webhook secret is duplicated in the Log account.
# =============================================================================

locals {
  firehose_delivery_freshness_alarm_seconds = 900
}

resource "aws_cloudwatch_log_metric_filter" "firehose_delivery_errors" {
  for_each = local.cloudwatch_log_delivery_sources

  name           = "gochuchamchi-firehose-${each.key}-delivery-errors"
  log_group_name = aws_cloudwatch_log_group.cloudwatch_log_archive_firehose[each.key].name
  pattern        = "ERROR"

  metric_transformation {
    # Literal log filter patterns do not support extracted dimensions. Keep
    # each delivery source isolated by giving it a distinct metric name.
    name      = "FirehoseDeliveryErrors-${each.key}"
    namespace = "Gochuchamchi/LogArchive"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "firehose_delivery_errors" {
  for_each = local.cloudwatch_log_delivery_sources

  alarm_name          = "gochuchamchi-firehose-${each.key}-delivery-error"
  alarm_description   = "P2: ${each.key} Firehose가 S3 전달 오류를 기록함. 중앙 로그 보존 누락 여부를 즉시 조사할 것."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "FirehoseDeliveryErrors-${each.key}"
  namespace           = "Gochuchamchi/LogArchive"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

}

resource "aws_cloudwatch_metric_alarm" "firehose_delivery_freshness" {
  for_each = local.cloudwatch_log_delivery_sources

  alarm_name          = "gochuchamchi-firehose-${each.key}-delivery-delay"
  alarm_description   = "P3: ${each.key} Firehose의 가장 오래된 미전달 로그가 ${local.firehose_delivery_freshness_alarm_seconds}초를 초과함."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DeliveryToS3.DataFreshness"
  namespace           = "AWS/Firehose"
  period              = 300
  statistic           = "Maximum"
  threshold           = local.firehose_delivery_freshness_alarm_seconds
  treat_missing_data  = "notBreaching"

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive[each.key].name
  }
}

resource "aws_cloudwatch_metric_alarm" "firehose_throttled_records" {
  for_each = local.cloudwatch_log_delivery_sources

  alarm_name          = "gochuchamchi-firehose-${each.key}-throttled-records"
  alarm_description   = "P3: ${each.key} Firehose 입력이 스로틀링되어 일부 로그가 수집되지 않을 수 있음."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ThrottledRecords"
  namespace           = "AWS/Firehose"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  dimensions = {
    DeliveryStreamName = aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive[each.key].name
  }
}

# The notification hub lives in the Workload account. Forward only the Log
# account's Firehose alarm transitions there through the default event bus.
data "aws_iam_policy_document" "firehose_alarm_forwarder_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose_alarm_forwarder" {
  name               = "gochuchamchi-firehose-alarm-forwarder"
  assume_role_policy = data.aws_iam_policy_document.firehose_alarm_forwarder_assume_role.json

  tags = local.cloudwatch_log_archive_tags
}

data "aws_iam_policy_document" "firehose_alarm_forwarder" {
  statement {
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = ["arn:aws:events:${var.region}:${var.workload_account_id}:event-bus/default"]
  }
}

resource "aws_iam_role_policy" "firehose_alarm_forwarder" {
  name   = "gochuchamchi-firehose-alarm-forwarder"
  role   = aws_iam_role.firehose_alarm_forwarder.id
  policy = data.aws_iam_policy_document.firehose_alarm_forwarder.json
}

resource "aws_cloudwatch_event_rule" "firehose_alarm_state_change" {
  name        = "gochuchamchi-firehose-alarm-state-change"
  description = "Firehose 수집 오류·지연 알람을 Workload 알림 허브로 전달합니다."

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = "gochuchamchi-firehose-" }]
      state     = { value = ["ALARM", "OK"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "firehose_alarm_workload_event_bus" {
  rule      = aws_cloudwatch_event_rule.firehose_alarm_state_change.name
  target_id = "ForwardToWorkloadAlertHub"
  arn       = "arn:aws:events:${var.region}:${var.workload_account_id}:event-bus/default"
  role_arn  = aws_iam_role.firehose_alarm_forwarder.arn
}
