# ============================================================
# GuardDuty AI 트리아지 (2026-08-13)
#
#   GuardDuty finding
#      │
#      ├─ Rule 1 (타입/severity 필터) ─→ [트리아지 Lambda] ─→ SNS 허브 ─→ Discord/이메일
#      │                                    필터 → Groq 판정 → 정책 표
#      │
#      └─ Rule 2 (severity >= 7) ─────→ [격리 Lambda]
#                                          AI를 기다리지 않는다
#
# 필터와 판단은 층이 다르다. Rule 1의 이벤트 패턴이 "무엇을 볼지"를
# EventBridge에서 공짜로 정하고(걸리면 Lambda 호출조차 없다), 트리아지는
# 살아남은 것에 대해서만 "그중 무엇이 진짜인지"를 붙인다. 소음 제거를
# 모델에 시키면 그게 곧 토큰 낭비다.
#
# 두 경로는 EventBridge에서 갈라져 서로를 모른다. 대응(격리)이 모델 지연·
# 장애·오판에 걸리면 안 되기 때문이다. 이 변경은 통보 경로에만 끼어든다.
#
# ── 왜 Bedrock이 아니라 Groq인가
#    개인 프로젝트 규모라 Bedrock 종량 비용을 감당할 여유가 없다는 판단.
#    gpt-oss-120b 기준 finding 1건 판정이 약 $0.0006이고, 캐시·상한까지
#    걸어 두면 월 $1을 넘기기 어렵다.
#    대가는 두 가지이고 코드에서 각각 막았다:
#      - API 키가 생긴다  → Secrets Manager에 수동 주입(state 오염 방지)
#      - 데이터가 AWS 밖으로 나간다 → 화이트리스트 투영 + 계정ID/사설IP/이메일
#        가명화 (triage/judge.py). 원본은 GuardDuty와 Discord에 그대로 남는다.
# ============================================================

variable "enable_triage" {
  description = <<-EOT
    AI 트리아지 on/off. false면 EventBridge 타겟이 SNS 직결로 되돌아간다
    (트리아지 도입 전 동작). **알림 자체는 끊기지 않고 판정만 없어진다.**

    기본값이 false인 이유: 2026-08-13에 적용했다가 판정 provider를 다시
    검토하기로 하면서 배선을 껐다. 기본값이 true로 남아 있으면 이 루트를
    apply하는 사람이 의도치 않게 트리아지를 되살리게 되고, 그때 시크릿에
    들어 있는 키가 유효한지 아무도 확인하지 않는다. **코드의 기본값과 실제
    배포 상태를 일치시켜 두는 것이 이 변수의 유일한 안전장치다.**

    켤 때는 명시적으로 켠다:
        $env:TF_VAR_enable_triage = "true"
    켜기 전에 시크릿의 API 키가 유효한지 먼저 확인할 것
    (triage/compare-providers.py 로 판정이 실제로 나오는지 확인).

    즉시 멈춰야 할 때 EventBridge 룰을 disable하지 말 것 — 룰을 끄면
    통보 경로 전체가 죽는다. 이 변수로 끄면 SNS 직결로 안전하게 되돌아간다.
  EOT
  type        = bool
  default     = false
}

variable "triage_judge_enabled" {
  description = "Groq 판정 on/off. false면 모든 finding이 UNCERTAIN으로 처리돼 정책 표대로 통보된다(소음 증가, 탐지 공백 없음)"
  type        = bool
  default     = true
}

variable "triage_provider" {
  description = <<-EOT
    판정을 맡길 API 규격. groq/openai/gemini는 OpenAI Chat Completions 규격을
    공유하고 anthropic만 Messages API로 갈라진다. 시크릿에 넣는 키도 여기에
    맞춰야 한다 (groq=gsk_…, openai=sk-…, gemini=AIza…, anthropic=sk-ant-…).

    ⚠️ gemini는 구글의 OpenAI 호환 레이어를 태운다. 그 레이어는 베타이고
    response_format 지원이 문서에 명시돼 있지 않으므로, 켜기 전에
    compare-providers.py 로 실제 판정이 나오는지 반드시 확인할 것.

    provider를 바꾸기 전에 triage/compare-providers.py로 같은 표본을 태워
    판정을 비교할 것 — 비용만 보고 고르면 알림 품질이 조용히 나빠진다.

    ⚠️ Claude를 쓰려면 반드시 "anthropic"이다. OpenAI 호환 레이어
    (base_url=api.anthropic.com/v1/)로 부르면 response_format이 **무시되어**
    구조화 출력이 깨지고, 모든 finding이 조용히 "판정 없음"이 된다.
  EOT
  type        = string
  default     = "groq"

  validation {
    condition     = contains(["groq", "openai", "gemini", "anthropic"], var.triage_provider)
    error_message = "triage_provider는 groq, openai, gemini, anthropic 중 하나여야 합니다."
  }
}

