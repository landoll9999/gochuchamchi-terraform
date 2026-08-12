# =============================================================================
# SIEM 알림 경로 — Log 계정 전용 (2026-08-12)
#
# 왜 Workload의 SNS 허브를 재사용하지 않는가
#   ① providers.tf 맨 위의 전제: "Workload나 Management에서 이 계정의 관리자
#      역할을 AssumeRole하는 신뢰 경로를 만들지 않는다." 반대 방향(Log →
#      Workload publish)도 결국 계정 경계를 넘는 상시 권한이고, 로그를 모아
#      두는 계정에서 밖으로 나가는 경로를 늘리는 건 이 계정의 존재 이유와
#      어긋난다.
#   ② 채널이 섞이면 안 된다. Workload 허브에는 배포 알람·드리프트·GuardDuty가
#      흐른다. 상관 탐지 결과가 거기 묻히면 만든 의미가 없다
#      (2026-08-11 handoff §7 "보안 전용 채널 분리 권장").
#
# 대가는 Discord 렌더러가 두 벌이 된다는 것이다. 받는 메시지 형식이 서로
# 다르므로(이쪽은 상관 룰 히트, 저쪽은 CloudWatch/GuardDuty 이벤트) 공통화해도
# 분기만 늘어난다. 계정 경계를 넘는 것보다 이쪽이 낫다고 판단했다.
#
# 자기 감시 루프 (Workload sns.tf와 같은 구조)
#   Discord 전달 실패 → SNS 재시도 3회 → DLQ 적재 → DLQ 알람 ALARM →
#   같은 토픽으로 발행 → Discord는 여전히 죽어 있어도 **이메일 구독자에게는
#   SNS가 직접 전달**한다. 그래서 "알림 파이프라인 자체의 고장"을 통보받는다.
#   ‼️ 이메일 구독이 0개면 이 루프의 최종 수신자가 없다. 최소 1개 주입 권장.
# =============================================================================

variable "siem_alert_emails" {
  description = <<-EOT
    SIEM 알림 토픽을 구독할 이메일 목록. apply 후 각 수신자가 확인 메일의
    "Confirm subscription"을 눌러야 활성화된다(3일 내 미승인 시 만료).
    개인 이메일을 코드에 하드코딩하지 않기 위한 변수 주입:
      $env:TF_VAR_siem_alert_emails = '["someone@example.com"]'
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for email in var.siem_alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", email))])
    error_message = "siem_alert_emails의 모든 항목은 이메일 주소 형식이어야 합니다."
  }
}


locals {
  siem_name_prefix = "gochuchamchi-siem"

  siem_tags = merge(
    local.cloudwatch_log_archive_tags,
    {
      Component = "siem"
    }
  )
}


# =============================================================================
# Discord Webhook 시크릿 — 그릇만 Terraform이 만들고 값은 사람이 넣는다
#
# 값을 variable로 받으면 tfstate에 평문으로 남는다. 시크릿 값은 인프라와
# 생애주기가 다르다는 원칙(2026-08-05 §4에서 PAT로 학습한 것)을 그대로 따른다.
#
# apply 후 한 번만:
#   aws secretsmanager put-secret-value `
#     --secret-id gochuchamchi/discord/siem-webhook `
#     --secret-string '{"webhook_url":"https://discord.com/api/webhooks/..."}' `
#     --region ap-northeast-2 --profile log-admin
#
# 값을 안 넣으면 Discord Lambda가 런타임에 실패한다 → SNS 재시도 → DLQ →
# DLQ 알람 → 이메일. 즉 "설정을 빠뜨린 것"도 알림으로 돌아온다.
#
# recovery_window_in_days를 0으로 두지 않는 이유: 0이면 destroy 시 즉시
# 삭제돼 웹훅 값이 증발한다. 반대로 값이 크면 같은 이름으로 재생성할 때
# "삭제 예약됨" 오류로 막히므로 7일로 타협했다.
# =============================================================================

resource "aws_secretsmanager_secret" "siem_discord_webhook" {
  name        = "gochuchamchi/discord/siem-webhook"
  description = "Log 계정 SIEM 보안 전용 Discord 웹훅. 값은 콘솔/CLI로 직접 주입 — Terraform은 그릇만 관리한다"

  recovery_window_in_days = 7

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-discord-webhook" })
}


# =============================================================================
# SNS 토픽 — 탐지 결과의 단일 팬아웃 지점
# =============================================================================

resource "aws_sns_topic" "siem_alerts" {
  name = "${local.siem_name_prefix}-alerts"

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-alerts" })
}

