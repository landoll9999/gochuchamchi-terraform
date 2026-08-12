# ============================================================
# SNS 알림 허브 (2026-08-04 도입)
#
# 왜 도입했나 — 기존 EventBridge → Lambda 직결 구조의 한계 2가지:
#   1) 팬아웃 불가: 알림 채널을 추가하려면 Lambda 코드를 고쳐야 했음
#      -> 이제 채널 추가 = 구독(subscription) 추가. Lambda는 Discord 전담.
#   2) 유실: Lambda가 실패하면(코드 버그, Discord 장애) 알림이 그냥 사라짐
#      -> SNS가 재시도하고, 최종 실패는 DLQ(SQS)에 적재 + DLQ 알람으로 통보.
#
# 암호화(KMS) 미적용 이유: EventBridge는 기본 관리형 키(aws/sns)로 암호화된
# 토픽에 발행할 수 없어(키 정책 수정 불가) CMK가 필요한데, CMK는 월 $1 + 키
# 정책 관리가 따라온다. 이 토픽에 흐르는 건 알람 이름/상태(비밀 아님)뿐이라
# 학습 단계에선 미암호화로 두고, 운영 전환 시 CMK + 키 정책을 세트로 도입할 것.
# ============================================================

resource "aws_sns_topic" "alerts" {
  name = "gochuchamchi-alerts"

  tags = {
    Name = "gochuchamchi-alerts"
  }
}

# EventBridge만 발행 가능하도록 최소권한으로 제한.
# Principal을 서비스 전체(events.amazonaws.com)로 열되, SourceArn 조건으로
# "우리 룰"에서 온 발행만 허용 — 같은 계정의 다른 EventBridge 룰도 못 쓰게 함.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowEventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          ArnEquals = {
            # 발행 가능한 rule을 명시적 목록으로 관리 — 신규 알림 소스는 여기 추가
            # (격리 Lambda의 결과 발행은 이 정책이 아니라 Lambda 역할의 IAM
            #  sns:Publish로 허용됨 — 같은 계정은 IAM/리소스 정책의 합집합)
            "aws:SourceArn" = [
              aws_cloudwatch_event_rule.cloudwatch_alarm_state_change.arn,
              aws_cloudwatch_event_rule.guardduty_finding.arn,
              aws_cloudwatch_event_rule.iam_activity_forwarded.arn,
            ]
          }
        }
      }
    ]
  })
}

# ============================================================
# 구독 1: Lambda → Discord (기존 파이프라인을 SNS 뒤로 이동)
# ============================================================

resource "aws_sns_topic_subscription" "discord_lambda" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cloudwatch_discord.arn

  # SNS의 Lambda 재시도(3회)까지 전부 실패한 메시지를 DLQ로 보냄.
  # 이게 없으면 Discord 장애 시 알림이 흔적 없이 유실된다.
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.alerts_dlq.arn
  })
}

# SNS가 Lambda를 호출할 권한 (기존 EventBridge 직결 권한을 대체)
resource "aws_lambda_permission" "allow_sns" {
  statement_id = "AllowExecutionFromSNS"

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cloudwatch_discord.function_name
  principal     = "sns.amazonaws.com"

  source_arn = aws_sns_topic.alerts.arn
}

# ============================================================
# 구독 2: 이메일 (SNS 기본 기능 — 코드 0줄로 채널 하나 확보)
#
# 이메일은 하드코딩하지 않고 변수로 주입 (하드코딩 리뷰 원칙):
#   $env:TF_VAR_alert_emails = '["someone@example.com"]'
# 주의:
#   - apply 후 각 수신자가 확인 메일의 "Confirm subscription"을 눌러야 활성화됨.
#     누르기 전(PendingConfirmation)에는 전달 안 되고, 3일 지나면 만료됨.
#   - PendingConfirmation 상태의 구독은 API로 삭제가 불가 — destroy 시 state에서만
#     제거되고 실제로는 3일 후 자동 소멸함 (terraform 에러 아님, 정상 동작).
# ============================================================

resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# ============================================================
# DLQ + 자기 감시 루프
#
# Discord 전달이 계속 실패하면: DLQ 적재 -> 아래 알람 ALARM 전환 ->
# EventBridge의 "gochuchamchi-" prefix 룰이 잡아서 -> 같은 SNS 토픽으로 발행.
# 이때 Lambda(Discord)는 여전히 죽어 있어도 이메일 구독자에게는 SNS가 직접
# 전달하므로 "알림 파이프라인 자체의 고장"을 통보받을 수 있다.
# (이메일 구독이 0개면 이 루프의 최종 수신자가 없다 — alert_emails 주입 권장)
# ============================================================

resource "aws_sqs_queue" "alerts_dlq" {
  name = "gochuchamchi-alerts-dlq"

  # 원인 조사 시간을 벌기 위해 보존 기간을 최대(14일)로
  message_retention_seconds = 1209600

  tags = {
    Name = "gochuchamchi-alerts-dlq"
  }
}

resource "aws_sqs_queue_policy" "alerts_dlq" {
  queue_url = aws_sqs_queue.alerts_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowSnsDeadLetter"
        Effect    = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.alerts_dlq.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.alerts.arn
          }
        }
      }
    ]
  })
}

# 알람 이름이 "gochuchamchi-"로 시작해야 eventbridge.tf의 prefix 룰에 잡힌다
resource "aws_cloudwatch_metric_alarm" "alerts_dlq_messages" {
  alarm_name        = "gochuchamchi-alerts-dlq-has-messages"
  alarm_description = "알림 파이프라인의 Discord 전달 실패분이 DLQ에 쌓임 — Lambda 로그와 Discord Webhook 상태를 확인할 것"

  namespace   = "AWS/SQS"
  metric_name = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.alerts_dlq.name
  }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # 메시지가 없으면 지표 자체가 안 찍히는 SQS 특성 -> 미수신을 정상으로 간주
  treat_missing_data = "notBreaching"

  tags = {
    Name = "gochuchamchi-alerts-dlq-has-messages"
  }
}

output "alerts_topic_arn" {
  value       = aws_sns_topic.alerts.arn
  description = "알림 허브 SNS 토픽 — 이후 GuardDuty/Security Hub/RDS 이벤트 등 신규 알림 소스는 이 토픽으로 발행하면 됨"
}
