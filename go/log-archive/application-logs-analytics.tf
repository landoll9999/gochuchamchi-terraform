# =============================================================================
# Athena - centralized Spring application security/access logs
#
# The EKS CloudWatch Observability add-on normally merges a JSON stdout line
# below `log_processed`. Direct root fields are also declared so the table keeps
# working if the collector is later changed to deliver the Spring JSON verbatim.
# =============================================================================

locals {
  athena_application_table_name = "application_logs"
  application_logs_s3_prefix    = "cloudwatch/application"

  application_event_struct_fields = join(",", [
    "timestamp:string",
    "eventcategory:string",
    "eventtype:string",
    "severity:string",
    "requestid:string",
    "cloudfrontrequestid:string",
    "clientip:string",
    "method:string",
    "uri:string",
    "useragent:string",
    "principal:string",
    "roles:array<string>",
    "statuscode:int",
    "responsetimems:bigint",
    "outcome:string",
    "exceptiontype:string",
    "actoruserid:bigint",
    "actorusername:string",
    "targettype:string",
    "targetid:string",
    "reasoncode:string",
    "details:string"
  ])

  application_athena_columns = [
    { name = "log", type = "string" },
    { name = "stream", type = "string" },
    { name = "time", type = "string" },
    { name = "log_processed", type = "struct<${local.application_event_struct_fields}>" },
    { name = "kubernetes", type = "struct<pod_name:string,namespace_name:string,container_name:string,host:string>" },
    { name = "timestamp", type = "string" },
    { name = "eventcategory", type = "string" },
    { name = "eventtype", type = "string" },
    { name = "severity", type = "string" },
    { name = "requestid", type = "string" },
    { name = "cloudfrontrequestid", type = "string" },
    { name = "clientip", type = "string" },
    { name = "method", type = "string" },
    { name = "uri", type = "string" },
    { name = "useragent", type = "string" },
    { name = "principal", type = "string" },
    { name = "roles", type = "array<string>" },
    { name = "statuscode", type = "int" },
    { name = "responsetimems", type = "bigint" },
    { name = "outcome", type = "string" },
    { name = "exceptiontype", type = "string" },
    { name = "actoruserid", type = "bigint" },
    { name = "actorusername", type = "string" },
    { name = "targettype", type = "string" },
    { name = "targetid", type = "string" },
    { name = "reasoncode", type = "string" },
    { name = "details", type = "string" }
  ]

  application_recent_partition = <<-SQL
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

  application_normalized_event_select = <<-SQL
    SELECT
      try(from_iso8601_timestamp(COALESCE(log_processed.timestamp, "timestamp"))) AS event_time,
      COALESCE(log_processed.eventcategory, eventcategory) AS event_category,
      COALESCE(log_processed.eventtype, eventtype) AS event_type,
      COALESCE(log_processed.severity, severity) AS severity,
      COALESCE(log_processed.requestid, requestid) AS request_id,
      COALESCE(log_processed.cloudfrontrequestid, cloudfrontrequestid) AS cloudfront_request_id,
      COALESCE(log_processed.clientip, clientip) AS client_ip,
      COALESCE(log_processed.method, method) AS method,
      COALESCE(log_processed.uri, uri) AS uri,
      COALESCE(log_processed.useragent, useragent) AS user_agent,
      COALESCE(log_processed.principal, principal) AS principal,
      COALESCE(log_processed.roles, roles) AS roles,
      COALESCE(log_processed.statuscode, statuscode) AS status_code,
      COALESCE(log_processed.responsetimems, responsetimems) AS response_time_ms,
      COALESCE(log_processed.outcome, outcome) AS outcome,
      COALESCE(log_processed.exceptiontype, exceptiontype) AS exception_type,
      COALESCE(log_processed.actoruserid, actoruserid) AS actor_user_id,
      COALESCE(log_processed.actorusername, actorusername) AS actor_username,
      COALESCE(log_processed.targettype, targettype) AS target_type,
      COALESCE(log_processed.targetid, targetid) AS target_id,
      COALESCE(log_processed.reasoncode, reasoncode) AS reason_code,
      COALESCE(log_processed.details, details) AS details,
      kubernetes.namespace_name AS namespace_name,
      kubernetes.pod_name AS pod_name,
      year,
      month,
      day,
      hour
    FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_application_table_name}"
  SQL
}

resource "aws_glue_catalog_table" "application_logs" {
  name          = local.athena_application_table_name
  database_name = aws_glue_catalog_database.security_logs.name
  description   = "Spring HTTP access and security audit events centralized from EKS"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL       = "TRUE"
    classification = "json"

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

    "storage.location.template" = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.application_logs_s3_prefix}/year=$${year}/month=$${month}/day=$${day}/hour=$${hour}/"
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
    location      = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.application_logs_s3_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    dynamic "columns" {
      for_each = local.application_athena_columns

      content {
        name = columns.value.name
        type = columns.value.type
      }
    }

    ser_de_info {
      name                  = "application-json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "case.insensitive" = "true"
      }
    }
  }
}

