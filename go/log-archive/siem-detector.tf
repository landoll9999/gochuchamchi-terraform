# =============================================================================
# SIEM 탐지 엔진 — 룰을 주기 실행하고, 후보에 판정을 붙여 알린다 (2026-08-12)
#
#   EventBridge(rate) → siem-detector Lambda → Athena(룰) → Groq(판정) → SNS
#
# 비용이 성립하는 이유 (개인 프로젝트 규모 전제)
#   Athena  탐지용 뷰는 2일치·4개 소스로 좁혀 놨다(security-events-view.tf).
#           1시간마다 룰 4개면 하루 스캔이 수 GB 수준 → 월 $1 미만.
#           워크그룹의 쿼리당 1 GiB 상한이 위쪽 뚜껑 역할을 한다.
#   Groq    후보가 있을 때만, 룰당 1회 호출한다. 후보가 없으면 0회다.
#           최악의 경우도 시간당 4회 = 하루 96회이고, 일일 상한
#           (siem_judge_daily_call_limit)이 그 위에 한 겹 더 걸린다.
#           **원시 로그는 모델로 가지 않는다** — 룰이 집계한 표만 간다.
#   Lambda  1시간 간격 실행이라 프리티어 안에서 끝난다.
#
# 이 스택이 죽었을 때 알아채는 법
#   실행마다 DetectionRunSuccess=1 지표를 찍는다. 두 주기 연속 안 찍히면
#   아래 알람이 SNS로 통보한다. SIEM에서 가장 위험한 고장은 "알림이 없는 것"과
#   "탐지가 멈춘 것"이 구분되지 않는 상태다.
# =============================================================================

variable "siem_schedule_expression" {
  description = <<-EOT
    탐지 주기. rate(1 hour) 기준으로 나머지 기본값(lookback 75분, 탐지 뷰 2일)이
    맞춰져 있다. 줄이면 탐지가 빨라지는 대신 Athena 스캔량이 비례해 는다 —
    파티션 단위가 하루라 실행 1회당 스캔량은 주기를 줄여도 안 줄기 때문이다.
    (rate(15 minutes)로 바꾸면 스캔 비용이 4배가 된다)
  EOT
  type        = string
  default     = "rate(1 hour)"
}

variable "siem_schedule_enabled" {
  description = "탐지 스케줄 on/off. 즉시 멈춰야 할 때 쓰는 스위치 — 리소스는 남고 실행만 안 된다"
  type        = bool
  default     = true
}

variable "siem_alert_dedup_hours" {
  description = <<-EOT
    같은 alert_key를 다시 알리지 않는 기간(시간). 룰이 매 주기 같은 대상을
    반복해서 잡기 때문에 이게 없으면 한 사건으로 알림이 수십 번 온다.
    짧게 하면 알림이 반복되고, 길게 하면 상황이 악화돼도 조용하다.
  EOT
  type        = number
  default     = 6

  validation {
    condition     = var.siem_alert_dedup_hours >= 1 && var.siem_alert_dedup_hours <= 72
    error_message = "siem_alert_dedup_hours는 1~72 사이여야 합니다."
  }
}

variable "siem_max_rows_in_alert" {
  description = "알림 본문과 판정 프롬프트에 싣는 최대 행 수. 늘리면 판정 입력 토큰이 비례해 는다"
  type        = number
  default     = 10
}

# --- 판정 계층 --------------------------------------------------------------

variable "siem_judge_enabled" {
  description = <<-EOT
    Groq 판정 계층 on/off. false면 룰이 잡은 후보가 전부 그대로 알림이 된다
    (탐지는 그대로 동작하고 소음만 늘어난다). Groq 계정 문제로 급히 떼어낼 때 쓴다.
  EOT
  type        = bool
  default     = true
}

