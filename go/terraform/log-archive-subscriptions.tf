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
    # (2026-08-12) RDS 감사 로그 중앙화 — "누가 들어와 무엇을 실행했나"의 증적을
    # 불변 중앙 버킷(Log 계정)에 보관한다. rds.tf 에서 QUERY_DML_NO_SELECT 까지 켠 뒤,
    # 이 감사 축을 workload 계정에만 두지 않고 다른 계정이 변조·삭제할 수 없는 곳으로
    # 보낸다(제로트러스트 감사의 핵심 — 침해된 계정이 자기 흔적을 못 지우게).
    # 로그 그룹은 AWS 가 만드는 것이라 리소스 참조가 아니라 이름을 조립한다.
    # 수신 Destination(gochuchamchi-rds-audit-log-archive)은 Log 계정에서 먼저
    # apply 되어 있어야 한다 — ../log-archive/log-archive.tf 의 archive_sources 에
    # "rds-audit" 를 추가하는 짝 커밋이 선행되어야 이 구독 필터 생성이 성공한다.
    rds-audit = "/aws/rds/instance/${data.aws_db_instance.this.db_instance_identifier}/audit"
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
