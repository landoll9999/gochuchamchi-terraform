# =============================================================================
# CloudWatch Logs -> 로그 계정 Destination 구독 필터  (2026-08-10 org 분리)
#
# 8/7에 Firehose를 account-baseline으로 뺐고, 이번에는 그 수신부 전체가
# ../log-archive(별도 로그 계정)로 갔다. 여기 남는 것은 여전히
# "EKS 로그 그룹을 수신부에 붙이는 배선"뿐이다 — 클러스터와 생명주기가 같다.
#
# 크로스 계정이라 두 가지가 8/7 버전과 다르다:
#   1. Firehose ARN이 아니라 Log Destination ARN을 가리킨다 — 구독 필터는
#      다른 계정의 Firehose를 직접 못 가리킨다.
#   2. role_arn이 없다 — 인가는 수신측(log-archive)의 destination policy가 맡고,
#      Firehose 투입 권한도 수신측 destination의 role이 갖는다.
#
# 참조는 data source가 아니라 ARN 조립이다 — 크로스 계정 data source는 로그
# 계정의 자격증명이 필요해서 kim/moon의 DenySensitiveServices 환경에서 걸린다.
# destination 이름 규칙은 ../log-archive/log-archive.tf 와 반드시 일치해야 한다.
# =============================================================================

locals {
  # 키는 ../log-archive/log-archive.tf 의 cloudwatch_log_archive_sources 와
  # 반드시 일치해야 한다. 여기서 값(로그 그룹 이름)을 붙인다.
  cloudwatch_log_archive_sources = {
    application   = aws_cloudwatch_log_group.container_insights_application.name
    control-plane = module.eks.cloudwatch_log_group_name
  }
}

resource "aws_cloudwatch_log_subscription_filter" "cloudwatch_log_archive" {
  for_each = local.cloudwatch_log_archive_sources

  name            = "gochuchamchi-${each.key}-s3-archive"
  log_group_name  = each.value
  filter_pattern  = ""
  destination_arn = "arn:aws:logs:${var.region}:${var.log_archive_account_id}:destination:gochuchamchi-${each.key}-log-archive"

  depends_on = [aws_eks_addon.cloudwatch_observability]

  lifecycle {
    precondition {
      condition     = var.log_archive_account_id != ""
      error_message = "log_archive_account_id가 비어 있습니다. 로그 계정 생성 후 계정 ID를 변수에 넣어야 합니다 (../log-archive 먼저 apply)."
    }
  }
}

# CloudFront 범위 WAF 로그는 us-east-1에 있으므로 서울 EKS 로그 구독과 provider를
# 분리한다. 수신 Destination은 Log 계정에서 먼저 apply되어 있어야 한다.
resource "aws_cloudwatch_log_subscription_filter" "waf_log_archive" {
  provider = aws.us_east_1

  name            = "gochuchamchi-waf-s3-archive"
  log_group_name  = aws_cloudwatch_log_group.waf.name
  filter_pattern  = ""
  destination_arn = "arn:aws:logs:us-east-1:${var.log_archive_account_id}:destination:gochuchamchi-waf-log-archive"

  depends_on = [aws_wafv2_web_acl_logging_configuration.edge]

  lifecycle {
    precondition {
      condition     = var.log_archive_account_id != ""
      error_message = "log_archive_account_id가 비어 있습니다. log-archive의 WAF Destination을 먼저 apply해야 합니다."
    }
  }
}