variable "siem_groq_model" {
  description = <<-EOT
    판정에 쓸 Groq 모델 ID.

    기본값이 gpt-oss-120b인 이유 (2026-08-12 기준 생산 모델 4종 비교):

      openai/gpt-oss-120b        $0.15/$0.60  500 tps   ← 이걸 쓴다
      openai/gpt-oss-20b         $0.075/$0.30 1000 tps  차선
      llama-3.3-70b-versatile    $0.59/$0.79  280 tps   가장 비싸고 느리다
      llama-3.1-8b-instant       $0.05/$0.08  560 tps   판정에 쓰기엔 작다

    120b가 llama-3.3-70b보다 **싸고 빠르고 크다** — 모든 축에서 우위라 고민할
    여지가 없다. 게다가 Llama 3.3의 공식 지원 언어에 한국어가 없는데 이 판정은
    한국어로 답해야 한다. 20b와는 월 $1 미만 차이라 비용으로 내릴 이유가 약하다.

    ⚠️ "그록 컴파운드"처럼 웹 검색·코드 실행 도구가 붙은 시스템은 쓰지 말 것.
    판정 입력에는 공격자가 값을 정할 수 있는 문자열(버킷 이름, User-Agent,
    역할 이름)이 들어가므로, 도구가 붙으면 프롬프트 인젝션이 오판을 넘어
    실제 외부 요청으로 증폭된다. 도구 없는 순수 추론 모델을 쓴다.

    ⚠️ 모델 목록과 이름은 수시로 바뀐다(폐기되는 모델도 있다). apply 전에
    siem/check-groq.py로 확인할 것 — 없는 모델이면 판정이 전부 "판정 없음"으로
    떨어지는데 알림은 계속 나오므로 알아채기 어렵다.
    JSON 구조화 출력(response_format)을 지원하는 모델이어야 한다.
  EOT
  type        = string
  default     = "openai/gpt-oss-120b"
}

variable "siem_groq_endpoint" {
  description = "Groq chat completions 엔드포인트 (OpenAI 호환). 다른 호환 게이트웨이로 갈아끼울 때 사용"
  type        = string
  default     = "https://api.groq.com/openai/v1/chat/completions"
}

variable "siem_groq_timeout_seconds" {
  description = "판정 호출 1건의 타임아웃(초). 넘기면 그 룰은 '판정 없음'으로 통보된다"
  type        = number
  default     = 20
}

variable "siem_groq_max_tokens" {
  description = <<-EOT
    판정 응답의 최대 출력 토큰.

    ⚠️ gpt-oss·qwen3 계열은 **추론 모델**이라 최종 JSON 앞에 사고 과정 토큰을
    먼저 생성한다. 이 값이 빠듯하면 JSON을 시작하기도 전에 예산이 소진돼
    400 `json_validate_failed`로 떨어진다(실제로 700으로 잡았다가 만난 문제).

    상한이지 지출이 아니다 — 실제 생성된 토큰만 과금되므로 넉넉히 둔다.
  EOT
  type        = number
  default     = 4000
}

variable "siem_groq_reasoning_effort" {
  description = <<-EOT
    추론 모델의 사고 깊이(low/medium/high). 사고 과정 토큰도 **출력 단가로
    과금**되므로 이 값이 곧 판정 비용이다.

    이 판정은 표 몇 줄을 보고 정상 자동화인지 가르는 일이라 깊은 추론이
    필요 없다 — low로 충분하고 응답 시간도 같이 준다.

    빈 문자열("")로 두면 파라미터를 아예 보내지 않는다. 이 파라미터를 모르는
    모델이 400을 낼 때의 탈출구다.
  EOT
  type        = string
  default     = "low"

  validation {
    condition     = contains(["", "low", "medium", "high"], var.siem_groq_reasoning_effort)
    error_message = "siem_groq_reasoning_effort는 \"\", low, medium, high 중 하나여야 합니다."
  }
}

variable "siem_judge_daily_call_limit" {
  description = <<-EOT
    하루 판정 호출 상한. 무료 티어 한도를 넘겨 429를 맞기 전에 우리가 먼저
    멈추기 위한 것이다. 상한에 걸려도 **탐지는 계속되고 알림도 계속 나간다** —
    판정(설명)만 빠진다.
  EOT
  type        = number
  default     = 300
}

variable "siem_response_enabled" {
  description = <<-EOT
    urgent 판정을 workload 계정 자동대응(WAF 24h 차단)으로 넘길지. 기본 false.
    이 파이프라인은 원래 '알리는 것'까지만 하므로(detector docstring) 이 경계를
    넘는 스위치는 명시적으로 켜야 한다. 켜도 조건이 좁다 — severity CRITICAL/HIGH
    + verdict=malicious + confidence>=siem_response_min_confidence + 공인 source_ip.
    실제 차단은 workload 격리 Lambda 의 waf_response_enabled 가 다시 게이트한다(이중).
  EOT
  type        = bool
  default     = false
}

