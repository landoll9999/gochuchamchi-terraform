# =============================================================================
# CloudWatch Logs -> Firehose 구독 필터  (2026-08-07 분리)
#
# 중앙 로그 아카이브(S3 버킷 / Firehose / IAM / 수명주기 600여 줄)는
# ../account-baseline 으로 옮겼다. 그 계층은 destroy하지 않는다 —
# 로그 버킷이 Object Lock COMPLIANCE라 애초에 지울 수 없기도 하고,
# 로그는 인프라가 죽어 있을 때야말로 남아 있어야 하기 때문이다.
#
# 여기 남긴 것은 "EKS 로그 그룹을 그 Firehose에 붙이는 배선"뿐이다.
# 클러스터와 생명주기가 같아서(클러스터가 사라지면 로그 그룹도 사라진다)
# 메인 스택에 있는 게 맞다.
#
# 참조는 remote state가 아니라 이름 고정 data source로 한다 —
# persistent-data.tf 와 같은 이유다.
# =============================================================================

data "aws_iam_role" "cloudwatch_logs_to_firehose" {
  name = "gochuchamchi-cloudwatch-logs-to-firehose"
}

data "aws_kinesis_firehose_delivery_stream" "cloudwatch_log_archive" {
  for_each = local.cloudwatch_log_archive_sources

  name = "gochuchamchi-${each.key}-log-archive"
}

locals {
  # 키는 ../account-baseline/log-archive.tf 의 cloudwatch_log_archive_sources 와
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
  destination_arn = data.aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive[each.key].arn
  role_arn        = data.aws_iam_role.cloudwatch_logs_to_firehose.arn

  depends_on = [aws_eks_addon.cloudwatch_observability]
}
