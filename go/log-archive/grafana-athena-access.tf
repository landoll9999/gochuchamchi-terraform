# =============================================================================
# Grafana → Athena 조회용 cross-account 역할 (2026-08-19)
#
# 무엇이 없어서 만드나
#   security_events 뷰(7소스 → 8필드 공통 스키마)는 이미 있는데, 그걸 볼 수 있는
#   곳이 Athena 콘솔뿐이었다. Grafana는 워크로드 계정에 있고 뷰는 이 계정에 있어
#   둘 사이에 경로가 없다. "현업이 요구하는 통합 검색 화면이 없다"의 실체가 이것이고,
#   이 파일이 그 한 칸을 잇는다.
#
# 왜 조회 전용 역할을 따로 파나 — log-admin을 공유하지 않고
#   providers.tf가 "Workload나 Management에서 이 계정의 관리자 역할을 AssumeRole하는
#   신뢰 경로를 만들지 않는다"고 못박고 있다. 그 원칙을 지키면서 조회만 열려면
#   관리자와 무관한 별도 역할이 필요하다. 이 역할은 읽기 액션만 갖고, 쓰기는
#   Athena 결과 버킷의 자기 프리픽스 하나뿐이다(쿼리 실행에 물리적으로 필요).
#
# 신뢰 대상이 계정 루트가 아니라 역할 ARN인 이유
#   워크로드 계정 전체를 신뢰하면 그 계정의 아무 역할이나 중앙 로그를 읽을 수 있다.
#   침해 가정 하에서는 앱 파드 역할도 후보에 들어간다. Grafana 파드에 붙는 그
#   역할 하나만 신뢰한다.
#
# ⚠️ 워크로드 쪽에도 sts:AssumeRole 허용이 필요하다 (양쪽 다 있어야 붙는다)
#   module/grafana/main.tf 의 grafana_cloudwatch 정책에 스테이트먼트 추가.
#   PATCH-grafana-main.md 참조.
# =============================================================================

variable "grafana_workload_role_name" {
  description = <<-EOT
    Grafana 파드에 연결된 워크로드 계정의 IAM 역할 이름. module/grafana/main.tf가
    "<cluster_name>-grafana-cloudwatch" 형태로 만든다(워크로드 스택의 var.cluster_name).
    클러스터 이름을 바꿨다면 여기도 같이 바꿔야 신뢰 정책이 맞는다.
  EOT
  type        = string
  default     = "gochuchamchi-eks-grafana-cloudwatch"
}

variable "grafana_reader_enabled" {
  description = <<-EOT
    Grafana 조회 경로 스위치. false면 역할 자체가 만들어지지 않는다.
    문제가 생겼을 때 콘솔이 아니라 이 값으로 끊을 것 — 콘솔에서 지우면 다음 apply에
    되살아난다(siem-detector.tf의 siem_schedule_enabled와 같은 원칙).
  EOT
  type        = bool
  default     = true
}


locals {
  grafana_reader_role_name = "gochuchamchi-grafana-athena-reader"

  grafana_workload_role_arn = (
    "arn:aws:iam::${var.workload_account_id}:role/${var.grafana_workload_role_name}"
  )

  grafana_reader_tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
    Component = "grafana-reader"
  }
}


# =============================================================================
# 신뢰 정책 — 워크로드 계정의 Grafana 역할만
#
# 특정 역할 ARN을 Principal에 직접 넣으면 IAM이 저장 시 고유 Principal ID로
# 변환한다. daily-down/up이 워크로드 역할을 삭제 후 같은 이름으로 재생성하면 그
# ID가 바뀌어 신뢰 관계가 끊어진다. 계정 root를 Principal로 두되
# aws:PrincipalArn을 정확한 Grafana 역할 ARN으로 제한하면 권한 범위는 유지하면서
# 역할 재생성 후에도 Log 계정 재-apply 없이 신뢰 관계가 이어진다.
# =============================================================================

