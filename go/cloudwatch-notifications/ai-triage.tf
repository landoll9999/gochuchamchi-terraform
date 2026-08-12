# ============================================================
# GuardDuty finding AI 트리아지 (2026-08-12 도입)
#
# 무엇을 푸는가 — 멘토 피드백 그대로:
#   "GuardDuty는 오탐이 너무 많아 현업에서 잘 안 쓴다. 제대로 쓰려면 들어오는
#    필드값을 다 쪼개서 의미 있는 것에만 경고를 올리도록 커스텀해야 하는데,
#    클라우드 변화가 빨라 그 커스텀을 유지하는 게 힘들다."
#   → 그 "커스텀 룰"을 사람이 유지보수하는 대신 모델이 매 건 판단하게 한다.
#     룰 테이블이 아니라 ai-triage/context.md 한 장을 최신으로 유지하면 된다.
#
# 배선 (통보 경로에만 끼어든다):
#   GuardDuty → EventBridge(severity>=4) → [AI 트리아지 Lambda] → SNS → Discord
#
#   ※ 대응 경로(severity>=7 → 격리 Lambda)는 건드리지 않았다. 격리는 AI 판정을
#     기다리지 않고 즉시 실행된다 — 모델 지연·장애·오판이 실제 대응을 막으면
#     안 되기 때문. 두 경로는 EventBridge에서 갈라져 서로를 모른다.
#
# 왜 Bedrock인가: API 키가 아예 없다. 인증이 Lambda 실행 역할의 IAM으로만
#   이뤄지므로 "키를 state에 넣지 않는다"(handoff §5-3 ③)가 설계상 자동 충족되고,
#   Secrets Manager 로테이션·유출 대응 부담이 사라진다.
# ============================================================

variable "enable_ai_triage" {
  description = <<-EOT
    AI 트리아지 온오프. false로 되돌리면 GuardDuty 통보가 이 Lambda를 거치지
    않고 예전처럼 SNS로 직결된다(guardduty-response.tf의 target이 되살아남).
    알림 자체는 어느 쪽이든 끊기지 않는 것이 이 스위치의 요점.
  EOT
  type        = bool
  default     = true
}

variable "ai_triage_model_id" {
  description = "Bedrock 모델 ID. Bedrock은 1st-party ID 앞에 anthropic. 접두사가 붙는다"
  type        = string
  default     = "anthropic.claude-opus-5"
}

variable "ai_triage_bedrock_region" {
  description = <<-EOT
    Bedrock 호출 리전. 빈 값이면 var.region(ap-northeast-2)을 쓴다.
    서울 리전에서 해당 모델이 서빙되지 않거나 모델 액세스를 못 받으면
    us-west-2 등으로 바꿀 수 있다 — finding 데이터가 그 리전으로 나가는
    것이므로 데이터 반출 정책을 먼저 확인할 것.
  EOT
  type        = string
  default     = ""
}

variable "ai_triage_effort" {
  description = "output_config.effort — low/medium/high/xhigh/max. 트리아지는 분류에 가까워 medium이 기본"
  type        = string
  default     = "medium"

  validation {
    condition     = contains(["low", "medium", "high", "xhigh", "max"], var.ai_triage_effort)
    error_message = "effort는 low, medium, high, xhigh, max 중 하나여야 합니다."
  }
}

# ※ severity 하한(비용 게이트 1)에 별도 변수를 두지 않는다.
#   guardduty-response.tf의 Rule 1이 쓰는 guardduty_notify_min_severity와
#   guardduty_always_notify_type_prefixes를 그대로 재사용한다. 값을 두 벌 두면
#   반드시 어긋나고, 어긋나는 순간 "룰은 통과시켰는데 Lambda가 버리는" 구멍이
#   생긴다 — 실제로 (A) 갈래의 severity 2짜리 루트 사용 finding이 그 구멍에
#   빠질 뻔했다.

variable "ai_triage_daily_call_limit" {
  description = <<-EOT
    하루 모델 호출 상한 (비용 게이트 4). 초과분은 AI 판정 없이 통보된다.
    finding 폭주 시 비용이 선형으로 늘지 않게 하는 하드 상한 — 멘토가 지적한
    "전량 분석 시 토큰 비용이 관건"에 대한 직접적인 답.
  EOT
  type        = number
  default     = 200
}

