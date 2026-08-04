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
# EventBridge가 Lambda를 호출할 수 있는 권한
# ============================================================

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id = "AllowExecutionFromEventBridge"

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cloudwatch_discord.function_name
  principal     = "events.amazonaws.com"

  source_arn = aws_cloudwatch_event_rule.cloudwatch_alarm_state_change.arn
}


# ============================================================
# EventBridge Rule의 실행 대상을 Lambda로 연결
# ============================================================

resource "aws_cloudwatch_event_target" "cloudwatch_discord" {
  rule = aws_cloudwatch_event_rule.cloudwatch_alarm_state_change.name

  target_id = "SendCloudWatchAlarmToDiscord"
  arn       = aws_lambda_function.cloudwatch_discord.arn

  depends_on = [
    aws_lambda_permission.allow_eventbridge
  ]
}