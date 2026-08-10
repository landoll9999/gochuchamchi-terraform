# =============================================================================
# VPC Flow Logs  (2026-08-07 분할)
#
# Glue 테이블과 Athena 저장 쿼리는 ../account-baseline/flow-logs-analytics.tf 로
# 옮겼다. 그쪽은 로그 버킷과 생명주기가 같고, 지워도 절감이 0이면서 재생성만
# 번거로운 영역이다.
#
# 여기 남은 aws_flow_log 는 VPC에 붙는 리소스라 VPC와 함께 사라지는 게 맞다.
# 재생성 비용도 사실상 0이다(과금은 S3 저장분뿐).
# =============================================================================

data "aws_s3_bucket" "cloudwatch_log_archive" {
  bucket = "gochuchamchi-cloudwatch-log-archive-${data.aws_caller_identity.current.account_id}"
}

locals {
  vpc_flow_logs_s3_prefix = "vpc-flow-logs"

  vpc_flow_logs_tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "vpc-flow-logs"
  }
}

resource "aws_flow_log" "vpc" {
  vpc_id               = module.vpc.vpc_id
  traffic_type         = "ALL"
  log_destination      = "${data.aws_s3_bucket.cloudwatch_log_archive.arn}/${local.vpc_flow_logs_s3_prefix}/"
  log_destination_type = "s3"

  # 기본 600초 집계. 포트스캔 타임라인 분석에는 충분하고 S3 객체 수를 줄여준다.
  max_aggregation_interval = 600

  destination_options {
    file_format = "parquet"
    # CloudTrail 테이블과 같은 projection 방식(yyyy/MM/dd 경로)을 쓰려고
    # hive 호환 파티션은 끈다.
    hive_compatible_partitions = false
    per_hour_partition         = false
  }

  tags = merge(
    local.vpc_flow_logs_tags,
    {
      Name = "gochuchamchi-vpc-flow-logs"
    }
  )

}

output "vpc_flow_logs_id" {
  description = "VPC Flow Log ID"
  value       = aws_flow_log.vpc.id
}