locals {
  application_named_queries = {
    "09-application-status-codes-24h" = {
      description = "최근 24시간 애플리케이션 HTTP 상태 코드별 건수"
      query       = <<-SQL
        WITH events AS (
          ${local.application_normalized_event_select}
          WHERE ${local.application_recent_partition}
        )
        SELECT
          status_code,
          COUNT(*) AS request_count
        FROM events
        WHERE event_category = 'HTTP_ACCESS'
          AND event_time >= current_timestamp - INTERVAL '24' HOUR
        GROUP BY status_code
        ORDER BY request_count DESC, status_code;
      SQL
    }

    "10-application-top-4xx-sources" = {
      description = "최근 24시간 4xx 응답을 많이 발생시킨 IP와 URI"
      query       = <<-SQL
        WITH events AS (
          ${local.application_normalized_event_select}
          WHERE ${local.application_recent_partition}
        )
        SELECT
          client_ip,
          method,
          uri,
          status_code,
          COUNT(*) AS request_count,
          MAX(event_time) AS last_seen
        FROM events
        WHERE event_category = 'HTTP_ACCESS'
          AND status_code BETWEEN 400 AND 499
          AND event_time >= current_timestamp - INTERVAL '24' HOUR
        GROUP BY client_ip, method, uri, status_code
        ORDER BY request_count DESC
        LIMIT 200;
      SQL
    }

    "11-application-5xx-errors" = {
      description = "최근 24시간 5xx 응답과 예외 유형·파드 집계"
      query       = <<-SQL
        WITH events AS (
          ${local.application_normalized_event_select}
          WHERE ${local.application_recent_partition}
        )
        SELECT
          uri,
          exception_type,
          pod_name,
          COUNT(*) AS error_count,
          MAX(response_time_ms) AS max_response_time_ms,
          MAX(event_time) AS last_seen
        FROM events
        WHERE event_category = 'HTTP_ACCESS'
          AND status_code BETWEEN 500 AND 599
          AND event_time >= current_timestamp - INTERVAL '24' HOUR
        GROUP BY uri, exception_type, pod_name
        ORDER BY error_count DESC
        LIMIT 200;
      SQL
    }

    "12-application-security-failures" = {
      description = "최근 24시간 로그인 실패·권한 거부·차단 보안 이벤트"
      query       = <<-SQL
        WITH events AS (
          ${local.application_normalized_event_select}
          WHERE ${local.application_recent_partition}
        )
        SELECT
          event_time,
          severity,
          event_type,
          outcome,
          client_ip,
          COALESCE(actor_username, principal) AS actor,
          method,
          uri,
          reason_code,
          details,
          request_id,
          cloudfront_request_id
        FROM events
        WHERE event_category = 'SECURITY_EVENT'
          AND event_time >= current_timestamp - INTERVAL '24' HOUR
          AND (outcome = 'FAILURE' OR event_type IN ('ACCESS_DENIED', 'ACCESS_BLOCKED'))
        ORDER BY event_time DESC
        LIMIT 500;
      SQL
    }

    "13-application-high-critical-events" = {
      description = "최근 24시간 HIGH/CRITICAL 권한·계정 변경 이벤트"
      query       = <<-SQL
        WITH events AS (
          ${local.application_normalized_event_select}
          WHERE ${local.application_recent_partition}
        )
        SELECT
          event_time,
          severity,
          event_type,
          outcome,
          client_ip,
          COALESCE(actor_username, principal) AS actor,
          target_type,
          target_id,
          reason_code,
          details,
          request_id
        FROM events
        WHERE event_category = 'SECURITY_EVENT'
          AND severity IN ('HIGH', 'CRITICAL')
          AND event_time >= current_timestamp - INTERVAL '24' HOUR
        ORDER BY event_time DESC
        LIMIT 500;
      SQL
    }

    "16-waf-allow-application-failure-correlation" = {
      description = "WAF가 허용했지만 애플리케이션에서 오류·거부로 판정된 요청 상관분석"
      query       = <<-SQL
        WITH allowed_waf AS (
          SELECT
            from_unixtime("timestamp" / 1000.0) AS waf_time,
            httprequest.requestid AS cloudfront_request_id,
            httprequest.clientip AS waf_client_ip,
            httprequest.httpmethod AS waf_method,
            httprequest.uri AS waf_uri,
            terminatingruleid
          FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_waf_table_name}"
          WHERE ${local.application_recent_partition}
            AND action = 'ALLOW'
        ),
        application_events AS (
          ${local.application_normalized_event_select}
          WHERE ${local.application_recent_partition}
        )
        SELECT
          w.waf_time,
          a.event_time AS application_time,
          w.waf_client_ip,
          w.waf_method,
          w.waf_uri,
          a.status_code,
          a.event_type,
          a.outcome,
          a.severity,
          a.exception_type,
          a.reason_code,
          w.cloudfront_request_id
        FROM allowed_waf w
        JOIN application_events a
          ON w.cloudfront_request_id = a.cloudfront_request_id
        WHERE a.event_time >= current_timestamp - INTERVAL '24' HOUR
          AND (
            a.status_code >= 400
            OR a.outcome = 'FAILURE'
            OR a.event_type IN ('ACCESS_DENIED', 'ACCESS_BLOCKED')
          )
        ORDER BY a.event_time DESC
        LIMIT 500;
      SQL
    }
  }
}

resource "aws_athena_named_query" "application" {
  for_each = local.application_named_queries

  name        = each.key
  description = each.value.description
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id
  query       = each.value.query

  depends_on = [
    aws_glue_catalog_table.application_logs,
    aws_glue_catalog_table.waf_logs
  ]
}

output "athena_application_table_name" {
  description = "Spring 애플리케이션 보안·접근 로그 Athena 테이블"
  value       = aws_glue_catalog_table.application_logs.name
}

output "application_logs_s3_location" {
  description = "중앙 애플리케이션 로그 S3 위치"
  value       = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.application_logs_s3_prefix}/"
}
