# =============================================================================
# VPC Flow Logs  (2026-08-07 분할 -> 2026-08-10 org 분리로 대상 버킷 변경)
#
# Glue 테이블과 Athena 저장 쿼리는 ../log-archive/flow-logs-analytics.tf 로
# 옮겼다(8/7에는 baseline이었고, 이번에 로그 계정으로).
#
# 여기 남은 aws_flow_log 는 VPC에 붙는 리소스라 VPC와 함께 사라지는 게 맞다.
# 재생성 비용도 사실상 0이다(과금은 S3 저장분뿐).
#
# 대상 버킷은 로그 계정 소유라 data source로 읽을 수 없다(크로스 계정) —
# ARN 조립으로 가리킨다. 쓰기 인가는 저쪽 버킷 정책(AWSLogDeliveryWrite,
# SourceAccount=이 계정)이 맡는다. 버킷 이름 규칙은
# ../log-archive/log-archive.tf 와 반드시 일치해야 한다.
# =============================================================================

locals {
  vpc_flow_logs_s3_prefix = "vpc-flow-logs"

  log_archive_bucket_arn = "arn:aws:s3:::gochuchamchi-log-archive-${var.log_archive_account_id}"

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
  log_destination      = "${local.log_archive_bucket_arn}/${local.vpc_flow_logs_s3_prefix}/"
  log_destination_type = "s3"

  lifecycle {
    precondition {
      condition     = var.log_archive_account_id != ""
      error_message = "log_archive_account_id가 비어 있습니다. 로그 계정 생성 후 계정 ID를 변수에 넣어야 합니다 (../log-archive 먼저 apply)."
    }
  }

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
