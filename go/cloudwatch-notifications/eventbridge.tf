# ============================================================
# CloudWatch Alarm 상태 변경 감지
# ============================================================

resource "aws_cloudwatch_event_rule" "cloudwatch_alarm_state_change" {
  name = "gochuchamchi-cloudwatch-alarm-state-change"

  description = (
    "gochuchamchi CloudWatch Alarm의 ALARM/OK 상태 변경을 감지합니다."
  )

  event_pattern = jsonencode({
    source = [
      "aws.cloudwatch"
    ]

    detail-type = [
      "CloudWatch Alarm State Change"
    ]

    detail = {
      alarmName = [
        {
          prefix = "gochuchamchi-"
        }
      ]

      state = {
        value = [
          "ALARM",
          "OK"
        ]
      }
    }
  })

  state = "ENABLED"

  tags = {
    Name = "gochuchamchi-cloudwatch-alarm-state-change"
  }
}


# ============================================================
# EventBridge Rule의 실행 대상을 SNS 허브로 연결
#   (2026-08-04) 기존 Lambda 직결 -> SNS 경유로 전환. Lambda 호출 권한은
#   EventBridge가 아니라 SNS가 가짐(sns.tf의 allow_sns). EventBridge -> SNS
#   발행 권한은 토픽 정책(sns.tf의 aws_sns_topic_policy.alerts)이 담당.
# ============================================================

resource "aws_cloudwatch_event_target" "alerts_sns" {
  rule = aws_cloudwatch_event_rule.cloudwatch_alarm_state_change.name

  target_id = "SendCloudWatchAlarmToSnsHub"
  arn       = aws_sns_topic.alerts.arn
}