# detector Lambda의 발행은 이 정책이 아니라 실행 역할의 IAM sns:Publish로
# 허용된다(같은 계정은 IAM/리소스 정책의 합집합). 여기서는 CloudWatch 알람만
# 열어 준다 — 알람은 서비스 주체로 발행하므로 리소스 정책이 필요하다.
data "aws_iam_policy_document" "siem_alerts_topic" {
  statement {
    sid    = "AllowCloudWatchAlarmPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.siem_alerts.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "siem_alerts" {
  arn    = aws_sns_topic.siem_alerts.arn
  policy = data.aws_iam_policy_document.siem_alerts_topic.json
}


# =============================================================================
# 구독 1 — 이메일 (코드 0줄로 확보하는 채널이자, 자기 감시 루프의 최종 수신자)
# =============================================================================

resource "aws_sns_topic_subscription" "siem_email" {
  for_each = toset(var.siem_alert_emails)

  topic_arn = aws_sns_topic.siem_alerts.arn
  protocol  = "email"
  endpoint  = each.value
}


# =============================================================================
# 구독 2 — Lambda → Discord
# =============================================================================

data "archive_file" "siem_discord" {
  type        = "zip"
  source_file = "${path.module}/siem/discord_function.py"
  output_path = "${path.module}/siem-discord.zip"
}

data "aws_iam_policy_document" "siem_lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "siem_discord" {
  name               = "${local.siem_name_prefix}-discord-lambda"
  assume_role_policy = data.aws_iam_policy_document.siem_lambda_assume_role.json

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-discord-lambda" })
}

resource "aws_iam_role_policy_attachment" "siem_discord_basic_execution" {
  role       = aws_iam_role.siem_discord.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "siem_discord_secret" {
  statement {
    sid       = "ReadSiemDiscordWebhook"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.siem_discord_webhook.arn]
  }
}

resource "aws_iam_role_policy" "siem_discord_secret" {
  name   = "${local.siem_name_prefix}-read-discord-webhook"
  role   = aws_iam_role.siem_discord.id
  policy = data.aws_iam_policy_document.siem_discord_secret.json
}

resource "aws_lambda_function" "siem_discord" {
  function_name = "${local.siem_name_prefix}-discord"
  description   = "SIEM 상관 탐지 결과와 파이프라인 고장을 Discord 보안 채널로 렌더링"

  role    = aws_iam_role.siem_discord.arn
  handler = "discord_function.lambda_handler"
  runtime = "python3.12"

  filename         = data.archive_file.siem_discord.output_path
  source_code_hash = data.archive_file.siem_discord.output_base64sha256

  timeout     = 15
  memory_size = 128

  environment {
    variables = {
      DISCORD_SECRET_ARN = aws_secretsmanager_secret.siem_discord_webhook.arn
      DISCORD_SECRET_KEY = "webhook_url"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.siem_discord_basic_execution,
    aws_iam_role_policy.siem_discord_secret,
  ]

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-discord" })
}

resource "aws_sns_topic_subscription" "siem_discord" {
  topic_arn = aws_sns_topic.siem_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.siem_discord.arn

  # SNS의 Lambda 재시도(3회)까지 전부 실패한 메시지를 DLQ로.
  # 이게 없으면 Discord 장애 시 탐지 결과가 흔적 없이 사라진다.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.siem_alerts_dlq.arn
  })
}

resource "aws_lambda_permission" "siem_discord_from_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.siem_discord.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.siem_alerts.arn
}


# =============================================================================
# DLQ + 자기 감시 알람
# =============================================================================

resource "aws_sqs_queue" "siem_alerts_dlq" {
  name = "${local.siem_name_prefix}-alerts-dlq"

  # 원인 조사 시간을 벌기 위해 보존 기간 최대(14일)
  message_retention_seconds = 1209600

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-alerts-dlq" })
}

data "aws_iam_policy_document" "siem_alerts_dlq" {
  statement {
    sid    = "AllowSnsDeadLetter"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.siem_alerts_dlq.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.siem_alerts.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "siem_alerts_dlq" {
  queue_url = aws_sqs_queue.siem_alerts_dlq.id
  policy    = data.aws_iam_policy_document.siem_alerts_dlq.json
}

resource "aws_cloudwatch_metric_alarm" "siem_alerts_dlq_messages" {
  alarm_name        = "${local.siem_name_prefix}-alerts-dlq-has-messages"
  alarm_description = "SIEM 알림의 Discord 전달 실패분이 DLQ에 쌓였습니다. 웹훅 시크릿에 값이 들어 있는지(apply 후 수동 주입 필요), Lambda 로그, Discord 웹훅 상태를 순서대로 확인하세요."

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.siem_alerts_dlq.name
  }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # 메시지가 없으면 지표 자체가 안 찍히는 SQS 특성 → 미수신을 정상으로 간주
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.siem_alerts.arn]
  ok_actions    = [aws_sns_topic.siem_alerts.arn]

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-alerts-dlq-has-messages" })
}


# =============================================================================
# Outputs
# =============================================================================

output "siem_alerts_topic_arn" {
  description = "SIEM 탐지 결과 SNS 토픽 (Log 계정 전용)"
  value       = aws_sns_topic.siem_alerts.arn
}

output "siem_discord_webhook_secret_name" {
  description = "apply 후 이 시크릿에 Discord 웹훅 URL을 직접 주입해야 알림이 전달된다"
  value       = aws_secretsmanager_secret.siem_discord_webhook.name
}
