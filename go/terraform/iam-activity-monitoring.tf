# =============================================================================
# IAM 활동 감시 — 콘솔 변경/권한 변경/루트 사용 탐지 (2026-08-12)
#
# 왜 EventBridge 인가 (metric filter 가 아니라)
#   IAM 알람의 교과서 방식은 CloudTrail -> CloudWatch Logs -> metric filter ->
#   alarm 이다. 하지만 이 계정의 CloudTrail(gochuchamchi-org-trail)은 S3 로만
#   가고 CloudWatch Logs 로는 보내지 않는다(CloudWatchLogsLogGroupArn=None).
#   그 경로를 켜려면 Management 소유 org trail 을 건드려야 한다.
#   대신 EventBridge 는 CloudTrail 관리 이벤트를 자동으로 받는다(트레일 설정과
#   무관). 로그 그룹도, metric filter 도 필요 없고 비용도 사실상 0 이다.
#
# 왜 us-east-1 인가 (중요)
#   IAM 과 콘솔 로그인은 "글로벌 서비스" 이벤트라 CloudTrail 이 us-east-1 에만
#   기록한다. 따라서 EventBridge 규칙도 us-east-1 에 있어야 잡힌다. 서울에 두면
#   IAM 이벤트가 영원히 안 들어온다(대표적 함정 — CIS 벤치마크 알람이 전부
#   us-east-1 인 이유).
#
# 서울 알림 허브로 어떻게 보내나
#   edge-logs.tf 의 WAF 알람 포워더와 같은 패턴: us-east-1 규칙이 잡은 이벤트를
#   서울 default 이벤트 버스로 relay 하고, cloudwatch-notifications 루트의
#   서울 규칙이 그걸 받아 SNS(gochuchamchi-alerts)로 발행한다. relay 시
#   source/detail-type/detail 은 보존되므로 서울에서 그대로 매칭된다.
#
# 무엇을 잡나 (노이즈 최소화 — 멘토가 지적한 GuardDuty 오탐 문제 의식)
#   1) 루트 계정의 모든 사용 (정상 운영에서 루트는 안 쓴다 = 쓰이면 이상)
#   2) IAM 변경 계열 API (사용자/역할/정책/액세스키 생성·삭제·수정·연결·해제)
#   3) 콘솔 로그인 실패 (무차별 대입 정찰)
#   단순 조회(Get/List/Describe)와 성공 로그인은 제외 — 매칭 안 함.
# =============================================================================

data "aws_iam_policy_document" "iam_activity_forwarder_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "iam_activity_forwarder" {
  name               = "gochuchamchi-iam-activity-forwarder"
  assume_role_policy = data.aws_iam_policy_document.iam_activity_forwarder_assume.json
  tags               = { Name = "gochuchamchi-iam-activity-forwarder" }
}

data "aws_iam_policy_document" "iam_activity_forwarder" {
  statement {
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = ["arn:aws:events:${var.region}:${data.aws_caller_identity.edge_current.account_id}:event-bus/default"]
  }
}

resource "aws_iam_role_policy" "iam_activity_forwarder" {
  name   = "gochuchamchi-iam-activity-forwarder"
  role   = aws_iam_role.iam_activity_forwarder.id
  policy = data.aws_iam_policy_document.iam_activity_forwarder.json
}

# --- 1) 루트 사용 + IAM 변경 API ------------------------------------------------
resource "aws_cloudwatch_event_rule" "iam_activity" {
  provider = aws.us_east_1

  name        = "gochuchamchi-iam-activity"
  description = "루트 사용·IAM 변경 API·콘솔 로그인 실패를 서울 알림 허브로 전달"

  event_pattern = jsonencode({
    detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]
    detail = {
      # OR 조건: 아래 셋 중 하나라도 참이면 매칭 (EventBridge 는 배열 요소 간 OR,
      # $or 로 서로 다른 필드 조합을 묶는다)
      "$or" = [
        # (a) 루트 계정의 모든 행위
        { userIdentity = { type = ["Root"] } },
        # (b) IAM 변경 계열 API (조회 제외)
        {
          eventSource = ["iam.amazonaws.com"]
          eventName = [
            { prefix = "Create" }, { prefix = "Delete" }, { prefix = "Update" },
            { prefix = "Put" }, { prefix = "Attach" }, { prefix = "Detach" },
            { prefix = "Add" }, { prefix = "Remove" }, { prefix = "Tag" }, { prefix = "Untag" }
          ]
        },
        # (c) 콘솔 로그인 실패
        {
          eventSource      = ["signin.amazonaws.com"]
          eventName        = ["ConsoleLogin"]
          responseElements = { ConsoleLogin = ["Failure"] }
        }
      ]
    }
  })
}

resource "aws_cloudwatch_event_target" "iam_activity_to_seoul" {
  provider = aws.us_east_1

  rule      = aws_cloudwatch_event_rule.iam_activity.name
  target_id = "ForwardIamActivityToSeoul"
  arn       = "arn:aws:events:${var.region}:${data.aws_caller_identity.edge_current.account_id}:event-bus/default"
  role_arn  = aws_iam_role.iam_activity_forwarder.arn
}

output "iam_activity_rule_arn" {
  # cloudwatch-notifications 루트의 서울 수신 규칙과 무관하게, us-east-1 규칙이
  # 실제로 생성됐는지 확인용
  value       = aws_cloudwatch_event_rule.iam_activity.arn
  description = "us-east-1 IAM 활동 감지 규칙 ARN"
}
