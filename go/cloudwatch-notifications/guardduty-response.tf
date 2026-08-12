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
# Rule 1: 통보 — 타입 기반 필터 (2026-08-12 개편)
#
# 왜 severity 숫자만으로는 부족한가 (실측으로 드러난 문제)
#   기존엔 severity>=4(Medium)만 통보했다. 그런데 실제 finding 을 보니 전부
#   severity 2 였고, 그중 Policy:IAMUser/RootCredentialUsage(루트 자격증명 사용)가
#   있었다 — 가장 중요한 신호인데 숫자가 낮아 통보에서 누락되고 있었다. 반대로
#   Medium 이상에 섞여오는 PortProbe/BruteForce 는 공인 IP 라면 항상 쏟아지는
#   인터넷 배경소음이라 통보돼봐야 소음이다(배스천은 SSH/RDP 인바운드가 0개라
#   무차별 대입은 성공 자체가 불가 = 순수 노이즈).
#   멘토 조언대로 "심각도 숫자"가 아니라 "타입(필드)"으로 의미를 판단한다.
#
# 두 갈래로 판단한다:
#   (A) 항상 통보 — severity 무관하게 의미가 확정적인 타입
#       루트 사용, S3 정책 완화, 자격증명 탈취/유출, 백도어/트로이목마/암호화폐,
#       파괴적 영향(Impact) 등. 저심각도로 와도 놓치면 안 되는 것들.
#   (B) 그 외 — Medium 이상이면서, 소음 타입(포트스캔/무차별대입)은 제외.
#
# 임계값·목록은 변수로 빼서 운영 중 조정 가능하게 둔다.
# ============================================================

variable "guardduty_always_notify_type_prefixes" {
  description = "severity와 무관하게 항상 통보할 finding 타입 접두사"
  type        = list(string)
  default = [
    "Policy:IAMUser/Root", # 루트 자격증명 사용
    "Policy:S3/",          # S3 퍼블릭 차단 해제 등 버킷 정책 완화
    "CredentialAccess:",   # 자격증명 탈취 시도
    "Exfiltration:",       # 데이터 반출
    "Backdoor:",           # C2/백도어
    "Trojan:",             # 트로이목마
    "CryptoCurrency:",     # 암호화폐 채굴(피침해 EC2의 전형적 증상)
    "Impact:",             # 파괴적 영향(랜섬/변조 등)
    "PenTest:",            # 침투도구 사용
  ]
}

variable "guardduty_notify_noise_types" {
  description = "Medium 이상이어도 통보하지 않을 소음 finding 타입(정확한 전체 이름)"
  type        = list(string)
  default = [
    "Recon:EC2/PortProbeUnprotectedPort",
    "Recon:EC2/PortProbeEMRUnprotectedPort",
    "UnauthorizedAccess:EC2/SSHBruteForce",
    "UnauthorizedAccess:EC2/RDPBruteForce",
  ]
}

resource "aws_cloudwatch_event_rule" "guardduty_finding" {
  name        = "gochuchamchi-guardduty-finding"
  description = "의미 있는 GuardDuty finding만 SNS 알림 허브로 발행합니다(타입 기반 필터)."

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]

    detail = {
      "$or" = [
        # (A) 항상 통보: severity 조건 없이 타입 접두사만 본다
        {
          type = [for p in var.guardduty_always_notify_type_prefixes : { prefix = p }]
        },
        # (B) 그 외: Medium 이상이되, 소음 타입은 제외
        {
          severity = [{ numeric = [">=", var.guardduty_notify_min_severity] }]
          type     = [{ "anything-but" = var.guardduty_notify_noise_types }]
        }
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

  # --- 격리 시 각 ENI에 원본 SG를 기록(복구의 근거). ENI 태그 생성 허용 ---
  statement {
    sid    = "TagEniPreQuarantine"
    effect = "Allow"

    actions = ["ec2:CreateTags"]

    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
    ]
  }

  # --- 복구(오격리 원상복구): ENI 원본 SG 복원 후 격리 태그 제거 ---
  statement {
    sid    = "DeleteQuarantineTags"
    effect = "Allow"

    actions = ["ec2:DeleteTags"]

    resources = [
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*",
      "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:network-interface/*",
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
