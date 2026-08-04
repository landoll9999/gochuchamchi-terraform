# =============================================================================
# CloudTrail -> 중앙 로그 S3
#
# 모든 활성 리전의 관리 이벤트를 기록합니다.
# 데이터 이벤트(S3 객체, Lambda 호출 등)는 비용과 로그량을 고려해 제외합니다.
# =============================================================================

data "aws_partition" "current" {}

locals {
  cloudtrail_name          = "gochuchamchi-management-trail"
  cloudtrail_s3_key_prefix = "cloudtrail"
  cloudtrail_arn           = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.region}:${data.aws_caller_identity.current.account_id}:trail/${local.cloudtrail_name}"
}

resource "aws_cloudtrail" "central" {
  name           = local.cloudtrail_name
  s3_bucket_name = aws_s3_bucket.cloudwatch_log_archive.id
  s3_key_prefix  = local.cloudtrail_s3_key_prefix

  enable_logging                = true
  enable_log_file_validation    = true
  include_global_service_events = true
  is_multi_region_trail         = true

  event_selector {
    include_management_events = true
    read_write_type           = "All"
  }

  tags = merge(
    local.cloudwatch_log_archive_tags,
    {
      Name      = local.cloudtrail_name
      Component = "cloudtrail"
    }
  )

  depends_on = [
    aws_s3_bucket_policy.cloudwatch_log_archive,
    aws_s3_bucket_server_side_encryption_configuration.cloudwatch_log_archive,
    aws_s3_bucket_versioning.cloudwatch_log_archive
  ]
}
output "cloudtrail_name" {
  description = "중앙 관리 이벤트 CloudTrail 이름"
  value       = aws_cloudtrail.central.name
}

output "cloudtrail_arn" {
  description = "중앙 관리 이벤트 CloudTrail ARN"
  value       = aws_cloudtrail.central.arn
}

output "cloudtrail_s3_location" {
  description = "Athena 테이블에서 사용할 CloudTrail S3 기본 경로"
  value       = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.cloudtrail_s3_key_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/CloudTrail/"
}