variable "triage_groq_model" {
  description = <<-EOT
    판정에 쓸 모델 ID. 빈 문자열이면 provider별 기본 모델을 쓴다
    (groq=openai/gpt-oss-120b, openai=gpt-4o-mini, gemini=gemini-3.6-flash,
    anthropic=claude-haiku-4-5).

    Groq에서 gpt-oss-120b를 택한 근거(2026-08-12 실측): llama-3.3-70b보다
    싸고(입력 1/4) 빠르고(1.8배) 크며, Llama 3.3은 공식 지원 언어에 한국어가 없다.

    ⚠️ provider와 짝이 맞아야 한다. provider만 바꾸고 모델을 그대로 두면 404가
    나고 모든 판정이 "판정 없음"이 된다. 헷갈리면 비워 두는 편이 안전하다.

    ⚠️ "그록 컴파운드"처럼 웹 검색·코드 실행 도구가 붙은 시스템은 쓰지 말 것.
    판정 입력에는 공격자가 값을 정할 수 있는 문자열(인스턴스 태그, 버킷 이름,
    User-Agent)이 들어가므로, 도구가 붙으면 프롬프트 인젝션이 오판을 넘어
    실제 외부 요청으로 증폭된다.

    ⚠️ 모델 목록은 수시로 바뀐다. 없는 모델이면 모든 판정이 "판정 없음"이
    되는데 알림은 계속 나오므로 알아채기 어렵다.
  EOT
  type        = string
  default     = ""
}

variable "triage_groq_endpoint" {
  description = <<-EOT
    판정 API 엔드포인트. 비우면 provider 기본값을 쓴다 — provider만 바꾸고
    엔드포인트를 옛 값으로 남겨 두는 사고를 막기 위해 기본값을 비워 두었다.
    프록시를 태우거나 호환 게이트웨이를 쓸 때만 채운다.
  EOT
  type        = string
  default     = ""
}

variable "triage_groq_max_tokens" {
  description = <<-EOT
    판정 응답의 최대 출력 토큰. gpt-oss 계열은 추론 모델이라 최종 JSON 앞에
    사고 과정 토큰을 먼저 생성한다. 빠듯하면 JSON을 시작하기도 전에 예산이
    소진돼 400 json_validate_failed로 떨어진다(700으로 잡았다가 만난 문제).
    상한이지 지출이 아니다 — 생성된 토큰만 과금된다.
  EOT
  type        = number
  default     = 4000
}

variable "triage_groq_reasoning_effort" {
  description = <<-EOT
    추론 깊이(low/medium/high). 사고 과정 토큰도 출력 단가로 과금되므로 이
    값이 곧 판정 비용이다. finding 한 건을 보고 정상 자동화인지 가르는 일이라
    low로 충분하다. 빈 문자열이면 파라미터를 아예 안 보낸다(허용값이 다른
    모델을 위한 탈출구 — 코드에도 자동 재시도가 있다).
  EOT
  type        = string
  default     = "low"

  validation {
    condition     = contains(["", "low", "medium", "high"], var.triage_groq_reasoning_effort)
    error_message = "triage_groq_reasoning_effort는 \"\", low, medium, high 중 하나여야 합니다."
  }
}

