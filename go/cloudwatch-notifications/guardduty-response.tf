# ============================================================
# GuardDuty 탐지 → 통보 + 자동 격리 (2026-08-07 도입)
#
# 왜 이 state에 있나 — account-baseline이 아니라:
#   1) 이 파일의 EventBridge rule은 `source: aws.guardduty` 이벤트 패턴만
#      쓰므로 detector 리소스를 참조할 필요가 없다. 계층 교차 참조 0.
#   2) account-baseline은 지금 removed+import 마이그레이션 중이라, 첫 plan이
#      "import만 있어야" 검증이 된다. 새 리소스를 거기 넣으면 판정이 흐려진다.
#   3) SNS 허브·Discord Lambda가 이미 여기 있어 배선이 가장 짧다.
#
# 격리 대상(EKS 노드/EC2)은 매일 destroy되는 main 계층에 있지만, 이 Lambda는
# Terraform 참조가 아니라 "finding에 적힌 인스턴스 ID"로 런타임에 API를 때리므로
# 한 방향 참조 원칙(terraform/ → 상시 계층)을 깨지 않는다. 검역 SG도 같은 이유로
# Terraform이 아니라 Lambda가 대상 VPC 안에 즉석 생성한다 — VPC가 매일 죽었다
# 살아나서 ARN을 배포 시점에 알 수 없기 때문.
# ============================================================

variable "guardduty_notify_min_severity" {
  description = "이 값 이상의 severity만 Discord/이메일로 통보 (GuardDuty: 4=Medium, 7=High)"
  type        = number
  default     = 4
}

variable "guardduty_isolate_min_severity" {
  description = "이 값 이상의 severity만 자동 격리 발동 (기본 7=High 이상)"
  type        = number
  default     = 7
}

variable "isolation_enabled" {
  description = "자동 격리 스위치. false면 Lambda가 통보만 하고 SG 교체를 하지 않음(드라이런). 오탐 검증 기간에 사용"
  type        = bool
  default     = true
}

# ============================================================
# Rule 1: 통보 — severity >= 4 (Medium 이상) → SNS 허브
#   Discord/이메일 팬아웃은 기존 구독이 그대로 처리. 코드 추가분은
#   lambda_function.py의 GuardDuty 이벤트 렌더러뿐.
# ============================================================

resource "aws_cloudwatch_event_rule" "guardduty_finding" {
  name        = "gochuchamchi-guardduty-finding"
  description = "GuardDuty Medium 이상 finding을 SNS 알림 허브로 발행합니다."

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]

    detail = {
      severity = [
        { numeric = [">=", var.guardduty_notify_min_severity] }
      ]
    }
  })

  state = "ENABLED"

  tags = {
    Name = "gochuchamchi-guardduty-finding"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_finding.name
  target_id = "SendGuardDutyFindingToSnsHub"
  arn       = aws_sns_topic.alerts.arn
}

# ============================================================
# Rule 2: 대응 — severity >= 7 (High 이상) → 격리 Lambda 직결
#   SNS를 거치지 않는 이유: 대응 경로는 팬아웃이 필요 없고, 통보 경로의
#   장애(예: Discord Webhook 문제로 DLQ 적재)가 격리 실행을 막으면 안 됨.
#   EventBridge가 Lambda 호출 실패를 최대 24시간 자체 재시도한다.
# ============================================================

resource "aws_cloudwatch_event_rule" "guardduty_finding_critical" {
  name        = "gochuchamchi-guardduty-finding-critical"
  description = "GuardDuty High 이상 finding에 대해 EC2 자동 격리 Lambda를 호출합니다."

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]

    detail = {
      severity = [
        { numeric = [">=", var.guardduty_isolate_min_severity] }
      ]
    }
  })

  state = "ENABLED"

  tags = {
    Name = "gochuchamchi-guardduty-finding-critical"
  }
}

resource "aws_cloudwatch_event_target" "guardduty_isolation_lambda" {
  rule      = aws_cloudwatch_event_rule.guardduty_finding_critical.name
  target_id = "InvokeIsolationLambda"
  arn       = aws_lambda_function.guardduty_isolation.arn
}

resource "aws_lambda_permission" "allow_eventbridge_isolation" {
  statement_id = "AllowExecutionFromEventBridge"

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guardduty_isolation.function_name
  principal     = "events.amazonaws.com"

  # 이 rule에서 온 호출만 허용 — 같은 계정의 다른 rule/주체가 격리를
  # 트리거하는 것을 차단 (sns.tf의 SourceArn 조건과 같은 원칙)
  source_arn = aws_cloudwatch_event_rule.guardduty_finding_critical.arn
}

