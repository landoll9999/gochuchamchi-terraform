# =============================================================================
# VPC Flow Logs — 분석 계층 (로그 계정 버전)
#
# ../account-baseline/flow-logs-analytics.tf 에서 이식. 경로의 계정 ID가
# "이 계정"이 아니라 "워크로드 계정"인 것이 유일한 차이다 — Flow Logs 배달
# 경로의 AWSLogs/<계정ID>는 버킷 소유자가 아니라 "로그를 만든 VPC의 계정"이다.
#
#   s3://<새-로그-버킷>/vpc-flow-logs/AWSLogs/<워크로드계정ID>/vpcflowlogs/<리전>/yyyy/MM/dd/
# =============================================================================

locals {
  athena_flowlogs_table_name   = "vpc_flow_logs"
  vpc_flow_logs_s3_base_prefix = "${local.vpc_flow_logs_s3_prefix}/AWSLogs/${local.workload_account_id}/vpcflowlogs"

  # 파케이(parquet) 기본 v2 필드. Athena 스캔 비용이 JSON/text 대비 크게 준다.
  flowlogs_athena_columns = [
    { name = "version", type = "int" },
    { name = "account_id", type = "string" },
    { name = "interface_id", type = "string" },
    { name = "srcaddr", type = "string" },
    { name = "dstaddr", type = "string" },
    { name = "srcport", type = "int" },
    { name = "dstport", type = "int" },
    { name = "protocol", type = "int" },
    { name = "packets", type = "bigint" },
    { name = "bytes", type = "bigint" },
    { name = "start", type = "bigint" },
    { name = "end", type = "bigint" },
    { name = "action", type = "string" },
    { name = "log_status", type = "string" }
  ]
}


# =============================================================================
# Athena - Flow Logs 조회 테이블 (CloudTrail 테이블과 동일한 projection 패턴)
# =============================================================================

resource "aws_glue_catalog_table" "vpc_flow_logs" {
  name          = local.athena_flowlogs_table_name
  database_name = aws_glue_catalog_database.security_logs.name
  description   = "중앙 S3에 저장된 VPC Flow Logs (parquet, 워크로드 계정 발신)"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL = "TRUE"

    "projection.enabled" = "true"
    # 이 VPC는 단일 리전이지만 CloudTrail 테이블과 스키마 구조를 맞춰둔다
    "projection.region.type"              = "injected"
    "projection.event_date.type"          = "date"
    "projection.event_date.format"        = "yyyy/MM/dd"
    "projection.event_date.interval"      = "1"
    "projection.event_date.interval.unit" = "DAYS"
    # Flow Logs도 CloudTrail과 같은 시점부터 조회 대상으로 잡는다
    "projection.event_date.range" = "${var.athena_cloudtrail_projection_start_date},NOW"

    "storage.location.template" = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.vpc_flow_logs_s3_base_prefix}/$${region}/$${event_date}/"
  }

  partition_keys {
    name = "region"
    type = "string"
  }

  partition_keys {
    name = "event_date"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.vpc_flow_logs_s3_base_prefix}/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"
    compressed    = true

    dynamic "columns" {
      for_each = local.flowlogs_athena_columns

      content {
        name = columns.value.name
        type = columns.value.type
      }
    }

    ser_de_info {
      name                  = "flowlogs-parquet-serde"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"

      parameters = {
        "serialization.format" = "1"
      }
    }
  }
}


# =============================================================================
# 조사용 저장 쿼리 - GuardDuty finding이 뜬 뒤 원본 증거를 바로 뽑는 용도
# =============================================================================

locals {
  # 공통 FROM/WHERE 절 — 모든 조사 쿼리가 "최근 24시간, 현재 리전"을 본다
  flowlogs_query_base = <<-SQL
    FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_flowlogs_table_name}"
    WHERE region = '${var.region}'
      AND event_date >= date_format(current_date - INTERVAL '1' DAY, '%Y/%m/%d')
  SQL

  flowlogs_named_queries = {
    "04-flowlogs-rejected-traffic" = {
      description = "최근 24시간 차단(REJECT)된 트래픽 상위 - 어떤 IP가 어디를 두드렸는가"
      query       = <<-SQL
        SELECT
          srcaddr, dstaddr, dstport, protocol,
          COUNT(*)     AS reject_count,
          SUM(packets) AS total_packets
        ${local.flowlogs_query_base}
          AND action = 'REJECT'
        GROUP BY srcaddr, dstaddr, dstport, protocol
        ORDER BY reject_count DESC
        LIMIT 100;
      SQL
    }

    "05-flowlogs-port-scan-detect" = {
      description = "최근 24시간, 단일 소스 IP가 훑은 목적지 포트 수 - 포트스캔 탐지의 원본 근거"
      query       = <<-SQL
        SELECT
          srcaddr,
          COUNT(DISTINCT dstport)                            AS distinct_ports,
          COUNT(DISTINCT dstaddr)                            AS distinct_targets,
          MIN(from_unixtime("start"))                        AS first_seen,
          MAX(from_unixtime("end"))                          AS last_seen,
          SUM(CASE WHEN action = 'REJECT' THEN 1 ELSE 0 END) AS rejected_flows
        ${local.flowlogs_query_base}
        GROUP BY srcaddr
        HAVING COUNT(DISTINCT dstport) >= 20
        ORDER BY distinct_ports DESC
        LIMIT 50;
      SQL
    }

    "06-flowlogs-top-talkers" = {
      description = "최근 24시간 전송량 상위 통신 쌍 - 데이터 유출(exfiltration) 흔적 확인"
      query       = <<-SQL
        SELECT
          srcaddr, dstaddr, dstport,
          SUM(bytes)   AS total_bytes,
          SUM(packets) AS total_packets,
          COUNT(*)     AS flow_count
        ${local.flowlogs_query_base}
          AND action = 'ACCEPT'
        GROUP BY srcaddr, dstaddr, dstport
        ORDER BY total_bytes DESC
        LIMIT 50;
      SQL
    }
  }
}

resource "aws_athena_named_query" "flowlogs" {
  for_each = local.flowlogs_named_queries

  name        = each.key
  description = each.value.description
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id
  query       = each.value.query

  depends_on = [aws_glue_catalog_table.vpc_flow_logs]
}


# =============================================================================
# Outputs
# =============================================================================

output "vpc_flow_logs_s3_location" {
  description = "Flow Logs 원본이 저장되는 S3 기본 경로"
  value       = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.vpc_flow_logs_s3_base_prefix}/"
}