variable "triage_policy_matrix" {
  description = <<-EOT
    (심각도 × AI 판정) → 액션. 로그 담당자 요구 구조를 그대로 표로 옮긴 것이고,
    **코드 배포 없이 tfvars만 고쳐 정책을 바꿀 수 있다.**

    액션:
      urgent     🚨 긴급 (Discord 통보)
      alert      🔴 알림
      review     🟡 검토 필요
      likely_fp  ⚪ 오탐 의심 (통보는 하되 낮은 우선순위로)
      suppress   🔇 통보 안 함
      store      📦 통보 안 함 (GuardDuty에 그대로 보관됨)

    ⚠️ 알림이 사라지는 칸은 MEDIUM × FALSE_POSITIVE 하나뿐이고, 그것도
    triage_suppress_min_confidence를 통과해야 한다. 이 칸을 늘릴수록
    모델 오판이 곧 미탐이 된다.
  EOT
  type        = map(map(string))

  default = {
    CRITICAL = { TRUE_POSITIVE = "urgent", UNCERTAIN = "urgent", FALSE_POSITIVE = "urgent" }
    HIGH     = { TRUE_POSITIVE = "urgent", UNCERTAIN = "review", FALSE_POSITIVE = "likely_fp" }
    MEDIUM   = { TRUE_POSITIVE = "alert", UNCERTAIN = "review", FALSE_POSITIVE = "suppress" }
    LOW      = { TRUE_POSITIVE = "alert", UNCERTAIN = "store", FALSE_POSITIVE = "store" }
  }

  validation {
    condition = alltrue([
      for tier, row in var.triage_policy_matrix : alltrue([
        for verdict, action in row :
        contains(["urgent", "alert", "review", "likely_fp", "suppress", "store"], action)
      ])
    ])
    error_message = "액션은 urgent/alert/review/likely_fp/suppress/store 중 하나여야 합니다."
  }

  validation {
    condition     = alltrue([for tier in ["CRITICAL", "HIGH", "MEDIUM", "LOW"] : contains(keys(var.triage_policy_matrix), tier)])
    error_message = "정책 표에는 CRITICAL/HIGH/MEDIUM/LOW 네 등급이 모두 있어야 합니다."
  }
}

variable "triage_type_prefix_min_tier" {
  description = <<-EOT
    guardduty_always_notify_type_prefixes에 걸리는 타입의 **최소 티어**.

    ⚠️ 이 값이 이 스택에서 가장 중요한 설정이다.
    EventBridge 룰 (A) 갈래는 루트 사용·자격증명 탈취 같은 타입을 severity와
    무관하게 통과시키는데, **이 환경의 finding은 실제로 거의 전부 severity 2
    (LOW)다**(2026-08-12-ai-triage.md §5). 티어를 severity로만 정하면 가장
    중요한 finding이 전부 LOW로 떨어져 판정도 못 받고 저장만 된다.
    이전 구현이 같은 함정을 문서로 남겼다.
  EOT
  type        = string
  default     = "HIGH"

  validation {
    condition     = contains(["MEDIUM", "HIGH", "CRITICAL"], var.triage_type_prefix_min_tier)
    error_message = "triage_type_prefix_min_tier는 MEDIUM/HIGH/CRITICAL 중 하나여야 합니다(LOW는 승격의 의미가 없습니다)."
  }
}

variable "triage_suppress_min_confidence" {
  description = <<-EOT
    FALSE_POSITIVE 판정으로 알림을 없애려면 필요한 최소 확신도(0~1).
    미만이면 UNCERTAIN으로 강등해 "검토"로 보낸다.

    로그 담당자 스펙에는 이 하한이 없었는데, 없으면 모델이 확신 0.3으로
    FALSE_POSITIVE를 뱉어도 그대로 묻힌다. confidence를 스키마에 넣어 놓고
    정책에서 안 쓰면 그 필드는 장식이다.
  EOT
  type        = number
  default     = 0.7

  validation {
    condition     = var.triage_suppress_min_confidence >= 0 && var.triage_suppress_min_confidence <= 1
    error_message = "triage_suppress_min_confidence는 0~1 사이여야 합니다."
  }
}

variable "triage_skip_judge_tiers" {
  description = <<-EOT
    판정 없이 저장만 할 티어. 여기 걸리면 Groq 호출조차 없다.

    LOW를 넣어도 증거는 안 사라진다 — GuardDuty가 90일 보관하고, 현재
    EventBridge 룰의 (B) 갈래가 이미 severity < 4를 거르고 있어 Lambda까지
    오지도 않는다. 여기 도착하는 LOW는 (A) 갈래(중요 타입)로 들어온 것들인데,
    그건 triage_type_prefix_min_tier가 HIGH로 올려 주므로 이 목록에 안 걸린다.
  EOT
  type        = list(string)
  default     = ["LOW"]
}