variable "siem_response_min_confidence" {
  description = "자동대응을 넘기기 위한 malicious 판정의 최소 확신도(0~1). 낮추면 오탐 대응이 는다."
  type        = number
  default     = 0.8

  validation {
    condition     = var.siem_response_min_confidence >= 0.5 && var.siem_response_min_confidence <= 1.0
    error_message = "siem_response_min_confidence는 0.5~1.0 사이여야 합니다."
  }
}

variable "siem_judge_benign_min_confidence" {
  description = <<-EOT
    benign 판정으로 알림을 생략하려면 필요한 최소 확신도(0~1).
    0에 가까울수록 조용해지고 모델 오판이 곧 미탐이 된다. 1로 두면 사실상
    판정이 알림을 없애지 못하고 설명만 붙는다(가장 보수적).
  EOT
  type        = number
  default     = 0.7

  validation {
    condition     = var.siem_judge_benign_min_confidence >= 0 && var.siem_judge_benign_min_confidence <= 1
    error_message = "siem_judge_benign_min_confidence는 0~1 사이여야 합니다."
  }
}

variable "siem_judge_strict_masking" {
  description = <<-EOT
    켜면 IAM 역할 이름·버킷 이름 같은 리소스 이름까지 가명으로 치환해서
    Groq에 보낸다. 계정 ID·내부 IP·이메일은 이 값과 무관하게 항상 가려진다.

    ⚠️ 켜면 판정 정확도가 떨어진다. "이 역할이 CI 자동화인가 사람인가"가
    판정의 핵심 근거인데 이름을 가리면 그 판단이 불가능해지기 때문이다.
    리소스 이름 규칙에 비밀이 들어가는 환경에서만 켤 것.
  EOT
  type        = bool
  default     = false
}


# =============================================================================
# Groq API 키 — 그릇만 Terraform이 만들고 값은 사람이 넣는다
#
# variable로 받으면 tfstate에 평문으로 남는다. Discord 웹훅(siem-alerts.tf)과
# 같은 방식이고, 같은 원칙이다: 시크릿 값은 인프라와 생애주기가 다르다.
#
# apply 후 한 번만:
#   aws secretsmanager put-secret-value `
#     --secret-id gochuchamchi/siem/groq-api-key `
#     --secret-string '{"api_key":"gsk_..."}' `
#     --region ap-northeast-2 --profile log-admin
#
# 값을 안 넣어도 탐지는 정상 동작한다 — 모든 알림에 "판정 없음"이 붙을 뿐이다.
# =============================================================================

resource "aws_secretsmanager_secret" "siem_groq_api_key" {
  name        = "gochuchamchi/siem/groq-api-key"
  description = "SIEM 판정 계층의 Groq API 키. 값은 콘솔/CLI로 직접 주입 — Terraform은 그릇만 관리한다"

  recovery_window_in_days = 7

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-groq-api-key" })
}


# =============================================================================
# 중복 억제 / 호출 상한 테이블
#
# 두 가지 용도를 한 테이블에서 쓴다 (키 접두사로 구분):
#   <rule_id>#<alert_key>   이미 알린 대상인가
#   judge-quota#<YYYY-MM-DD>  오늘 판정을 몇 번 호출했나
#
# TTL 삭제는 최대 48시간까지 지연될 수 있어 "항목이 남아 있다"만으로는 억제
# 여부를 판단할 수 없다. Lambda가 alerted_at 비교를 조건식에 같이 걸어 처리한다.
# =============================================================================

resource "aws_dynamodb_table" "siem_alert_state" {
  name         = "${local.siem_name_prefix}-alert-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "alert_key"

  attribute {
    name = "alert_key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  point_in_time_recovery {
    # 알림 중복 억제 상태는 유실돼도 알림이 한 번 더 오는 정도라 복구 대상이 아니다
    enabled = false
  }

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-alert-state" })
}


# =============================================================================
# 실행 역할
#
# 역할 이름이 gochuchamchi- 로 시작해야 KMS 키 정책의 AllowProjectRoles
# (kms-logs.tf)에 걸려 로그 객체를 복호화할 수 있다. 이름을 바꾸면 Athena가
# 원본을 못 읽어 모든 룰이 실패한다.
# =============================================================================