data "aws_iam_policy_document" "grafana_reader_assume_role" {
  statement {
    sid    = "AllowGrafanaPodRole"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.workload_account_id}:root"]
    }

    # grafana-athena-datasource 플러그인이 AssumeRole에 세션 태그를 붙이므로
    # sts:TagSession도 신뢰해야 한다 (없으면 caller 정책이 맞아도 403 AccessDenied
    # on sts:TagSession — 2026-08-19 실측). 워크로드 grafana 정책도 대칭으로 둘 다 허용.
    actions = ["sts:AssumeRole", "sts:TagSession"]

    # Principal을 계정 root로 열었지만 실제 호출자는 이 역할 ARN 하나로 제한한다.
    # aws:PrincipalArn 조건값은 IAM 고유 Principal ID로 변환되지 않으므로 역할을
    # 삭제 후 같은 이름으로 재생성해도 계속 일치한다.
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [local.grafana_workload_role_arn]
    }

    # 조직 밖에서 이 역할 ARN을 흉내 낼 수 없게 한 겹 더 건다.
    # (역할 ARN 신뢰만으로도 충분하지만, 계정 삭제 후 ID 재사용 같은 경계 사례를 막는다)
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [local.org_id]
    }
  }
}


# ⚠️ 역할 이름이 반드시 gochuchamchi- 로 시작해야 한다.
#    kms-logs.tf의 AllowProjectRoles 조건이
#      aws:PrincipalArn StringLike arn:aws:iam::<acct>:role/gochuchamchi-*
#    이라, 이름을 바꾸면 IAM 정책에 kms:Decrypt가 있어도 키 정책에서 막혀
#    원본 로그를 복호화하지 못한다. siem-detector.tf가 같은 이유로 같은 제약을 진다.
resource "aws_iam_role" "grafana_reader" {
  count = var.grafana_reader_enabled ? 1 : 0

  name = local.grafana_reader_role_name

  # IAM description은 ASCII + Latin-1만 허용한다 (module/grafana/main.tf 주석 참고).
  description = "Read-only role for Grafana to query security_events via Athena"

  assume_role_policy = data.aws_iam_policy_document.grafana_reader_assume_role.json

  # 기본 1시간. Grafana는 만료 전에 재발급하므로 늘릴 이유가 없다.
  max_session_duration = 3600

  tags = merge(
    local.grafana_reader_tags,
    { Name = local.grafana_reader_role_name }
  )
}


# =============================================================================
# 권한 — 읽기 + Athena 결과 프리픽스에만 쓰기
# =============================================================================