variable "ai_triage_cache_ttl_hours" {
  description = "같은 (finding 타입 × 리소스) 판정을 재사용하는 시간 (비용 게이트 3)"
  type        = number
  default     = 6
}

variable "ai_triage_suppress_finding_types" {
  description = <<-EOT
    모델을 부르지 않고 정상으로 분류할 finding 타입 접두사 (비용 게이트 2).
    억제해도 알림은 나간다 — 등급만 내려간다.

    ※ 순수 소음(PortProbe·BruteForce)은 여기가 아니라 Rule 1의
      guardduty_notify_noise_types에 넣는다. 그쪽은 EventBridge에서 아예
      걸러져 Lambda 호출조차 안 일어나므로 더 싸다. 이 목록은 "알림은 받되
      AI 판단은 필요 없는" 중간 지대용이다.
  EOT
  type        = list(string)
  default     = []
}

variable "ai_triage_enrich_cloudtrail" {
  description = "finding 주체의 최근 CloudTrail 이벤트를 프롬프트에 붙일지 여부"
  type        = bool
  default     = true
}

variable "ai_triage_timeout" {
  description = "Lambda 타임아웃(초). adaptive thinking + effort에 따라 모델 응답이 수십 초 걸릴 수 있음"
  type        = number
  default     = 120
}

locals {
  ai_triage_enabled = var.enable_ai_triage ? 1 : 0
  ai_triage_region  = var.ai_triage_bedrock_region != "" ? var.ai_triage_bedrock_region : var.region
  ai_triage_dir     = "${path.module}/ai-triage"
}

# ============================================================
# Lambda 레이어 — Anthropic SDK
#
# 기존 Lambda들과 달리 순수 stdlib으로 안 되는 유일한 이유는 SDK 의존성이다.
# pydantic-core·jiter가 컴파일 확장이라 로컬(Windows) 휠을 그대로 올리면
# import에서 죽는다 → build-layer.ps1이 manylinux/cp312 휠을 받아 온다.
#
# terraform_data는 requirements.txt나 빌드 스크립트가 바뀔 때만 다시 돈다.
# archive_file은 data 소스지만 depends_on이 걸려 있어 plan이 아닌 apply 시점에
# 읽힌다 — 빌드보다 먼저 zip을 읽어 "디렉터리 없음"으로 실패하는 것을 막는다.
# ============================================================

resource "terraform_data" "ai_triage_layer_build" {
  count = local.ai_triage_enabled

  triggers_replace = [
    filesha256("${local.ai_triage_dir}/requirements.txt"),
    filesha256("${local.ai_triage_dir}/build-layer.ps1"),
  ]

  provisioner "local-exec" {
    # Windows 로컬 apply 전제. Linux CI에서 돌릴 일이 생기면 같은 내용의 sh
    # 스크립트를 추가하고 여기서 분기할 것.
    interpreter = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
    command     = "${local.ai_triage_dir}/build-layer.ps1"
  }
}

data "archive_file" "ai_triage_layer" {
  count = local.ai_triage_enabled

  type        = "zip"
  source_dir  = "${local.ai_triage_dir}/build/layer"
  output_path = "${local.ai_triage_dir}/build/ai-triage-layer.zip"

  depends_on = [terraform_data.ai_triage_layer_build]
}

resource "aws_lambda_layer_version" "anthropic_sdk" {
  count = local.ai_triage_enabled

  layer_name  = "gochuchamchi-anthropic-sdk"
  description = "Anthropic SDK (Bedrock) — AI 트리아지 Lambda 전용"

  filename         = data.archive_file.ai_triage_layer[0].output_path
  source_code_hash = data.archive_file.ai_triage_layer[0].output_base64sha256

  compatible_runtimes      = ["python3.12"]
  compatible_architectures = ["x86_64"]
}

# ============================================================
# 함수 코드 ZIP
#
# source_dir가 아니라 source 블록을 쓰는 이유: 같은 디렉터리에 빌드 산출물
# (build/, 수십 MB)과 requirements.txt가 있어서, 디렉터리째 압축하면 레이어가
# 함수 zip 안에 통째로 또 들어간다.
# ============================================================