variable "triage_test_ips" {
  description = <<-EOT
    점검/모의훈련 출발지 IP. 여기서 온 finding은 판정도 통보도 하지 않는다.
    우리가 돌린 스캐너를 위협으로 알리면 알림 신뢰도가 먼저 무너진다.
    ⚠️ 넣는 순간 그 IP의 실제 공격도 안 보인다. 훈련 기간에만 넣고 뺄 것.
  EOT
  type        = list(string)
  default     = []
}

variable "triage_dedup_hours" {
  description = "같은 finding id를 다시 통보하지 않는 기간(시간). GuardDuty는 같은 사건을 count를 올리며 반복 발행한다"
  type        = number
  default     = 6
}

variable "triage_verdict_cache_hours" {
  description = "같은 (타입 × 리소스) 판정을 재사용하는 기간(시간). 판정 호출을 아끼는 주 수단이다"
  type        = number
  default     = 6
}

variable "triage_daily_call_limit" {
  description = "하루 판정 호출 상한. 무료 티어 429를 맞기 전에 우리가 먼저 멈춘다. 넘겨도 통보는 계속되고 판정만 빠진다"
  type        = number
  default     = 300
}

variable "triage_strict_masking" {
  description = <<-EOT
    켜면 IAM 역할/사용자 이름, 버킷 이름까지 가명으로 치환해 Groq에 보낸다.
    계정 ID·사설 IP·이메일은 이 값과 무관하게 항상 가려진다.
    ⚠️ 켜면 판정 정확도가 떨어진다 — "이 주체가 CI 자동화인가 사람인가"가
    판정의 핵심 근거인데 이름을 가리면 그 판단이 불가능해진다.
  EOT
  type        = bool
  default     = false
}


locals {
  triage_name             = "gochuchamchi-guardduty-triage"
  triage_metric_namespace = "Gochuchamchi/Triage"
}


# ============================================================
# Groq API 키 — 그릇만 Terraform이 만들고 값은 사람이 넣는다
#
# variable로 받으면 tfstate에 평문으로 남는다. 2026-08-05 §4에서 PAT로
# 배운 것과 같은 원칙: 시크릿 값은 인프라와 생애주기가 다르다.
#
# apply 후 한 번만:
#   aws secretsmanager put-secret-value `
#     --secret-id gochuchamchi/triage/groq-api-key `
#     --secret-string '{"api_key":"gsk_..."}' `
#     --region ap-northeast-2 --profile workload-admin
#
# 값을 안 넣어도 알림은 정상 동작한다 — 전부 "판정 없음"이 될 뿐이다.
#
# recovery_window_in_days를 0으로 두지 않는 이유: 0이면 destroy 시 즉시
# 삭제돼 값이 증발한다. 크면 같은 이름 재생성이 "삭제 예약됨"으로 막히므로
# 7일로 타협했다.
# ============================================================

resource "aws_secretsmanager_secret" "triage_groq_api_key" {
  name        = "gochuchamchi/triage/groq-api-key"
  description = "GuardDuty AI 트리아지의 Groq API 키. 값은 콘솔/CLI로 직접 주입 — Terraform은 그릇만 관리한다"

  recovery_window_in_days = 7

  tags = {
    Name = "${local.triage_name}-groq-api-key"
  }
}


# ============================================================
# 상태 테이블 — 중복 억제 / 판정 캐시 / 호출 상한
#
# 셋을 한 테이블에서 키 접두사로 구분한다:
#   finding#<id>              이미 통보한 finding인가
#   verdict#<type>#<resource> 이 조합의 판정을 재사용할 수 있나
#   quota#<YYYY-MM-DD>        오늘 몇 번 호출했나
# ============================================================

resource "aws_dynamodb_table" "triage_state" {
  name         = "${local.triage_name}-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "state_key"

  attribute {
    name = "state_key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    # 중복 억제 상태가 유실돼도 알림이 한 번 더 오는 정도라 복구 대상이 아니다
    enabled = false
  }

  tags = {
    Name = "${local.triage_name}-state"
  }
}


# ============================================================
# 실행 역할
# ============================================================

resource "aws_iam_role" "triage" {
  name               = local.triage_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Name = local.triage_name
  }
}