data "aws_iam_policy_document" "grafana_reader" {

  # ---------------------------------------------------------------------------
  # Athena 쿼리 실행. Grafana는 수동 조사 전용 Workgroup에만 접근한다.
  # 매시간 탐지용 1 GiB 상한은 그대로 유지하고, VPC Flow를 포함한 통합 검색은
  # 별도의 제한된 상한에서 실행해 서로의 안정성과 비용 경계를 분리한다.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "RunAthenaQueriesInSecurityWorkgroup"
    effect = "Allow"

    actions = [
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
      "athena:GetQueryExecution",
      "athena:BatchGetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetQueryResultsStream",
      "athena:GetWorkGroup",
      "athena:ListNamedQueries",
      "athena:GetNamedQuery",
      "athena:BatchGetNamedQuery"
    ]

    resources = [aws_athena_workgroup.security_investigation.arn]
  }

  # 데이터소스/카탈로그 목록 조회 — Grafana 데이터소스 설정 화면에서 쓴다.
  statement {
    sid    = "ListAthenaCatalogs"
    effect = "Allow"

    actions = [
      "athena:ListDataCatalogs",
      "athena:GetDataCatalog",
      "athena:ListDatabases",
      "athena:GetDatabase",
      "athena:ListTableMetadata",
      "athena:GetTableMetadata",
      "athena:ListWorkGroups"
    ]

    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # Glue 카탈로그 — 읽기만. 뷰 생성/변경은 siem-detector Lambda의 일이고
  # Grafana가 스키마를 건드릴 이유가 없다.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "ReadGlueCatalog"
    effect = "Allow"

    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions"
    ]

    resources = [
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:catalog",
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:database/${aws_glue_catalog_database.security_logs.name}",
      "arn:aws:glue:${var.region}:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.security_logs.name}/*"
    ]
  }

  # ---------------------------------------------------------------------------
  # 원본 로그 버킷 — 읽기만. 삭제·쓰기는 주지 않는다.
  #
  # ⚠️ 버킷이 두 개다. security_events 뷰의 7개 소스 중 alb 분기만 별도 버킷을
  #    본다(alb-access-logs.tf). 여기를 빼면 다른 소스는 되는데 alb 행만
  #    AccessDenied로 사라지고, UNION ALL 이라 쿼리 자체가 실패한다.
  #    "왜 통합 검색에 ALB만 안 나오지"의 원인이 여기다.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "ReadCentralLogArchive"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation"
    ]

    resources = [
      aws_s3_bucket.cloudwatch_log_archive.arn,
      "${aws_s3_bucket.cloudwatch_log_archive.arn}/*",
      aws_s3_bucket.alb_access_logs.arn,
      "${aws_s3_bucket.alb_access_logs.arn}/*"
    ]
  }

  # ---------------------------------------------------------------------------
  # Athena 결과 버킷 — 쓰기가 필요한 유일한 지점.
  # Athena는 결과를 S3에 떨군 뒤 그것을 읽어 돌려주는 구조라 PutObject 없이는
  # 쿼리 자체가 실패한다.
  #
  # 버킷 ARN과 객체 ARN을 함께 준다. GetBucketLocation·ListBucket은 버킷 레벨
  # 액션이라 객체 ARN(.../results/*)만으로는 인가되지 않는다 —
  # 프리픽스로 좁히려다 이 둘이 빠지면 Athena가 첫 호출에서 바로 막힌다.
  # siem-detector.tf의 WriteQueryResults와 같은 형태로 맞춘다.
  # ---------------------------------------------------------------------------
  statement {
    sid    = "WriteAthenaQueryResults"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts",
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation"
    ]

    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*"
    ]
  }

  # ---------------------------------------------------------------------------
  # 중앙 아카이브 CMK — 복호화만. Athena 결과 버킷은 SSE-S3라 키가 필요 없다
  # (athena.tf의 encryption_option = "SSE_S3").
  # ---------------------------------------------------------------------------
  statement {
    sid    = "DecryptCentralLogs"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]

    resources = [aws_kms_key.logs.arn]
  }
}


resource "aws_iam_role_policy" "grafana_reader" {
  count = var.grafana_reader_enabled ? 1 : 0

  name   = "${local.grafana_reader_role_name}-read"
  role   = aws_iam_role.grafana_reader[0].id
  policy = data.aws_iam_policy_document.grafana_reader.json
}


# =============================================================================
# Outputs — 워크로드 쪽 설정에 그대로 넣는 값들
# =============================================================================

output "grafana_reader_role_arn" {
  description = "Grafana 데이터소스의 assumeRoleArn에 넣을 값"
  value       = try(aws_iam_role.grafana_reader[0].arn, null)
}

output "grafana_athena_datasource_settings" {
  description = "Grafana Athena 데이터소스 설정에 필요한 값 묶음"

  value = {
    catalog        = "AwsDataCatalog"
    database       = aws_glue_catalog_database.security_logs.name
    workgroup      = aws_athena_workgroup.security_investigation.name
    region         = var.region
    assumeRoleArn  = try(aws_iam_role.grafana_reader[0].arn, null)
    outputLocation = "s3://${aws_s3_bucket.athena_results.id}/results/"
  }
}
