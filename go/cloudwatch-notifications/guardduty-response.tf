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

variable "protected_instance_tag_keys" {
  description = "자동 격리에서 제외할 EC2 인스턴스 태그 키 또는 접두사 목록. EKS 워커 노드는 서비스 전체 영향 방지를 위해 기본적으로 제외하고 P1 수동 대응으로 전환합니다."
  type        = list(string)
  default = [
    "eks:cluster-name",
    "kubernetes.io/cluster/",
  ]
}

# ---------------------------------------------------------------------------
# (2026-08-12) 자동대응 3종 확장: 자격증명 대응 / 이력 보존 / 미복구 감시
# ---------------------------------------------------------------------------

variable "credential_response_enabled" {
  description = "탈취 의심 IAM 액세스키 자동 비활성화 스위치. false면 통보만(드라이런)"
  type        = bool
  default     = true
}

variable "protected_access_key_ids" {
  description = <<-EOT
    자동 비활성화에서 제외할 액세스키 ID 목록(최후의 안전장치).
    비워두는 것이 기본이다 — GuardDuty 자격증명 finding 은 "비정상 사용"을 탐지한
    것이라, 정상 사용 중인 키는 애초에 탐지되지 않는다. 여기에 키를 넣으면 그 키가
    실제로 탈취돼도 자동 대응이 안 되므로, 넣는 순간 그 위험을 감수하는 것이다.
    (이 계정의 IAM 사용자: terra-user — SSO 가 아닌 정적 키 주체)
  EOT
  type        = list(string)
  default     = []
}

variable "quarantine_stale_hours" {
  description = "격리 후 이 시간이 지나도록 복구/정리되지 않으면 재통보 (일일 재구축 환경이라 24h 이상은 비정상)"
  type        = number
  default     = 12
}

variable "isolation_history_retention_days" {
  description = "격리/복구 이력 보존 일수 (DynamoDB TTL). 지나면 자동 삭제되어 비용이 무한 증가하지 않음"
  type        = number
  default     = 90
}

# ---------------------------------------------------------------------------
# (2026-08-13) WAF 자동 차단: 네트워크 기반 finding 의 공격자 IP 를 엣지에서 막는다
# ---------------------------------------------------------------------------

variable "waf_response_enabled" {
  description = "네트워크 기반 GuardDuty finding 의 원격 IP 를 WAF 차단 목록에 자동 추가할지. 기본 false(드라이런) — 관찰 후 켠다. 격리·키 대응과 독립적인 부가 대응이다."
  type        = bool
  default     = false
}

variable "waf_blocklist_ip_set_name" {
  description = "격리 Lambda 가 IP 를 넣고 빼는 CLOUDFRONT WAF IP set 이름(../persistent 소유). 비우면 Lambda 가 WAF 대응을 건너뛴다."
  type        = string
  default     = "gochuchamchi-guardduty-blocklist"
}

variable "waf_block_ttl_hours" {
  description = "WAF 자동 차단 IP 의 유효 시간(시간). 만료되면 audit 경로(매시간)가 목록에서 뺀다 — WAF IP set 에는 TTL 이 없어 코드로 해제한다."
  type        = number
  default     = 24
}