data "archive_file" "ai_triage_function" {
  count = local.ai_triage_enabled

  type        = "zip"
  output_path = "${path.module}/ai-triage-function.zip"

  source {
    content  = file("${local.ai_triage_dir}/ai_triage_function.py")
    filename = "ai_triage_function.py"
  }

  source {
    # 프롬프트에 주입되는 환경 컨텍스트. 코드와 분리해 둬서 인프라가 바뀔 때
    # 파이썬을 안 건드리고 이 파일만 고치면 된다.
    content  = file("${local.ai_triage_dir}/context.md")
    filename = "context.md"
  }
}

# ============================================================
# 판정 캐시 + 일일 호출 카운터 (DynamoDB)
#
# 테이블 하나에 두 종류의 아이템이 산다:
#   finding#<sha256>  — 판정 캐시 (TTL: ai_triage_cache_ttl_hours)
#   quota#YYYY-MM-DD  — 그날의 모델 호출 횟수 (TTL 3일)
# 온디맨드 과금이라 유휴 비용은 사실상 0이고, TTL이 정리까지 해준다.
# ============================================================

resource "aws_dynamodb_table" "ai_triage" {
  count = local.ai_triage_enabled

  name         = "gochuchamchi-ai-triage"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "triage_key"

  attribute {
    name = "triage_key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = {
    Name = "gochuchamchi-ai-triage"
  }
}

# ============================================================
# 실행 역할
# ============================================================

resource "aws_iam_role" "ai_triage" {
  count = local.ai_triage_enabled

  name = "gochuchamchi-ai-triage-lambda"

  # lambda.tf의 신뢰 정책 재사용 (동일 서비스 principal)
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = "gochuchamchi-ai-triage-lambda"
  }
}

resource "aws_iam_role_policy_attachment" "ai_triage_basic_execution" {
  count = local.ai_triage_enabled

  role       = aws_iam_role.ai_triage[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ai_triage" {
  count = local.ai_triage_enabled

  # --- 모델 호출 ---
  # 파운데이션 모델 ARN은 계정 필드가 비어 있다(AWS 소유 리소스).
  # 추론 프로파일은 리전 간 라우팅에 쓰이며 계정 소유라 별도 항목이 필요하다.
  # ※ 첫 apply 후 실제 호출로 권한 부족(AccessDeniedException)이 안 나는지
  #   반드시 확인할 것 — Bedrock은 IAM 통과 후에도 "모델 액세스" 승인이
  #   따로 필요하며, 그건 콘솔에서 하는 별개 작업이다.
  statement {
    sid    = "InvokeTriageModel"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]

    resources = [
      "arn:aws:bedrock:${local.ai_triage_region}::foundation-model/${var.ai_triage_model_id}",
      "arn:aws:bedrock:${local.ai_triage_region}:${data.aws_caller_identity.current.account_id}:inference-profile/*",
    ]
  }

  # --- 판정 캐시 / 호출 상한 ---
  statement {
    sid    = "TriageStateTable"
    effect = "Allow"

    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
    ]

    resources = [aws_dynamodb_table.ai_triage[0].arn]
  }

  # --- 컨텍스트 보강 ---
  # LookupEvents는 리소스 수준 제한을 지원하지 않아 * 밖에 쓸 수 없다.
  # 읽기 전용이고 이벤트 히스토리(90일)만 본다.
  statement {
    sid       = "EnrichFromCloudTrail"
    effect    = "Allow"
    actions   = ["cloudtrail:LookupEvents"]
    resources = ["*"]
  }

  # --- 결과 통보: 알림 허브로만 ---
  statement {
    sid       = "PublishVerdict"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  # --- 비동기 호출 실패분을 기존 알림 DLQ로 ---
  # 이 Lambda가 통째로 죽으면 판정도 통보도 없이 finding이 사라진다. DLQ에
  # 쌓이면 sns.tf의 DLQ 알람이 ALARM으로 가고, 그 알람은 SNS를 통해 이메일로
  # 직접 전달된다 — Discord Lambda가 같이 죽어 있어도 사람이 알 수 있다.
  statement {
    sid       = "DeadLetterOnFailure"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.alerts_dlq.arn]
  }
}

resource "aws_iam_role_policy" "ai_triage" {
  count = local.ai_triage_enabled

  name   = "gochuchamchi-ai-triage"
  role   = aws_iam_role.ai_triage[0].id
  policy = data.aws_iam_policy_document.ai_triage[0].json
}

