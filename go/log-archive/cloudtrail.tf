# Organization Trail은 Management 계정의 ../management/audit로 이동했다.
#
# 이 removed 블록은 기존 2계정 state에 Trail이 이미 들어 있는 경우 실물 Trail을
# 삭제하지 않고 Log state에서만 분리한다. Log state에서 이 변경을 먼저 적용한 뒤
# Management audit state로 동일 Trail을 import한다.
removed {
  from = aws_cloudtrail.org

  lifecycle {
    destroy = false
  }
}

output "cloudtrail_s3_location_workload" {
  description = "Workload 계정 Organization Trail 로그의 S3 기본 경로"
  value       = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.cloudtrail_s3_key_prefix}/AWSLogs/${local.org_id}/${local.workload_account_id}/CloudTrail/"
}