variable "protected_response_ips" {
  description = "WAF 자동 차단에서 제외할 IP(관리자 IP 등). 사설/내부 IP 는 코드가 자동 제외하므로 여기엔 공인 IP 만 넣는다."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# (2026-08-13) 침해 파드 K8s 격리: EKS 런타임 finding 의 파드에 deny-all NetworkPolicy
# ---------------------------------------------------------------------------

variable "pod_response_enabled" {
  description = "EKS 런타임 finding 의 대상 파드에 deny-all NetworkPolicy 를 자동 적용할지. 기본 false(드라이런). Lambda 는 배스천을 SSM 으로 시켜 kubectl 을 돌린다(gochuchamchi 네임스페이스 한정)."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# (2026-08-13) 대응 입력원 확대: Security Hub finding 도 격리 Lambda 로
# ---------------------------------------------------------------------------

variable "securityhub_response_enabled" {
  description = <<-EOT
    Security Hub 의 HIGH/CRITICAL finding(GuardDuty 제품 제외)을 격리 Lambda 로
    보낼지. 기본 false — 리소스(EventBridge 규칙)는 두고 배선(state)만 끈다.
    이건 '입력원' 스위치이고, 실제 격리 실행은 여전히 isolation_enabled 등
    개별 대응 스위치가 게이트한다(이중 게이트). GuardDuty 는 이미 직접 경로로
    처리되므로 Lambda 가 ProductName=GuardDuty 를 걸러 이중 대응을 막는다.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# (2026-08-13) 추가 대응 4종 스위치 (전부 기본 드라이런 — 관찰 후 개별로 켠다)
# ---------------------------------------------------------------------------

variable "iam_subject_response_enabled" {
  description = "탈취 의심 IAM 주체(역할/사용자)에 deny-all 정책을 자동 부착할지. 기본 false. 키 비활성화가 못 잡는 AssumedRole/SSO 세션 대응. 정상 역할에 붙으면 서비스가 마비되므로 protected_iam_principals 로 반드시 걸러야 한다."
  type        = bool
  default     = false
}

variable "protected_iam_principals" {
  description = "IAM 주체 격리에서 제외할 역할/사용자 이름(파드 역할·CI 역할·운영자 등 절대 막으면 안 되는 것). iam_subject_response_enabled 를 켤 때 반드시 채운다."
  type        = list(string)
  default     = []
}

variable "s3_response_enabled" {
  description = "S3 대상 finding 시 버킷에 PublicAccessBlock 을 자동 강제할지. 기본 false. 퍼블릭 차단은 보수적이라 상대적으로 안전하다."
  type        = bool
  default     = false
}

variable "sg_response_enabled" {
  description = "격리 시 원본 SG 의 0.0.0.0/0 위험 인그레스(민감포트/광범위)를 자동 제거할지. 기본 false. 대상을 좁혔지만 정상 규칙 오제거 위험이 있으니 관찰 후 켠다."
  type        = bool
  default     = false
}

variable "snapshot_on_isolate_enabled" {
  description = "EC2 격리 시 EBS 볼륨 포렌식 스냅샷을 자동으로 뜰지. 기본 false. 읽기 전용이라 안전하고 비용만 소폭 든다."
  type        = bool
  default     = false
}

# ============================================================
# 격리/복구 이력 저장소 (2026-08-12)
#
# 왜 필요한가: 지금까지 격리 결과는 SNS 로 흘러가고 사라졌다(인스턴스 포렌식
# 태그만 남는데, 인스턴스가 destroy 되면 그것도 없어진다). "언제 무엇을 왜
# 격리/복구했는가"가 남지 않으면 사후 조사도, 제로트러스트가 요구하는 행위
# 감사도 불가능하다.
#
# DynamoDB 를 쓰는 이유: 조회가 쉽고(인스턴스별/시간별), TTL 로 자동 정리되며,
# on-demand 과금이라 이 정도 쓰기량(격리 이벤트 = 드묾)에서는 사실상 무료다.
# S3 는 append 조회가 번거롭고 Athena 를 또 붙여야 한다.
# ============================================================

resource "aws_dynamodb_table" "isolation_history" {
  name         = "gochuchamchi-isolation-history"
  billing_mode = "PAY_PER_REQUEST"

  # 파티션 키: 대상 리소스(인스턴스 ID 또는 액세스키 ID) — "이 자원에 무슨 일이
  # 있었나"가 가장 흔한 조회다. 정렬 키로 시각을 두어 시간순 이력이 된다.
  hash_key  = "targetId"
  range_key = "eventTime"

  attribute {
    name = "targetId"
    type = "S"
  }

  attribute {
    name = "eventTime"
    type = "S"
  }

  ttl {
    attribute_name = "expiresAt"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true # AWS 관리형 키 — 이력에 비밀값은 안 들어간다
  }

  tags = {
    Name = "gochuchamchi-isolation-history"
  }
}

# ============================================================
# 미복구 격리 감시 — 매시간 점검 (2026-08-12)
#
# 격리해두고 사람이 잊으면 노드가 계속 죽어 있다. 매시간 Lambda 를 audit 모드로
# 깨워 "격리된 지 quarantine_stale_hours 시간이 지난 인스턴스"를 다시 통보한다.
# 별도 Lambda 를 만들지 않고 같은 함수의 action 분기를 쓰는 이유: 격리/복구/감사가
# 같은 태그·같은 이력 테이블을 다루므로 로직이 한 곳에 있는 편이 어긋나지 않는다.
# ============================================================

resource "aws_cloudwatch_event_rule" "quarantine_audit" {
  name                = "gochuchamchi-quarantine-audit"
  description         = "격리 후 미복구 상태가 오래된 인스턴스를 주기적으로 재통보합니다."
  schedule_expression = "rate(1 hour)"
  state               = "ENABLED"

  tags = {
    Name = "gochuchamchi-quarantine-audit"
  }
}

resource "aws_cloudwatch_event_target" "quarantine_audit_lambda" {
  rule      = aws_cloudwatch_event_rule.quarantine_audit.name
  target_id = "InvokeIsolationAudit"
  arn       = aws_lambda_function.guardduty_isolation.arn

  # 같은 Lambda 를 audit 모드로 호출 (격리 경로와 구분되는 유일한 신호)
  input = jsonencode({ action = "audit" })
}

resource "aws_lambda_permission" "allow_eventbridge_audit" {
  statement_id = "AllowExecutionFromEventBridgeAudit"

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guardduty_isolation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.quarantine_audit.arn
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

# AI 트리아지가 켜져 있으면 finding은 트리아지 Lambda로 가고, 이 SNS 직결은
# 사라진다(triage.tf의 aws_cloudwatch_event_target.triage). 여기 남겨 두는 것은
# **롤백 경로**다 — enable_triage=false 한 번으로 트리아지 도입 전 동작으로
# 정확히 되돌아간다. 알림이 끊기는 구간이 없다.
resource "aws_cloudwatch_event_target" "guardduty_sns" {
  count = var.enable_triage ? 0 : 1

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

# ============================================================
# 입력원 2: Security Hub HIGH/CRITICAL finding → 격리 Lambda (2026-08-13)
#   GuardDuty 외 소스(Inspector·Config 등)의 finding 을 대응에 편입한다.
#   ProductName=GuardDuty 는 이미 위 직접 경로가 처리하므로 패턴에서 제외해
#   이중 트리거를 막는다. 리소스는 항상 두고 state 로만 배선을 켠다(트리아지와
#   같은 방식 — 껐다 켜는 데 IAM 전파 대기가 없다).
# ============================================================

resource "aws_cloudwatch_event_rule" "securityhub_finding" {
  name        = "gochuchamchi-securityhub-finding-critical"
  description = "Security Hub HIGH/CRITICAL finding(GuardDuty 제외)을 자동대응 Lambda로 보냅니다."

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]

    detail = {
      findings = {
        Severity    = { Label = ["HIGH", "CRITICAL"] }
        Workflow    = { Status = ["NEW"] }
        RecordState = ["ACTIVE"]
        ProductName = [{ "anything-but" = ["GuardDuty"] }]
      }
    }
  })

  state = var.securityhub_response_enabled ? "ENABLED" : "DISABLED"

  tags = {
    Name = "gochuchamchi-securityhub-finding-critical"
  }
}

resource "aws_cloudwatch_event_target" "securityhub_isolation_lambda" {
  rule      = aws_cloudwatch_event_rule.securityhub_finding.name
  target_id = "InvokeIsolationLambdaFromSecurityHub"
  arn       = aws_lambda_function.guardduty_isolation.arn
}

resource "aws_lambda_permission" "allow_eventbridge_securityhub" {
  statement_id  = "AllowEventBridgeSecurityHubInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guardduty_isolation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.securityhub_finding.arn
}

# ============================================================
# 입력원 3: Log 계정 SIEM detector 의 urgent 판정 → 격리 Lambda (2026-08-13, 크로스계정)
#   Log 계정이 이 default 버스로 put 하는 권한은 log-account-eventbridge.tf 의
#   event_permission 이 이미 계정 단위로 부여한다(이벤트 종류 무관). 여기서는 그
#   이벤트를 격리 Lambda 로 라우팅만 한다. Lambda 는 sourceIps 를 WAF 24h 차단으로만
#   처리하고, 실제 차단은 waf_response_enabled 가 게이트한다(Log 쪽 스위치와 이중).
# ============================================================

resource "aws_cloudwatch_event_rule" "siem_response" {
  name        = "gochuchamchi-siem-response"
  description = "Log 계정 SIEM detector의 urgent 대응 요청(공격자 IP)을 격리 Lambda로 라우팅"

  event_pattern = jsonencode({
    source      = ["gochuchamchi.siem"]
    detail-type = ["SIEM Response Request"]
  })

  state = "ENABLED"

  tags = {
    Name = "gochuchamchi-siem-response"
  }
}

resource "aws_cloudwatch_event_target" "siem_response_isolation" {
  rule      = aws_cloudwatch_event_rule.siem_response.name
  target_id = "InvokeIsolationLambdaFromSiem"
  arn       = aws_lambda_function.guardduty_isolation.arn
}

resource "aws_lambda_permission" "allow_eventbridge_siem_response" {
  statement_id  = "AllowEventBridgeSiemResponseInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.guardduty_isolation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.siem_response.arn
}

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

  # --- 자격증명 대응: 탈취 의심 액세스키 비활성화 ---
  #     ListAccessKeys 는 대상 사용자 확인용. UpdateAccessKey 로 Inactive 전환한다.
  #     삭제(DeleteAccessKey)는 주지 않는다 — 되돌릴 수 없고, 포렌식 증적도 사라진다.
  #     비활성화는 즉시 효력이 있으면서 되돌릴 수 있다.
  statement {
    sid    = "DisableCompromisedAccessKey"
    effect = "Allow"

    actions = [
      "iam:ListAccessKeys",
      "iam:UpdateAccessKey",
    ]

    resources = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/*"]
  }

  # --- 미복구 감시(audit 모드)가 격리 태그로 인스턴스를 찾는다 ---
  #     ec2:DescribeInstances 는 위 DescribeTargets 에 이미 있음.

  # --- 격리/복구/자격증명 대응 이력 적재 + WAF 차단 만료 조회/삭제 ---
  #     GetItem/DeleteItem 은 WAF 자동 차단의 만료 청소(sweep)가 각 IP 의
  #     만료 시각을 읽고, 해제 후 그 항목을 지우는 데 쓴다.
  statement {
    sid    = "WriteIsolationHistory"
    effect = "Allow"

    actions = [
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:GetItem",
      "dynamodb:DeleteItem",
    ]

    resources = [aws_dynamodb_table.isolation_history.arn]
  }

  # --- WAF 자동 차단: 네트워크 기반 finding 의 원격 IP 를 CLOUDFRONT IP set 에
  #     넣고 뺀다. IP set 은 ../persistent 소유이고 CLOUDFRONT scope 라 us-east-1
  #     이지만, ARN 을 특정 이름의 IP set 으로 좁힌다(Id 는 와일드카드) ---
  statement {
    sid    = "ManageWafBlocklist"
    effect = "Allow"

    actions = [
      "wafv2:GetIPSet",
      "wafv2:UpdateIPSet",
    ]

    resources = [
      "arn:aws:wafv2:us-east-1:${data.aws_caller_identity.current.account_id}:global/ipset/${var.waf_blocklist_ip_set_name}/*",
    ]
  }

  # --- IP set 을 이름으로 찾으려면 목록 조회가 필요하다. ListIPSets 는 리소스
  #     수준 제한을 지원하지 않아 * 이지만, 읽기 전용이라 노출 표면이 작다 ---
  statement {
    sid    = "ListWafIpSets"
    effect = "Allow"

    actions = ["wafv2:ListIPSets"]

    resources = ["*"]
  }

  # --- 파드 격리: 배스천을 SSM 으로 시켜 kubectl(deny-all NetworkPolicy)을 돌린다.
  #     Lambda 는 EKS 프라이빗 API 에 직접 붙지 않는다 — 이미 gochuchamchi 네임스페이스
  #     edit 권한이 있는 배스천을 경유한다. SendCommand 는 document 와 instance 를
  #     각각 좁히고(둘 다 매칭돼야 호출됨), instance 는 배스천 태그로만 한정한다 ---
  statement {
    sid       = "SendCommandRunShellDocument"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "SendCommandToBastionOnly"
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Name"
      values   = ["gochuchamchi-bastion"]
    }
  }

  statement {
    sid       = "ReadSsmCommandResult"
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  # --- ① IAM 주체 격리: 탈취 의심 역할/사용자에 deny-all 인라인 정책 부착/제거.
  #     키 비활성화가 못 잡는 AssumedRole/SSO 세션 대응 ---
  statement {
    sid    = "QuarantineIamPrincipal"
    effect = "Allow"
    actions = [
      "iam:PutRolePolicy",
      "iam:PutUserPolicy",
      "iam:DeleteRolePolicy",
      "iam:DeleteUserPolicy",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/*",
    ]
  }

  # --- ② S3 버킷 퍼블릭 차단: 침해로 퍼블릭화된 버킷을 되돌린다 ---
  statement {
    sid       = "BlockS3Public"
    effect    = "Allow"
    actions   = ["s3:PutBucketPublicAccessBlock"]
    resources = ["arn:aws:s3:::*"]
  }

  # --- ③ 위험 SG 규칙 제거 (DescribeSecurityGroups 는 DescribeTargets 에 이미 있음) ---
  statement {
    sid       = "RemoveRiskySgRules"
    effect    = "Allow"
    actions   = ["ec2:RevokeSecurityGroupIngress"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:security-group/*"]
  }

  # --- ④ 격리 시 EBS 포렌식 스냅샷 (읽기 전용 증거 보존) ---
  statement {
    sid       = "ForensicSnapshot"
    effect    = "Allow"
    actions   = ["ec2:CreateSnapshots"]
    resources = ["*"]
  }

  statement {
    sid       = "TagForensicSnapshot"
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:snapshot/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSnapshots"]
    }
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

  # SG 생성 + ENI 교체 + SNS 발행까지. 파드 격리 경로는 배스천 SSM 명령 폴링(최대
  # 50s)이 붙으므로 여유를 둔다.
  timeout     = 120
  memory_size = 128

  environment {
    variables = {
      SNS_TOPIC_ARN               = aws_sns_topic.alerts.arn
      MIN_SEVERITY                = tostring(var.guardduty_isolate_min_severity)
      QUARANTINE_SG_NAME          = "gochuchamchi-quarantine"
      ISOLATION_ENABLED           = var.isolation_enabled ? "true" : "false"
      PROTECTED_INSTANCE_TAG_KEYS = join(",", var.protected_instance_tag_keys)

      # (2026-08-12) 자동대응 확장
      HISTORY_TABLE               = aws_dynamodb_table.isolation_history.name
      HISTORY_RETENTION_DAYS      = tostring(var.isolation_history_retention_days)
      CREDENTIAL_RESPONSE_ENABLED = var.credential_response_enabled ? "true" : "false"
      PROTECTED_ACCESS_KEY_IDS    = join(",", var.protected_access_key_ids)
      QUARANTINE_STALE_HOURS      = tostring(var.quarantine_stale_hours)

      # (2026-08-13) WAF 자동 차단
      WAF_RESPONSE_ENABLED      = var.waf_response_enabled ? "true" : "false"
      WAF_BLOCKLIST_IP_SET_NAME = var.waf_blocklist_ip_set_name
      WAF_BLOCK_TTL_HOURS       = tostring(var.waf_block_ttl_hours)
      PROTECTED_IPS             = join(",", var.protected_response_ips)

      # (2026-08-13) 침해 파드 K8s 격리 (배스천 SSM 경유)
      POD_RESPONSE_ENABLED = var.pod_response_enabled ? "true" : "false"
      BASTION_TAG_NAME     = "gochuchamchi-bastion"

      # (2026-08-13) 추가 대응 4종 (IAM 주체 격리 / S3 퍼블릭 차단 / SG 규칙 제거 / EBS 스냅샷)
      IAM_SUBJECT_RESPONSE_ENABLED = var.iam_subject_response_enabled ? "true" : "false"
      PROTECTED_IAM_PRINCIPALS     = join(",", var.protected_iam_principals)
      S3_RESPONSE_ENABLED          = var.s3_response_enabled ? "true" : "false"
      SG_RESPONSE_ENABLED          = var.sg_response_enabled ? "true" : "false"
      SNAPSHOT_ON_ISOLATE_ENABLED  = var.snapshot_on_isolate_enabled ? "true" : "false"
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
