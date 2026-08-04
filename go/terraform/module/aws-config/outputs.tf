output "configuration_recorder_name" {
  description = "AWS Config Configuration Recorder 이름"
  value       = aws_config_configuration_recorder.this.name
}

output "delivery_channel_name" {
  description = "AWS Config S3 Delivery Channel 이름"
  value       = aws_config_delivery_channel.this.name
}

output "iam_role_arn" {
  description = "AWS Config가 사용하는 IAM Role ARN"
  value       = aws_iam_role.this.arn
}

output "s3_delivery_path" {
  description = "AWS Config 이력과 스냅샷이 저장되는 S3 기본 경로"
  value       = "s3://${var.s3_bucket_name}/${local.config_s3_object_prefix}/"
}

output "recorder_enabled" {
  description = "AWS Config Recorder 활성화 상태"
  value       = aws_config_configuration_recorder_status.this.is_enabled
}