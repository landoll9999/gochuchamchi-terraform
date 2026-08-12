# =============================================================================
# CloudWatch cross-account observability - Log account as monitoring account
#
# Only metrics are shared. Raw WAF/application logs already arrive in the
# immutable central S3 archive and are investigated with Athena, so duplicating
# cross-account log visibility would add cost and operational complexity.
# =============================================================================

locals {
  oam_shared_resource_types = ["AWS::CloudWatch::Metric"]

  oam_sink_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowWorkloadMetricsLink"
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${local.workload_account_id}:root"
      }
      Action   = ["oam:CreateLink", "oam:UpdateLink"]
      Resource = "*"
      Condition = {
        "ForAllValues:StringEquals" = {
          "oam:ResourceTypes" = local.oam_shared_resource_types
        }
      }
    }]
  })
}

resource "aws_oam_sink" "security_monitoring_seoul" {
  name = "gochuchamchi-security-monitoring-seoul"

  tags = merge(local.cloudwatch_log_archive_tags, {
    Component = "security-monitoring"
  })
}

resource "aws_oam_sink_policy" "security_monitoring_seoul" {
  sink_identifier = aws_oam_sink.security_monitoring_seoul.id
  policy          = local.oam_sink_policy
}

resource "aws_oam_sink" "security_monitoring_us_east_1" {
  provider = aws.us_east_1

  name = "gochuchamchi-security-monitoring-us-east-1"

  tags = merge(local.cloudwatch_log_archive_tags, {
    Component = "security-monitoring"
  })
}

resource "aws_oam_sink_policy" "security_monitoring_us_east_1" {
  provider = aws.us_east_1

  sink_identifier = aws_oam_sink.security_monitoring_us_east_1.id
  policy          = local.oam_sink_policy
}

output "oam_sink_arn_seoul" {
  description = "Log account OAM sink ARN for the Workload Seoul link"
  value       = aws_oam_sink.security_monitoring_seoul.arn
}

output "oam_sink_arn_us_east_1" {
  description = "Log account OAM sink ARN for the Workload us-east-1 link"
  value       = aws_oam_sink.security_monitoring_us_east_1.arn
}
