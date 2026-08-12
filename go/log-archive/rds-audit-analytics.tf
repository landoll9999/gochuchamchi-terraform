# =============================================================================
# Athena - centralized RDS audit logs
#
# Audit log line formats vary by engine and configuration (for example MySQL
# MariaDB Audit vs PostgreSQL pgaudit). Keep the immutable original message as
# a one-column external table first; it is safe for every engine and remains
# useful for investigation while a typed parser is added later if required.
# =============================================================================

locals {
  athena_rds_audit_table_name = "rds_audit_logs"
  rds_audit_logs_s3_prefix    = "cloudwatch/rds-audit"

  rds_audit_recent_partition = <<-SQL
    (
      (year = date_format(current_timestamp, '%Y')
        AND month = date_format(current_timestamp, '%m')
        AND day = date_format(current_timestamp, '%d'))
      OR
      (year = date_format(current_timestamp - INTERVAL '1' DAY, '%Y')
        AND month = date_format(current_timestamp - INTERVAL '1' DAY, '%m')
        AND day = date_format(current_timestamp - INTERVAL '1' DAY, '%d'))
    )
  SQL

  rds_audit_named_queries = {
    "17-rds-audit-recent-events-24h" = {
      description = "최근 24시간 RDS 감사 원문 이벤트"
      query       = <<-SQL
        SELECT
          year, month, day, hour,
          message
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_rds_audit_table_name}"
        WHERE ${local.rds_audit_recent_partition}
        LIMIT 500;
      SQL
    }

    "18-rds-audit-authentication-failures-24h" = {
      description = "최근 24시간 RDS 인증 실패·접근 거부 흔적"
      query       = <<-SQL
        SELECT
          year, month, day, hour,
          message
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_rds_audit_table_name}"
        WHERE ${local.rds_audit_recent_partition}
          AND (
            lower(message) LIKE '%access denied%'
            OR lower(message) LIKE '%authentication failed%'
            OR lower(message) LIKE '%login failed%'
            OR lower(message) LIKE '%password authentication failed%'
          )
        LIMIT 500;
      SQL
    }

    "19-rds-audit-privilege-and-ddl-24h" = {
      description = "최근 24시간 RDS 권한 변경 및 DDL 흔적"
      query       = <<-SQL
        SELECT
          year, month, day, hour,
          message
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_rds_audit_table_name}"
        WHERE ${local.rds_audit_recent_partition}
          AND regexp_like(lower(message), '(create|alter|drop|grant|revoke)')
        LIMIT 500;
      SQL
    }

    "20-rds-audit-data-mutations-24h" = {
      description = "최근 24시간 RDS 데이터 변경(INSERT/UPDATE/DELETE/TRUNCATE) 흔적"
      query       = <<-SQL
        SELECT
          year, month, day, hour,
          message
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_rds_audit_table_name}"
        WHERE ${local.rds_audit_recent_partition}
          AND regexp_like(lower(message), '(insert|update|delete|truncate)')
        LIMIT 500;
      SQL
    }
  }
}

resource "aws_glue_catalog_table" "rds_audit_logs" {
  name          = local.athena_rds_audit_table_name
  database_name = aws_glue_catalog_database.security_logs.name
  description   = "Raw immutable RDS audit log messages centralized from the Workload account"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL       = "TRUE"
    classification = "text"

    "projection.enabled"     = "true"
    "projection.year.type"   = "integer"
    "projection.year.range"  = "2026,2036"
    "projection.year.digits" = "4"

    "projection.month.type"   = "integer"
    "projection.month.range"  = "1,12"
    "projection.month.digits" = "2"

    "projection.day.type"   = "integer"
    "projection.day.range"  = "1,31"
    "projection.day.digits" = "2"

    "projection.hour.type"   = "integer"
    "projection.hour.range"  = "0,23"
    "projection.hour.digits" = "2"

    "storage.location.template" = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.rds_audit_logs_s3_prefix}/year=$${year}/month=$${month}/day=$${day}/hour=$${hour}/"
  }

  partition_keys {
    name = "year"
    type = "string"
  }

  partition_keys {
    name = "month"
    type = "string"
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  partition_keys {
    name = "hour"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.rds_audit_logs_s3_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    columns {
      name = "message"
      type = "string"
    }

    ser_de_info {
      name                  = "rds-audit-raw-message-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"

      parameters = {
        "input.regex" = "^(.*)$"
      }
    }
  }
}

resource "aws_athena_named_query" "rds_audit" {
  for_each = local.rds_audit_named_queries

  name        = each.key
  description = each.value.description
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id
  query       = each.value.query

  depends_on = [aws_glue_catalog_table.rds_audit_logs]
}

output "athena_rds_audit_table_name" {
  description = "RDS 감사 로그 Athena 원문 테이블"
  value       = aws_glue_catalog_table.rds_audit_logs.name
}

output "rds_audit_logs_s3_location" {
  description = "중앙 RDS 감사 로그 S3 위치"
  value       = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.rds_audit_logs_s3_prefix}/"
}