resource "aws_iam_role_policy_attachment" "triage_basic_execution" {
  role       = aws_iam_role.triage.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "triage" {
  statement {
    sid       = "PublishToAlertHub"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  statement {
    sid       = "TrackTriageState"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.triage_state.arn]
  }

  statement {
    sid       = "ReadGroqApiKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.triage_groq_api_key.arn]
  }

  # PutMetricData는 리소스 단위 제한이 불가능하다. 네임스페이스 조건으로 좁힌다.
  statement {
    sid       = "PublishTriageMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.triage_metric_namespace]
    }
  }
}

resource "aws_iam_role_policy" "triage" {
  name   = local.triage_name
  role   = aws_iam_role.triage.id
  policy = data.aws_iam_policy_document.triage.json
}


# ============================================================
# 배포 패키지
#
# 외부 SDK가 없다 — Groq은 HTTP API이고 judge.py는 표준 라이브러리 urllib만
# 쓴다. Bedrock을 쓸 때 필요했던 레이어 빌드(build-layer.ps1)가 사라졌고,
# 그래서 apply에 python/pip/PyPI 접근이 필요 없다.
# ============================================================

#
# source_dir 이 아니라 파일을 하나씩 지정한다. 디렉터리를 통째로 넣으면
# __pycache__ 나 배포 대상이 아닌 검증 스크립트(check-groq.py,
# compare-providers.py)까지 딸려가 zip 해시가 예측 불가능하게 흔들린다.
data "archive_file" "triage" {
  type        = "zip"
  output_path = "${path.module}/guardduty-triage.zip"

  source {
    content  = file("${path.module}/triage/triage_function.py")
    filename = "triage_function.py"
  }

  source {
    content  = file("${path.module}/triage/judge.py")
    filename = "judge.py"
  }

  source {
    content  = file("${path.module}/triage/policy.py")
    filename = "policy.py"
  }

  # 판정 정확도의 대부분이 여기서 나온다. 인프라가 바뀌면 룰이 아니라
  # 이 문서를 고치는 것이 이 설계의 유지보수 전략이다.
  source {
    content  = file("${path.module}/triage/context.md")
    filename = "context.md"
  }
}

resource "aws_lambda_function" "triage" {
  function_name = local.triage_name
  description   = "GuardDuty finding을 AI로 판정하고 (심각도 × 판정) 정책 표에 따라 통보"

  role    = aws_iam_role.triage.arn
  handler = "triage_function.lambda_handler"
  runtime = "python3.12"

  filename         = data.archive_file.triage.output_path
  source_code_hash = data.archive_file.triage.output_base64sha256

  # 판정 1회(최대 20초) + 재시도 여유. 이 값을 줄이면 Lambda가 중간에 잘려
  # 알림도 지표도 안 남는다 — 가장 조용한 형태의 고장이다.
  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      SNS_TOPIC_ARN    = aws_sns_topic.alerts.arn
      STATE_TABLE_NAME = aws_dynamodb_table.triage_state.name

      GROQ_SECRET_ARN = aws_secretsmanager_secret.triage_groq_api_key.arn
      GROQ_SECRET_KEY = "api_key"

      JUDGE_ENABLED  = tostring(var.triage_judge_enabled)
      STRICT_MASKING = tostring(var.triage_strict_masking)

      # judge.py는 TRIAGE_* 를 우선 읽고 옛 GROQ_* 로 물러선다. 이름을 옮긴 것은
      # provider가 groq만이 아니게 된 뒤로 GROQ_ 접두사가 거짓말이 되기 때문이다.
      # 엔드포인트·모델을 빈 값으로 두면 judge.py가 provider 기본값을 채운다.
      TRIAGE_PROVIDER         = var.triage_provider
      TRIAGE_ENDPOINT         = var.triage_groq_endpoint
      TRIAGE_MODEL            = var.triage_groq_model
      TRIAGE_MAX_TOKENS       = tostring(var.triage_groq_max_tokens)
      TRIAGE_REASONING_EFFORT = var.triage_groq_reasoning_effort
      TRIAGE_TIMEOUT_SECONDS  = "20"

      POLICY_MATRIX           = jsonencode(var.triage_policy_matrix)
      ALWAYS_NOTIFY_PREFIXES  = jsonencode(var.guardduty_always_notify_type_prefixes)
      TYPE_PREFIX_MIN_TIER    = var.triage_type_prefix_min_tier
      SUPPRESS_MIN_CONFIDENCE = tostring(var.triage_suppress_min_confidence)
      SKIP_JUDGE_TIERS        = jsonencode(var.triage_skip_judge_tiers)
      TEST_IPS                = jsonencode(var.triage_test_ips)

      DEDUP_HOURS         = tostring(var.triage_dedup_hours)
      VERDICT_CACHE_HOURS = tostring(var.triage_verdict_cache_hours)
      DAILY_CALL_LIMIT    = tostring(var.triage_daily_call_limit)

      METRIC_NAMESPACE = local.triage_metric_namespace
    }
  }

  # Lambda 자체가 죽어도 finding을 잃지 않는다. 기존 알림 DLQ로 보내고
  # DLQ 알람이 이메일로 직접 간다.
  dead_letter_config {
    target_arn = aws_sqs_queue.alerts_dlq.arn
  }

  depends_on = [
    aws_iam_role_policy_attachment.triage_basic_execution,
    aws_iam_role_policy.triage,
  ]

  tags = {
    Name = local.triage_name
  }
}

