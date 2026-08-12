# =============================================================================
# IAM 활동 알림 — us-east-1 에서 전달된 IAM/루트/로그인실패 이벤트를 SNS 로 (2026-08-12)
#
# 짝: ../terraform/iam-activity-monitoring.tf 가 us-east-1 에서 이벤트를 잡아
#     서울 default 버스로 relay 한다. 이 파일은 서울에서 그걸 받아 알림 허브로
#     발행한다. relay 시 source/detail-type/detail 이 보존되므로 아래 패턴은
#     ../terraform 쪽과 동일하게 유지해야 한다(둘이 어긋나면 조용히 안 잡힌다).
#
# 왜 서울에 IAM 이벤트가 "우리 것만" 오는가
#   IAM/콘솔로그인은 글로벌이라 서울 버스에는 원래 안 온다. 따라서 서울 버스에서
#   이 detail-type 이 보인다면 us-east-1 포워더가 보낸 것뿐이다. 그래도 루트 사용은
#   서울 리전에서도 네이티브로 잡힐 수 있어, 패턴을 동일하게 좁혀 오탐을 막는다.
# =============================================================================

resource "aws_cloudwatch_event_rule" "iam_activity_forwarded" {
  name        = "gochuchamchi-iam-activity-forwarded"
  description = "us-east-1에서 전달된 루트 사용·IAM 변경·콘솔 로그인 실패 이벤트"

  event_pattern = jsonencode({
    detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail = {
      "$or" = [
        { userIdentity = { type = ["Root"] } },
        {
          eventSource = ["iam.amazonaws.com"]
          eventName = [
            { prefix = "Create" }, { prefix = "Delete" }, { prefix = "Update" },
            { prefix = "Put" }, { prefix = "Attach" }, { prefix = "Detach" },
            { prefix = "Add" }, { prefix = "Remove" }, { prefix = "Tag" }, { prefix = "Untag" }
          ]
        },
        {
          eventSource      = ["signin.amazonaws.com"]
          eventName        = ["ConsoleLogin"]
          responseElements = { ConsoleLogin = ["Failure"] }
        }
      ]
    }
  })

  tags = {
    Name = "gochuchamchi-iam-activity-forwarded"
  }
}

resource "aws_cloudwatch_event_target" "iam_activity_sns" {
  rule      = aws_cloudwatch_event_rule.iam_activity_forwarded.name
  target_id = "SendIamActivityToSnsHub"
  arn       = aws_sns_topic.alerts.arn

  # CloudTrail 원문은 필드가 많아 알림으로는 읽기 어렵다(멘토 지적: GuardDuty JSON이
  # 컬럼이 너무 많아 그대로는 못 본다). 핵심 필드만 뽑아 사람이 읽을 한 줄로 만든다.
  input_transformer {
    input_paths = {
      account   = "$.detail.userIdentity.accountId"
      actor     = "$.detail.userIdentity.arn"
      type      = "$.detail.userIdentity.type"
      eventName = "$.detail.eventName"
      source    = "$.detail.eventSource"
      sourceIp  = "$.detail.sourceIPAddress"
      time      = "$.detail.eventTime"
      region    = "$.detail.awsRegion"
    }
    # SNS 이메일 본문. Discord Lambda 도 같은 SNS 를 구독하므로 이 문자열을 받는다.
    input_template = <<-TEMPLATE
      "[IAM 활동 감지] <type> 이(가) <eventName> 실행"
      "행위자: <actor>"
      "이벤트: <source> / <eventName>"
      "출발IP: <sourceIp>  리전: <region>  시각: <time>"
      "계정: <account>"
      "→ 예상한 변경인지 확인하세요. 모르는 행위자·루트 사용·연속 로그인 실패면 즉시 조사."
    TEMPLATE
  }
}
