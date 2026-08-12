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
  description = <<-EOT
    Bedrock 호출에 쓸 모델 ID. **추론 프로파일 ID를 넣는다.**

    Claude Opus 5는 ap-northeast-2에서 inferenceTypesSupported=INFERENCE_PROFILE
    만 지원한다(ON_DEMAND 없음). 기반 모델 ID(anthropic.claude-opus-5)를 그대로
    넣으면 모델 액세스를 켜도 ValidationException이 난다.

    서울에서 잡히는 범위별 최신 모델:
      global.*  Opus 5 / Sonnet 5 / Opus 4.8 / Haiku 4.5 — 전 세계 리전 라우팅
      apac.*    Sonnet 4(2025-05)가 최신, 그 위로는 없음 — APAC 내 라우팅

    ※ global 프로파일은 요청이 APAC 밖에서 실행될 수 있다. 모델에 나가는 것은
      화이트리스트 투영된 finding + context.md + CloudTrail 요약이라 고객 데이터는
      없지만, ARN·IP·계정 ID·리소스 이름 등 인프라 메타데이터는 포함된다.
      데이터 반출이 협상 불가 조건인 환경이라면 apac.* 로 내리되, 그쪽 최신이
      deprecated 모델이라는 부채를 같이 받는다.
  EOT
  type        = string
  default     = "global.anthropic.claude-opus-5"
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

  # 추론 프로파일 ID에서 기반 모델 ID를 뽑는다(global.anthropic.claude-opus-5
  # → anthropic.claude-opus-5). IAM의 foundation-model ARN은 프로파일이 아니라
  # 기반 모델을 가리켜야 하므로 접두사를 떼지 않으면 존재하지 않는 ARN이 된다.
  # 프로파일이 아닌 기반 모델 ID를 넣은 경우엔 아무것도 바뀌지 않는다.
  ai_triage_base_model_id = replace(var.ai_triage_model_id, "/^(global|apac|us|eu)\\./", "")
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

  # ※ context.md 는 여기 넣지 않는다. 아래 S3 섹션 주석 참고.
}

# ============================================================
# 환경 컨텍스트 저장소 (S3 + 전용 CMK)
#
# context.md 를 함수 zip 에서 뺀 이유:
#   lambda:GetFunction 은 배포 패키지의 presigned URL 을 돌려준다. 그 권한은
#   ReadOnlyAccess 관리형 정책에 들어 있어서, 읽기 전용으로 받은 사람도 zip 을
#   내려받아 context.md 를 열 수 있었다. 이 파일은 계정 ID·네트워크 구조·IAM
#   주체·배치된 통제·탐지 우선순위, 그리고 스스로 적어 둔 방어 공백까지 한 장에
#   모아 둔 문서다. 흩어진 사실 자체는 AWS 가 이미 갖고 있지만, 이렇게 조립된
#   형태는 이 파이프라인이 처음 만들어 낸 것이라 노출 시 가치가 다르다.
#
# S3 로 옮기는 것만으로는 부족하다 — ReadOnlyAccess 에는 s3:GetObject 도 있다.
# 실효는 SSE-KMS 에서 나온다. SSE-KMS 객체는 요청자 본인이 kms:Decrypt 를
# 가져야 읽히는데 ReadOnlyAccess 에는 Decrypt 가 없다. 객체는 받아도 평문을
# 얻지 못한다.
#
# 버킷 정책 explicit Deny 는 쓰지 않는다. 배포 주체까지 함께 걸려 버킷을
# 관리 불능으로 만드는 사고가 흔하다. 통제는 키 정책 한 곳에만 둔다.
#
# 전용 키를 새로 만든다. alias/gochuchamchi-data 를 재사용하면 그쪽 스택의
# 키 정책을 고쳐야 해서 스택 간 결합이 생긴다.
# ============================================================

data "aws_iam_policy_document" "ai_triage_context_key" {
  count = local.ai_triage_enabled

  # 계정 IAM 에 위임. 이 문장이 없으면 키를 다시 관리할 수 없게 된다.
  # 이로써 AdministratorAccess 는 여전히 복호화할 수 있지만, 관리자는 어차피
  # 무엇이든 읽을 수 있으므로 이 설계가 막으려는 대상이 아니다.
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowTriageLambdaDecrypt"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ai_triage[0].arn]
    }

    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
  }
}

