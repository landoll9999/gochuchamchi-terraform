# =============================================================================
# AWS Config 네트워크 비준수 상태 1시간 재알림
#
# 규칙 자체는 ../account-baseline/network-compliance.tf가 소유한다. 이 스택은
# 기존 SNS -> Discord 허브를 재사용해 다음만 담당한다.
#   NON_COMPLIANT  : 매시간 현재 위반 리소스 요약 통보
#   COMPLIANT 복귀: RESOLVED 1회 통보
# 자동 복구 권한과 코드는 의도적으로 두지 않는다.
# =============================================================================

variable "network_config_rule_names" {
  description = "account-baseline에서 생성한 네트워크 AWS Config 규칙 이름"
  type        = list(string)
  default = [
    "gochuchamchi-network-restricted-ports",
    "gochuchamchi-rds-private-only",
    "gochuchamchi-vpc-flow-logs-enabled",
    "gochuchamchi-default-sg-closed",
  ]

  validation {
    condition     = length(var.network_config_rule_names) > 0
    error_message = "network_config_rule_names must contain at least one AWS Config rule name."
  }
}

locals {
  network_compliance_reminder_name = "gochuchamchi-network-compliance-reminder"
}

# 직전 실행이 비준수였는지 기억해야 복구 알림을 딱 한 번만 보낼 수 있다.
resource "aws_dynamodb_table" "network_compliance_state" {
  name         = "gochuchamchi-network-compliance-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "stateKey"

  attribute {
    name = "stateKey"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name      = "gochuchamchi-network-compliance-state"
    Component = "network-compliance"
  }
}

data "archive_file" "network_compliance_reminder" {
  type        = "zip"
  source_file = "${path.module}/network_compliance_reminder.py"
  output_path = "${path.module}/network-compliance-reminder.zip"
}

data "aws_iam_policy_document" "network_compliance_reminder_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "network_compliance_reminder" {
  name               = local.network_compliance_reminder_name
  assume_role_policy = data.aws_iam_policy_document.network_compliance_reminder_assume.json

  tags = {
    Name      = local.network_compliance_reminder_name
    Component = "network-compliance"
  }
}

resource "aws_iam_role_policy_attachment" "network_compliance_reminder_logs" {
  role       = aws_iam_role.network_compliance_reminder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "network_compliance_reminder" {
  statement {
    sid    = "ReadNetworkConfigCompliance"
    effect = "Allow"
    actions = [
      "config:DescribeComplianceByConfigRule",
      "config:GetComplianceDetailsByConfigRule",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadWriteReminderState"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
    ]
    resources = [aws_dynamodb_table.network_compliance_state.arn]
  }

  statement {
    sid       = "PublishNetworkComplianceReminder"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "network_compliance_reminder" {
  name   = "read-config-and-publish-reminder"
  role   = aws_iam_role.network_compliance_reminder.id
  policy = data.aws_iam_policy_document.network_compliance_reminder.json
}

resource "aws_lambda_function" "network_compliance_reminder" {
  function_name = local.network_compliance_reminder_name
  description   = "Reminds operators hourly while AWS Config network rules remain noncompliant; no auto-remediation"

  role    = aws_iam_role.network_compliance_reminder.arn
  handler = "network_compliance_reminder.lambda_handler"
  runtime = "python3.13"

  filename         = data.archive_file.network_compliance_reminder.output_path
  source_code_hash = data.archive_file.network_compliance_reminder.output_base64sha256

  timeout     = 60
  memory_size = 128

  environment {
    variables = {
      CONFIG_RULE_NAMES = join(",", var.network_config_rule_names)
      STATE_TABLE_NAME  = aws_dynamodb_table.network_compliance_state.name
      SNS_TOPIC_ARN     = aws_sns_topic.alerts.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.network_compliance_reminder_logs,
    aws_iam_role_policy.network_compliance_reminder,
  ]

  tags = {
    Name      = local.network_compliance_reminder_name
    Component = "network-compliance"
  }
}

resource "aws_cloudwatch_event_rule" "network_compliance_hourly" {
  name                = "gochuchamchi-network-compliance-hourly"
  description         = "Rechecks AWS Config network compliance and repeats unresolved alerts every hour."
  schedule_expression = "rate(1 hour)"
  state               = "ENABLED"

  tags = {
    Name      = "gochuchamchi-network-compliance-hourly"
    Component = "network-compliance"
  }
}

resource "aws_cloudwatch_event_target" "network_compliance_hourly" {
  rule      = aws_cloudwatch_event_rule.network_compliance_hourly.name
  target_id = "InvokeNetworkComplianceReminder"
  arn       = aws_lambda_function.network_compliance_reminder.arn

  input = jsonencode({ action = "audit-network-compliance" })
}

resource "aws_lambda_permission" "network_compliance_hourly" {
  statement_id  = "AllowExecutionFromEventBridgeNetworkCompliance"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.network_compliance_reminder.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.network_compliance_hourly.arn
}

output "network_compliance_reminder_function_name" {
  description = "Hourly network compliance reminder Lambda (notification only; no remediation)."
  value       = aws_lambda_function.network_compliance_reminder.function_name
}
