output "org_trail_arn" {
  value       = aws_cloudtrail.org.arn
  description = "Management 소유 Organization Trail ARN"
}

output "cloudtrail_s3_locations" {
  description = "계정별 Organization Trail 기본 경로"
  value = {
    management = format(
      "s3://%s/%s/AWSLogs/<ORG_ID>/%s/CloudTrail/",
      var.log_archive_bucket_name,
      var.cloudtrail_s3_key_prefix,
      var.management_account_id,
    )
    log_archive = format(
      "s3://%s/%s/AWSLogs/<ORG_ID>/%s/CloudTrail/",
      var.log_archive_bucket_name,
      var.cloudtrail_s3_key_prefix,
      var.log_archive_account_id,
    )
    workload = format(
      "s3://%s/%s/AWSLogs/<ORG_ID>/%s/CloudTrail/",
      var.log_archive_bucket_name,
      var.cloudtrail_s3_key_prefix,
      var.workload_account_id,
    )
  }
}
