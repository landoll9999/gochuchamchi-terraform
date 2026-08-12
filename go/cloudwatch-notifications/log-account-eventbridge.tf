# =============================================================================
# Accept Firehose health alarm events from the Security/Log account.
#
# The existing default-bus rule already routes gochuchamchi-* CloudWatch alarm
# events to SNS and then Discord. This policy grants only the Log account the
# ability to put those cross-account events onto this account's default bus.
# =============================================================================

resource "aws_cloudwatch_event_permission" "allow_log_account_firehose_alarm_events" {
  statement_id   = "AllowLogAccountFirehoseAlarmEvents"
  action         = "events:PutEvents"
  principal      = "564186750363"
  event_bus_name = "default"
}