# Lambda가 DLQ에 쓰려면 별도 권한이 필요하다 (dead_letter_config는 실행 역할로 쓴다)
data "aws_iam_policy_document" "triage_dlq" {
  statement {
    sid       = "SendToAlertsDlq"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.alerts_dlq.arn]
  }
}

resource "aws_iam_role_policy" "triage_dlq" {
  name   = "${local.triage_name}-dlq"
  role   = aws_iam_role.triage.id
  policy = data.aws_iam_policy_document.triage_dlq.json
}

# 로그 그룹을 명시 생성한다 — 암묵 생성되면 보존기간이 "무기한"이라 요금이 계속 는다
resource "aws_cloudwatch_log_group" "triage" {
  name              = "/aws/lambda/${aws_lambda_function.triage.function_name}"
  retention_in_days = 30

  tags = {
    Name = "${local.triage_name}-logs"
  }
}


# ============================================================
# EventBridge 타겟 전환
#
# enable_triage = true  → finding이 트리아지 Lambda로 간다
# enable_triage = false → 기존 SNS 직결로 되돌아간다 (롤백 경로 보존)
#
# guardduty-response.tf의 aws_cloudwatch_event_target.guardduty_sns 에
# count가 붙어 있어 둘 중 하나만 존재한다.
# ============================================================

resource "aws_cloudwatch_event_target" "triage" {
  count = var.enable_triage ? 1 : 0

  rule      = aws_cloudwatch_event_rule.guardduty_finding.name
  target_id = "InvokeTriageLambda"
  arn       = aws_lambda_function.triage.arn
}

resource "aws_lambda_permission" "triage_from_events" {
  count = var.enable_triage ? 1 : 0

  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.triage.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.guardduty_finding.arn
}


# ============================================================
# 자기 감시
#
# 트리아지가 죽으면 GuardDuty 통보 경로 전체가 조용해진다(타겟이 이쪽이므로).
# Lambda 오류를 알람으로 잡아 두지 않으면 "알림이 없는 것"과 "탐지가 멈춘 것"이
# 구분되지 않는다.
#
# 알람 이름이 "gochuchamchi-"로 시작해야 eventbridge.tf의 prefix 룰에 잡혀
# SNS 허브로 발행된다.
# ============================================================

resource "aws_cloudwatch_metric_alarm" "triage_errors" {
  alarm_name        = "${local.triage_name}-errors"
  alarm_description = "GuardDuty 트리아지 Lambda가 실패하고 있습니다. 이 경우 GuardDuty 통보 경로 전체가 조용해집니다 — 로그(/aws/lambda/${local.triage_name})를 즉시 확인하고, 원인 파악이 길어지면 enable_triage=false로 SNS 직결로 되돌리세요."

  namespace   = "AWS/Lambda"
  metric_name = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.triage.function_name
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  tags = {
    Name = "${local.triage_name}-errors"
  }
}


# ============================================================
# Outputs
# ============================================================

output "triage_function_name" {
  description = "GuardDuty 트리아지 Lambda"
  value       = aws_lambda_function.triage.function_name
}

output "triage_groq_secret_name" {
  description = "apply 후 이 시크릿에 Groq API 키를 주입해야 판정이 붙는다(없어도 통보는 동작)"
  value       = aws_secretsmanager_secret.triage_groq_api_key.name
}

output "triage_policy_matrix" {
  description = "현재 적용 중인 (심각도 × 판정) → 액션 표"
  value       = var.triage_policy_matrix
}
