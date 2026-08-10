resource "aws_cloudtrail" "org" {
  name           = var.cloudtrail_name
  s3_bucket_name = var.log_archive_bucket_name
  s3_key_prefix  = var.cloudtrail_s3_key_prefix
  kms_key_id     = var.log_archive_kms_key_arn

  enable_logging                = true
  enable_log_file_validation    = true
  include_global_service_events = true
  is_multi_region_trail         = true
  is_organization_trail         = true

  event_selector {
    include_management_events = true
    read_write_type           = "All"
  }

  tags = {
    Name        = var.cloudtrail_name
    Project     = "gochuchamchi"
    Environment = "organization"
    ManagedBy   = "Terraform"
    Component   = "organization-cloudtrail"
  }

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.management_account_id
      error_message = "Organization Trail은 Management 계정(307223751140)에서만 관리할 수 있습니다."
    }
  }
}
