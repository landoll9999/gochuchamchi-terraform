# =============================================================================
# AWS Config -> 중앙 로그 S3
#
# CloudTrail이 "누가 무엇을 했는가"를 남긴다면, AWS Config는 "리소스가 지금 어떤
# 상태이고 언제 어떻게 바뀌었는가"를 남깁니다.
# Security Hub 보안 표준 대부분이 이 Config 기록을 근거로 평가하므로,
# security-hub.tf보다 먼저 적용되어야 합니다(module.security_hub의 depends_on).
#
# 저장 위치는 CloudTrail과 같은 중앙 로그 버킷이고 prefix로만 분리합니다.
#   s3://<중앙-로그-버킷>/config/AWSLogs/<계정ID>/Config/
# =============================================================================

locals {
  aws_config_s3_key_prefix = "config"
}

module "aws_config" {
  source = "./module/aws-config"

  name_prefix = "gochuchamchi"

  # cloudwatch-log-archive.tf의 중앙 로그 버킷 재사용.
  # 같은 계정이라 버킷 정책 추가 없이 모듈 안의 IAM Role 정책만으로 전달이 된다.
  s3_bucket_name = aws_s3_bucket.cloudwatch_log_archive.id
  s3_bucket_arn  = aws_s3_bucket.cloudwatch_log_archive.arn
  s3_key_prefix  = local.aws_config_s3_key_prefix

  # IAM User/Role/Policy 같은 글로벌 리소스도 기록.
  # Security Hub의 IAM 관련 Control이 이 기록을 필요로 한다.
  include_global_resource_types = true

  snapshot_delivery_frequency = var.aws_config_snapshot_delivery_frequency

  tags = local.cloudwatch_log_archive_tags

  # 버킷 정책/암호화/버저닝이 먼저 잡힌 뒤에 Delivery Channel이 만들어져야
  # Config의 전달 테스트(PutObject)가 통과한다. cloudtrail.tf와 동일한 이유.
  depends_on = [
    aws_s3_bucket_policy.cloudwatch_log_archive,
    aws_s3_bucket_server_side_encryption_configuration.cloudwatch_log_archive,
    aws_s3_bucket_versioning.cloudwatch_log_archive
  ]
}
