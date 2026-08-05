# =============================================================================
# 수동 변경(드리프트) 감지  — 2026-08-04 자동화 3/3
#
# 무엇을 잡나
#   "Terraform 밖에서 인프라가 바뀐 순간"을 실시간으로 알린다. 이게 곧 드리프트의
#   발생 원인이다 — 콘솔에서 SG 규칙 하나 열어놓고 잊으면, 다음 apply가 그걸 조용히
#   되돌리거나(원인 모를 장애) 코드와 실환경이 계속 어긋난 채로 굴러간다.
#
# 왜 `terraform plan` 방식이 아닌가 (트레이드오프)
#   정석은 "하루 1회 terraform plan -detailed-exitcode -> 종료코드 2면 알림"이다.
#   그런데 이 스택은 kubernetes/helm 프로바이더를 쓰고 EKS 퍼블릭 엔드포인트가
#   /32 허용목록으로 잠겨 있어서, GitHub 호스티드 러너에서는 plan이 refresh 단계에서
#   타임아웃 난다. 즉 plan 방식은 self-hosted runner(배스천) 결정이 선행돼야 한다.
#   이 파일은 그 결정 없이 지금 당장 얻을 수 있는 신호를 먼저 확보하는 쪽이다.
#     · plan 방식      : 모든 드리프트를 잡지만 러너 인프라가 필요(사후 감지, 1일 지연)
#     · 이 이벤트 방식 : 사람이 콘솔로 만진 변경을 "즉시" 잡음, 비용 0, 러너 불필요
#                        단 CLI/SDK로 낸 수동 변경은 못 잡는다 (아래 한계 참고)
#   두 방식은 대체재가 아니라 보완재다. 러너가 생기면 plan 룰을 추가로 붙인다.
#
# 전제 — CloudTrail이 관리 이벤트를 기록하고 있어야 한다(../terraform/cloudtrail.tf).
#   EventBridge의 "AWS API Call via CloudTrail" 이벤트는 CloudTrail이 켜져 있을 때만 온다.
#
# 비용 — AWS 서비스가 발행하는 이벤트는 EventBridge 요금이 없다. SNS 발행분만 과금(무시 가능).
# =============================================================================

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# 룰 1: 콘솔에서 발생한 모든 인프라 변경
#
#   sessionCredentialFromConsole = "true" 는 CloudTrail이 "이 API 호출은 콘솔
#   세션 자격증명으로 이뤄졌다"고 표시하는 필드다. 즉 사람이 브라우저에서 클릭한 변경.
#   Terraform/CLI/컨트롤러(ALB controller, ExternalDNS 등)는 이 필드가 없어서
#   자동으로 걸러진다 -> 별도 제외 목록 없이도 노이즈가 거의 없다.
#
#   readOnly = false 로 조회성 호출(Describe*/List*)을 배제한다. 이게 없으면
#   콘솔 화면 한 번 여는 것만으로 수십 건이 발행된다.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "console_mutation" {
  name        = "gochuchamchi-console-mutation"
  description = "콘솔에서 사람이 직접 수행한 인프라 변경(드리프트 발생 시점)을 감지합니다."

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]

    # 이 프로젝트가 Terraform으로 관리하는 서비스만 감시한다.
    # (aws.logs/aws.autoscaling 은 컨트롤러가 자동으로 만지지만 콘솔 조건이
    #  이미 사람만 남기므로 포함해도 안전)
    source = [
      "aws.ec2",
      "aws.eks",
      "aws.rds",
      "aws.elasticache",
      "aws.elasticloadbalancing",
      "aws.s3",
      "aws.iam",
      "aws.secretsmanager",
      "aws.kms",
      "aws.route53",
      "aws.logs",
      "aws.autoscaling",
    ]

    detail = {
      readOnly                     = [false]
      sessionCredentialFromConsole = ["true"]
    }
  })

  state = "ENABLED"

  tags = {
    Name = "gochuchamchi-console-mutation"
  }
}

# ---------------------------------------------------------------------------
# 룰 2: IAM 변경 — Terraform 실행 주체를 제외한 누구든
#
#   IAM은 콘솔이든 CLI든 "권한 경계가 바뀌는" 최고 위험 변경이라 별도로 본다.
#   anything-but으로 Terraform 주체(현재 apply를 돌리는 자격증명)를 제외하지 않으면
#   apply마다 수십 건이 울린다.
#
#   ⚠ 이 제외는 "지금 이 스택을 apply하는 주체" 기준이다. 나중에 CI(OIDC 역할)에서
#     apply하게 되면 그 역할 ARN도 제외 목록에 추가해야 한다 — 그때는
#     arn = [{ "anything-but" = [A, B] }] 형태로 목록을 쓰면 된다.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "iam_mutation" {
  name        = "gochuchamchi-iam-mutation"
  description = "Terraform 실행 주체가 아닌 누군가의 IAM 변경(권한 경계 변화)을 감지합니다."

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail"]
    source        = ["aws.iam"]

    detail = {
      readOnly = [false]
      userIdentity = {
        arn = [{ "anything-but" = data.aws_caller_identity.current.arn }]
      }
    }
  })

  state = "ENABLED"

  tags = {
    Name = "gochuchamchi-iam-mutation"
  }
}

# ---------------------------------------------------------------------------
# 룰 3: 루트 계정 사용
#
#   루트는 MFA 강제 그룹(../terraform/iam-security.tf)으로도 통제할 수 없는 유일한
#   주체다. 정상 운영에서는 절대 쓰일 일이 없으므로, 쓰였다는 사실 자체가 신호다.
#   (읽기 전용 호출까지 포함 — 루트 로그인 후 둘러보는 것도 알아야 할 사건)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "root_activity" {
  name        = "gochuchamchi-root-activity"
  description = "루트 계정의 API 사용을 감지합니다. 정상 운영에서는 발생하지 않아야 합니다."

  event_pattern = jsonencode({
    "detail-type" = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]

    detail = {
      userIdentity = {
        type = ["Root"]
      }
    }
  })

  state = "ENABLED"

  tags = {
    Name = "gochuchamchi-root-activity"
  }
}

# ---------------------------------------------------------------------------
# 세 룰 모두 SNS 허브로 (input_transformer를 쓰지 않는 이유)
#
#   input_transformer로 사람이 읽기 좋은 문자열을 만들면 이메일은 예뻐지지만,
#   같은 토픽을 구독하는 Lambda가 받는 Message가 "JSON이 아닌 문자열"이 되어
#   json.loads에서 터진다(-> SNS 재시도 -> DLQ). 그래서 원본 JSON을 그대로 보내고,
#   사람이 읽는 형태로 바꾸는 일은 Lambda(lambda_function.py)가 담당한다.
#   이메일 구독자는 원본 JSON을 받는다 — 알림의 1차 목적이 "발생 사실 통보"라 허용.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_event_target" "console_mutation_sns" {
  rule      = aws_cloudwatch_event_rule.console_mutation.name
  target_id = "SendConsoleMutationToSnsHub"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_target" "iam_mutation_sns" {
  rule      = aws_cloudwatch_event_rule.iam_mutation.name
  target_id = "SendIamMutationToSnsHub"
  arn       = aws_sns_topic.alerts.arn
}

resource "aws_cloudwatch_event_target" "root_activity_sns" {
  rule      = aws_cloudwatch_event_rule.root_activity.name
  target_id = "SendRootActivityToSnsHub"
  arn       = aws_sns_topic.alerts.arn
}