# ============================================================
# 트리아지 Lambda
# ============================================================

resource "aws_lambda_function" "ai_triage" {
  count = local.ai_triage_enabled

  function_name = "gochuchamchi-ai-triage"

  role    = aws_iam_role.ai_triage[0].arn
  handler = "ai_triage_function.lambda_handler"
  runtime = "python3.12"

  # 레이어를 manylinux x86_64로 빌드했으므로 아키텍처를 명시해 고정한다.
  architectures = ["x86_64"]
  layers        = [aws_lambda_layer_version.anthropic_sdk[0].arn]

  filename         = data.archive_file.ai_triage_function[0].output_path
  source_code_hash = data.archive_file.ai_triage_function[0].output_base64sha256

  timeout = var.ai_triage_timeout

  # SDK import + pydantic 로딩이 있어 128MB로는 콜드스타트가 길다.
  # 메모리는 CPU 배분과 연동되므로 512가 오히려 총 과금 시간이 짧다.
  memory_size = 512

  dead_letter_config {
    target_arn = aws_sqs_queue.alerts_dlq.arn
  }

  environment {
    variables = {
      SNS_TOPIC_ARN          = aws_sns_topic.alerts.arn
      TRIAGE_TABLE_NAME      = aws_dynamodb_table.ai_triage[0].name
      BEDROCK_REGION         = local.ai_triage_region
      MODEL_ID               = var.ai_triage_model_id
      EFFORT                 = var.ai_triage_effort
      DAILY_CALL_LIMIT       = tostring(var.ai_triage_daily_call_limit)
      CACHE_TTL_SECONDS      = tostring(var.ai_triage_cache_ttl_hours * 3600)
      SUPPRESS_FINDING_TYPES = join(",", var.ai_triage_suppress_finding_types)
      ENRICH_CLOUDTRAIL      = var.ai_triage_enrich_cloudtrail ? "true" : "false"

      # Rule 1과 같은 값을 주입한다 — Lambda의 severity 게이트가 룰의 두 갈래를
      # 그대로 재현하게 해서, (A) 갈래로 들어온 저심각도 finding이 게이트에
      # 걸려 판정을 못 받는 일을 구조적으로 막는다.
      AI_MIN_SEVERITY             = tostring(var.guardduty_notify_min_severity)
      ALWAYS_TRIAGE_TYPE_PREFIXES = join(",", var.guardduty_always_notify_type_prefixes)
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.ai_triage_basic_execution,
    aws_iam_role_policy.ai_triage,
  ]

  tags = {
    Name = "gochuchamchi-ai-triage"
  }
}

# ============================================================
# 통보 경로를 트리아지 Lambda로 우회
#
# 기존: guardduty_finding rule → SNS 허브 (guardduty-response.tf, 이제 count=0)
# 변경: guardduty_finding rule → 이 Lambda → (판정 부착) → SNS 허브
# ============================================================

resource "aws_cloudwatch_event_target" "guardduty_ai_triage" {
  count = local.ai_triage_enabled

  rule      = aws_cloudwatch_event_rule.guardduty_finding.name
  target_id = "SendGuardDutyFindingToAiTriage"
  arn       = aws_lambda_function.ai_triage[0].arn
}

resource "aws_lambda_permission" "allow_eventbridge_ai_triage" {
  count = local.ai_triage_enabled

  statement_id = "AllowExecutionFromEventBridge"

  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ai_triage[0].function_name
  principal     = "events.amazonaws.com"

  # 통보 rule에서 온 호출만 허용 (sns.tf·guardduty-response.tf와 같은 원칙)
  source_arn = aws_cloudwatch_event_rule.guardduty_finding.arn
}

# ============================================================
# 출력
# ============================================================

output "ai_triage_function_name" {
  description = "AI 트리아지 Lambda 이름 (로그: aws logs tail /aws/lambda/<이 값> --follow)"
  value       = var.enable_ai_triage ? aws_lambda_function.ai_triage[0].function_name : null
}

output "ai_triage_metrics_namespace" {
  description = "토큰 사용량·판정 분포 지표 네임스페이스 (CloudWatch > Metrics)"
  value       = var.enable_ai_triage ? "Gochuchamchi/AITriage" : null
}
