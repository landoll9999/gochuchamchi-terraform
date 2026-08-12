# =============================================================================
# Workload metrics -> Log account CloudWatch monitoring account
#
# This belongs to account-baseline because OAM links are account-level,
# near-zero-cost resources that must survive the daily Workload teardown.
# Raw logs continue through the existing Firehose/S3 archive path.
# =============================================================================

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}

resource "aws_oam_link" "security_monitoring_seoul" {
  label_template  = "$AccountName"
  resource_types  = ["AWS::CloudWatch::Metric"]
  sink_identifier = var.log_archive_oam_sink_arn_seoul

  link_configuration {
    metric_configuration {
      filter = "Namespace IN ('AWS/ApplicationELB', 'Gochuchamchi/ApplicationSecurity')"
    }
  }

  tags = local.security_monitoring_link_tags
}

resource "aws_oam_link" "security_monitoring_us_east_1" {
  provider = aws.us_east_1

  label_template  = "$AccountName"
  resource_types  = ["AWS::CloudWatch::Metric"]
  sink_identifier = var.log_archive_oam_sink_arn_us_east_1

  link_configuration {
    metric_configuration {
      filter = "Namespace = 'AWS/WAFV2'"
    }
  }

  tags = local.security_monitoring_link_tags
}

locals {
  security_monitoring_link_tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "security-monitoring-link"
  }
}

variable "log_archive_oam_sink_arn_seoul" {
  description = "Log account OAM sink ARN in ap-northeast-2"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:oam:ap-northeast-2:564186750363:sink/", var.log_archive_oam_sink_arn_seoul))
    error_message = "The Seoul OAM sink must belong to Log account 564186750363 in ap-northeast-2."
  }
}

variable "log_archive_oam_sink_arn_us_east_1" {
  description = "Log account OAM sink ARN in us-east-1"
  type        = string

  validation {
    condition     = can(regex("^arn:aws:oam:us-east-1:564186750363:sink/", var.log_archive_oam_sink_arn_us_east_1))
    error_message = "The us-east-1 OAM sink must belong to Log account 564186750363 in us-east-1."
  }
}