resource "aws_iam_role" "siem_detector" {
  name               = "${local.siem_name_prefix}-detector-lambda"
  assume_role_policy = data.aws_iam_policy_document.siem_lambda_assume_role.json

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-detector-lambda" })
}

resource "aws_iam_role_policy_attachment" "siem_detector_basic_execution" {
  role       = aws_iam_role.siem_detector.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "siem_detector" {
  # --- Athena: 룰/뷰 SQL 읽기 + 실행 ---------------------------------------
  statement {
    sid    = "RunDetectionQueries"
    effect = "Allow"

    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:BatchGetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetWorkGroup",
      # 룰 SQL은 저장 쿼리에서 읽는다 — Lambda 재배포 없이 룰을 고치기 위한 구조
      "athena:BatchGetNamedQuery",
      "athena:GetNamedQuery",
      "athena:ListNamedQueries",
    ]

    resources = [aws_athena_workgroup.security_logs.arn]
  }

  # --- Glue: 테이블 메타데이터 + 뷰 생성 ------------------------------------
  # CREATE OR REPLACE VIEW는 Glue에 VIRTUAL_VIEW 테이블을 쓰는 동작이라
  # Create/Update/Delete Table 권한이 필요하다. 데이터베이스 범위로 제한한다.
  statement {
    sid    = "ReadCatalogAndManageViews"
    effect = "Allow"

    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:DeleteTable",
    ]

    resources = [
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.security_logs.name}",
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.security_logs.name}/*",
    ]
  }

  # --- S3: 원본 로그 읽기 (쓰기 권한은 주지 않는다) -------------------------
  statement {
    sid    = "ReadCentralLogs"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn,
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/*",
    ]
  }

  # --- S3: Athena 쿼리 결과 (여기는 쓰기가 필요하다) ------------------------
  statement {
    sid    = "WriteQueryResults"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:AbortMultipartUpload",
    ]

    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*",
    ]
  }

  # --- KMS: 로그 버킷 객체 복호화 -------------------------------------------
  statement {
    sid       = "DecryptCentralLogs"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.logs.arn]
  }

  # --- DynamoDB: 중복 억제 + 호출 상한 --------------------------------------
  statement {
    sid       = "TrackAlertState"
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:GetItem"]
    resources = [aws_dynamodb_table.siem_alert_state.arn]
  }

  # --- SNS: 알림 발행 --------------------------------------------------------
  statement {
    sid       = "PublishAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.siem_alerts.arn]
  }

  # --- Secrets Manager: Groq API 키 -----------------------------------------
  statement {
    sid       = "ReadGroqApiKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.siem_groq_api_key.arn]
  }

  # --- CloudWatch: 지표 -----------------------------------------------------
  # PutMetricData는 리소스 단위 제한이 불가능하다. 네임스페이스 조건으로 좁힌다.
  statement {
    sid       = "PublishDetectionMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.siem_metric_namespace]
    }
  }

  # (2026-08-13) urgent 판정을 workload 계정 자동대응으로 넘긴다(크로스계정 PutEvents).
  # 대상은 workload 의 default 이벤트 버스 하나로 좁힌다.
  statement {
    sid       = "DispatchResponseToWorkload"
    effect    = "Allow"
    actions   = ["events:PutEvents"]
    resources = ["arn:aws:events:${var.region}:${var.workload_account_id}:event-bus/default"]
  }
}

resource "aws_iam_role_policy" "siem_detector" {
  name   = "${local.siem_name_prefix}-detector"
  role   = aws_iam_role.siem_detector.id
  policy = data.aws_iam_policy_document.siem_detector.json
}


# =============================================================================
# 배포 패키지
#
# rules.json을 zip 안에 넣는다 — 환경변수로 넘기지 않는 이유:
# Lambda 환경변수는 전체 합계 4 KB 제한인데 룰의 why 문구가 한글이라 3바이트/자다.
# 룰이 몇 개만 늘어도 조용히 상한을 넘어 배포가 깨진다. 패키지 안에 두면 그
# 제약이 없고, 룰이 바뀌면 zip 해시가 바뀌어 Lambda가 자동으로 갱신된다.
#
# named query ID는 apply 시점에야 정해지므로 이 data 소스는 plan에서
# "known after apply"로 남는다 — 정상이다.
# =============================================================================

locals {
  siem_metric_namespace = "Gochuchamchi/SIEM"

  siem_rules_manifest = {
    # 매 실행 앞에서 재생성할 뷰 (조사용·탐지용 둘 다)
    views = [for name, query in aws_athena_named_query.create_security_events_view : query.id]

    rules = [
      for key, rule in local.siem_rules : {
        id           = key
        name         = aws_athena_named_query.siem_rule[key].name
        severity     = rule.severity
        title        = rule.title
        why          = rule.why
        always_alert = rule.always_alert
        query_id     = aws_athena_named_query.siem_rule[key].id
      }
    ]
  }
}

data "archive_file" "siem_detector" {
  type        = "zip"
  output_path = "${path.module}/siem-detector.zip"

  source {
    content  = file("${path.module}/siem/detector_function.py")
    filename = "detector_function.py"
  }

  source {
    content  = file("${path.module}/siem/judge.py")
    filename = "judge.py"
  }

  # 판정 정확도의 대부분이 여기서 나온다. 인프라가 바뀌면 룰이 아니라
  # 이 문서를 고치는 것이 이 설계의 유지보수 전략이다.
  source {
    content  = file("${path.module}/siem/context.md")
    filename = "context.md"
  }

  source {
    content  = jsonencode(local.siem_rules_manifest)
    filename = "rules.json"
  }
}


# =============================================================================
# 탐지 Lambda
# =============================================================================

resource "aws_lambda_function" "siem_detector" {
  function_name = "${local.siem_name_prefix}-detector"
  description   = "Athena 상관 룰을 주기 실행하고 후보에 Groq 판정을 붙여 SNS로 발행"

  role    = aws_iam_role.siem_detector.arn
  handler = "detector_function.lambda_handler"
  runtime = "python3.12"

  filename         = data.archive_file.siem_detector.output_path
  source_code_hash = data.archive_file.siem_detector.output_base64sha256

  # 쿼리 대기(최대 240초) + 판정 호출(룰당 최대 20초)을 합친 것보다 넉넉하게.
  # 이 값을 줄이면 Lambda가 중간에 잘려 지표도 알림도 남지 않는다 —
  # 가장 조용한 형태의 고장이므로 여유를 둔다.
  timeout     = 480
  memory_size = 256

  # 두 주기가 겹쳐 도는 것을 막는다. 겹치면 같은 후보를 두 번 판정해
  # 호출 상한만 태운다.
  reserved_concurrent_executions = 1

  environment {
    variables = {
      ATHENA_WORKGROUP = aws_athena_workgroup.security_logs.name
      ATHENA_DATABASE  = aws_glue_catalog_database.security_logs.name
      ALERT_TOPIC_ARN  = aws_sns_topic.siem_alerts.arn
      DEDUP_TABLE_NAME = aws_dynamodb_table.siem_alert_state.name

      DEDUP_HOURS           = tostring(var.siem_alert_dedup_hours)
      LOOKBACK_MINUTES      = tostring(var.siem_rule_lookback_minutes)
      MAX_ROWS_IN_ALERT     = tostring(var.siem_max_rows_in_alert)
      QUERY_TIMEOUT_SECONDS = "240"
      METRIC_NAMESPACE      = local.siem_metric_namespace

      JUDGE_ENABLED               = tostring(var.siem_judge_enabled)
      JUDGE_DAILY_CALL_LIMIT      = tostring(var.siem_judge_daily_call_limit)
      JUDGE_BENIGN_MIN_CONFIDENCE = tostring(var.siem_judge_benign_min_confidence)
      JUDGE_STRICT_MASKING        = tostring(var.siem_judge_strict_masking)

      # (2026-08-13) 자동대응 연결 (크로스계정). RESPONSE_ENABLED=false 면 dispatch 는
      # 조용히 통과한다. 버스 ARN 은 항상 넣되 스위치가 게이트한다.
      RESPONSE_ENABLED        = tostring(var.siem_response_enabled)
      RESPONSE_EVENT_BUS_ARN  = "arn:aws:events:${var.region}:${var.workload_account_id}:event-bus/default"
      RESPONSE_MIN_CONFIDENCE = tostring(var.siem_response_min_confidence)
      GROQ_SECRET_ARN         = aws_secretsmanager_secret.siem_groq_api_key.arn
      GROQ_SECRET_KEY         = "api_key"
      GROQ_ENDPOINT           = var.siem_groq_endpoint
      GROQ_MODEL              = var.siem_groq_model
      GROQ_TIMEOUT_SECONDS    = tostring(var.siem_groq_timeout_seconds)
      GROQ_MAX_ROWS           = tostring(var.siem_max_rows_in_alert)
      GROQ_MAX_TOKENS         = tostring(var.siem_groq_max_tokens)
      GROQ_REASONING_EFFORT   = var.siem_groq_reasoning_effort
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.siem_detector_basic_execution,
    aws_iam_role_policy.siem_detector,
  ]

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-detector" })
}

# 로그 그룹을 명시 생성한다 — 암묵 생성되면 보존기간이 "무기한"이라
# 요금이 계속 는다.
resource "aws_cloudwatch_log_group" "siem_detector" {
  name              = "/aws/lambda/${aws_lambda_function.siem_detector.function_name}"
  retention_in_days = 30

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-detector-logs" })
}


# =============================================================================
# 스케줄
# =============================================================================

resource "aws_cloudwatch_event_rule" "siem_detector_schedule" {
  name        = "${local.siem_name_prefix}-detector-schedule"
  description = "SIEM 상관 탐지 주기 실행"

  schedule_expression = var.siem_schedule_expression
  state               = var.siem_schedule_enabled ? "ENABLED" : "DISABLED"

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-detector-schedule" })
}

resource "aws_cloudwatch_event_target" "siem_detector" {
  rule      = aws_cloudwatch_event_rule.siem_detector_schedule.name
  target_id = "siem-detector"
  arn       = aws_lambda_function.siem_detector.arn
}

resource "aws_lambda_permission" "siem_detector_from_events" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.siem_detector.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.siem_detector_schedule.arn
}


# =============================================================================
# 자기 감시 — "탐지가 멈춘 것"과 "알릴 게 없는 것"을 구분한다
#
# 실행이 성공할 때마다 DetectionRunSuccess=1을 찍는다. 두 주기 연속으로 이
# 지표가 없으면(= Lambda가 아예 안 돌았거나 중간에 죽었으면) 알람이 뜬다.
# treat_missing_data = "breaching"이 이 알람의 핵심이다 — 지표가 없는 것이
# 바로 우리가 찾는 고장이기 때문이다.
#
# 룰 쿼리 실패는 Lambda가 직접 운영 알림을 발행하므로 별도 알람을 두지 않는다.
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "siem_detector_not_running" {
  alarm_name        = "${local.siem_name_prefix}-detector-not-running"
  alarm_description = "SIEM 탐지가 두 주기 연속 실행되지 않았습니다. 이 시간대는 관제 공백입니다. Lambda 로그(/aws/lambda/${local.siem_name_prefix}-detector)와 EventBridge 룰 활성화 상태를 확인하세요."

  namespace   = local.siem_metric_namespace
  metric_name = "DetectionRunSuccess"

  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # 지표가 없는 것이 곧 고장이다
  treat_missing_data = "breaching"

  alarm_actions = [aws_sns_topic.siem_alerts.arn]
  ok_actions    = [aws_sns_topic.siem_alerts.arn]

  tags = merge(local.siem_tags, { Name = "${local.siem_name_prefix}-detector-not-running" })
}


# =============================================================================
# Outputs
# =============================================================================

output "siem_detector_function_name" {
  description = "SIEM 탐지 Lambda. 수동 실행: aws lambda invoke --function-name <이 값> out.json"
  value       = aws_lambda_function.siem_detector.function_name
}

output "siem_groq_api_key_secret_name" {
  description = "apply 후 이 시크릿에 Groq API 키를 직접 주입해야 판정이 붙는다(없어도 탐지·알림은 동작)"
  value       = aws_secretsmanager_secret.siem_groq_api_key.name
}

output "siem_metric_namespace" {
  description = "탐지 지표 네임스페이스 (RuleHits / JudgeVerdict / ScannedBytes / EstimatedCostUsd / DetectionRunSuccess)"
  value       = local.siem_metric_namespace
}