# ============================================================
# 격리 Lambda
# ============================================================

data "archive_file" "guardduty_isolation" {
  type        = "zip"
  source_file = "${path.module}/isolation_function.py"
  output_path = "${path.module}/guardduty-isolation.zip"
}

resource "aws_iam_role" "guardduty_isolation" {
  name = "gochuchamchi-guardduty-isolation-lambda"

  # lambda.tf의 신뢰 정책 재사용 (동일 서비스 principal)
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "gochuchamchi-guardduty-isolation-lambda"
  }
}

resource "aws_iam_role_policy_attachment" "isolation_basic_execution" {
  role = aws_iam_role.guardduty_isolation.name

  policy_arn = (
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  )
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "guardduty_isolation" {
  # --- 조회: 대상 확인용. Describe*는 리소스 수준 제한을 지원하지 않아 * ---
  statement {
    sid    = "DescribeTargets"
    effect = "Allow"

    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeNetworkInterfaces",
    ]

    resources = ["*"]
  }

  # --- 검역 SG 생성: VPC가 매일 재생성되어 ARN을 배포 시점에 못 박는다.
  #     대신 리전·계정으로 한정하고, 생성 시 태그를 강제해 아무 SG나 만들 수
  #     없게 조건을 건다 ---
  statement {
    sid    = "CreateQuarantineSg"
    effect = "Allow"

    actions = ["ec2:CreateSecurityGroup"]

    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*",
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:vpc/*",
    ]
  }

  statement {
    sid    = "TagOnCreate"
    effect = "Allow"

    actions = ["ec2:CreateTags"]

    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }
  }

  # --- 검역 SG의 기본 egress 규칙 제거 (0규칙 = 전면 차단).
  #     우리가 만든(=이 태그가 붙은) SG에만 허용 ---
  statement {
    sid    = "RevokeQuarantineEgress"
    effect = "Allow"

    actions = ["ec2:RevokeSecurityGroupEgress"]

    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/gochuchamchi:role"
      values   = ["quarantine"]
    }
  }

  # --- 격리 실행: ENI의 SG 교체 + 인스턴스 포렌식 태깅.
  #     ENI/인스턴스는 finding이 가리키는 대상이라 사전에 좁힐 수 없음 ---
  statement {
    sid    = "IsolateEni"
    effect = "Allow"

    actions = ["ec2:ModifyNetworkInterfaceAttribute"]

    resources = ["*"]
  }

  statement {
    sid    = "TagQuarantinedInstance"
    effect = "Allow"

    actions = ["ec2:CreateTags"]

    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
  }

  # --- 결과 통보: 알림 허브로만 발행 가능 ---
  statement {
    sid    = "PublishResult"
    effect = "Allow"

    actions = ["sns:Publish"]

    resources = [aws_sns_topic.alerts.arn]
  }
}

resource "aws_iam_role_policy" "guardduty_isolation" {
  name = "gochuchamchi-guardduty-isolation"
  role = aws_iam_role.guardduty_isolation.id

  policy = data.aws_iam_policy_document.guardduty_isolation.json
}

resource "aws_lambda_function" "guardduty_isolation" {
  function_name = "gochuchamchi-guardduty-isolation"

  role    = aws_iam_role.guardduty_isolation.arn
  handler = "isolation_function.lambda_handler"
  runtime = "python3.12"

  filename         = data.archive_file.guardduty_isolation.output_path
  source_code_hash = data.archive_file.guardduty_isolation.output_base64sha256

  # SG 생성 + ENI 교체 + SNS 발행까지. Describe 재시도 여유 포함
  timeout     = 60
  memory_size = 128

  environment {
    variables = {
      SNS_TOPIC_ARN      = aws_sns_topic.alerts.arn
      MIN_SEVERITY       = tostring(var.guardduty_isolate_min_severity)
      QUARANTINE_SG_NAME = "gochuchamchi-quarantine"
      ISOLATION_ENABLED  = var.isolation_enabled ? "true" : "false"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.isolation_basic_execution,
    aws_iam_role_policy.guardduty_isolation,
  ]

  tags = {
    Name = "gochuchamchi-guardduty-isolation"
  }
}