resource "aws_kms_key" "ai_triage_context" {
  count = local.ai_triage_enabled

  description             = "AI 트리아지 환경 컨텍스트(context.md) 암호화 전용"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.ai_triage_context_key[0].json

  tags = {
    Name = "gochuchamchi-ai-triage-context"
  }
}

resource "aws_kms_alias" "ai_triage_context" {
  count = local.ai_triage_enabled

  name          = "alias/gochuchamchi-ai-triage-context"
  target_key_id = aws_kms_key.ai_triage_context[0].key_id
}

resource "aws_s3_bucket" "ai_triage_context" {
  count = local.ai_triage_enabled

  bucket = "gochuchamchi-ai-triage-context-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name = "gochuchamchi-ai-triage-context"
  }
}

resource "aws_s3_bucket_public_access_block" "ai_triage_context" {
  count = local.ai_triage_enabled

  bucket = aws_s3_bucket.ai_triage_context[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "ai_triage_context" {
  count = local.ai_triage_enabled

  bucket = aws_s3_bucket.ai_triage_context[0].id

  # 인프라가 바뀔 때마다 갱신되는 문서다. 잘못 고쳐 판정 품질이 무너졌을 때
  # 되돌릴 수 있어야 하고, 언제 무엇이 바뀌었는지도 남아야 한다.
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ai_triage_context" {
  count = local.ai_triage_enabled

  bucket = aws_s3_bucket.ai_triage_context[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.ai_triage_context[0].arn
    }

    # 객체가 하나뿐이라 큰 차이는 없지만, KMS 요청 수를 줄인다.
    bucket_key_enabled = true
  }
}

resource "aws_s3_object" "ai_triage_context" {
  count = local.ai_triage_enabled

  bucket = aws_s3_bucket.ai_triage_context[0].id
  key    = "context.md"

  # content 가 아니라 source 를 쓴다. content 로 넣으면 파일 내용이 tfstate 에
  # 그대로 박힌다 — 패키지에서 빼 놓고 state 로 새면 한 일이 없어진다.
  source = "${local.ai_triage_dir}/context.md"
  etag   = filemd5("${local.ai_triage_dir}/context.md")

  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.ai_triage_context[0].arn
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
      # 기반 모델은 리전 와일드카드여야 한다. 교차 리전 프로파일(global.*/apac.*)은
      # 요청을 다른 리전에서 실행하는데, 그때 그 리전의 기반 모델 권한을 본다.
      # 호출 리전만 박아 두면 라우팅된 순간 AccessDeniedException이 난다.
      "arn:aws:bedrock:*::foundation-model/${local.ai_triage_base_model_id}",
      # 프로파일 자체는 호출 리전의 것을 참조한다. 와일드카드였던 것을
      # 실제 쓰는 프로파일 하나로 좁힌다.
      "arn:aws:bedrock:${local.ai_triage_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.ai_triage_model_id}",
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

  # --- 환경 컨텍스트 읽기 ---
  # 객체 하나로 좁힌다. 이 역할은 버킷을 나열할 필요도 없다.
  statement {
    sid       = "ReadTriageContext"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ai_triage_context[0].arn}/context.md"]
  }

  # SSE-KMS 객체는 요청자 본인의 Decrypt 권한으로 풀린다. 이 문장이 실질적인
  # 접근 통제이고, 키 정책과 짝을 이뤄야 동작한다.
  statement {
    sid       = "DecryptTriageContext"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.ai_triage_context[0].arn]
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
      SNS_TOPIC_ARN     = aws_sns_topic.alerts.arn
      TRIAGE_TABLE_NAME = aws_dynamodb_table.ai_triage[0].name

      # 환경 컨텍스트는 패키지가 아니라 S3에서 읽는다(위 S3 섹션 주석 참고).
      # ※ context.md 를 고쳐도 함수 코드 해시는 안 바뀐다. 즉 apply 해도 웜
      #   실행 환경은 옛 내용을 계속 들고 있다 — 즉시 반영하려면 실행 환경이
      #   교체되도록 Lambda 설정을 한 번 건드릴 것.
      CONTEXT_BUCKET = aws_s3_bucket.ai_triage_context[0].id
      CONTEXT_KEY    = aws_s3_object.ai_triage_context[0].key

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
