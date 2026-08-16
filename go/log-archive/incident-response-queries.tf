# =============================================================================
# Incident Response (IR) Athena saved queries
#
# Discord 알림에 포함된 날짜와 IP/행위자만 바꿔 바로 실행하는 조사용 쿼리다.
# 실시간 탐지/차단은 EventBridge · SNS · Discord가 담당하고, 이 쿼리는 사후
# 증적 확인과 상관 분석만 담당한다. 각 쿼리는 파티션 조건을 반드시 포함해
# 불필요한 S3 전체 스캔을 막는다.
# =============================================================================

locals {
  incident_response_queries = {
    "IR-01 IAM activity by IP" = {
      description = "CloudTrail: 특정 날짜·IP의 IAM/API 행위 조사. date_key와 source_ip만 교체"
      query = <<-SQL
        WITH params AS (
          SELECT 'YYYY/MM/DD' AS date_key, 'REPLACE_WITH_SOURCE_IP' AS source_ip
        )
        SELECT
          eventtime,
          eventsource,
          eventname,
          COALESCE(useridentity.arn, useridentity.username, useridentity.principalid) AS actor,
          sourceipaddress,
          requestparameters,
          errorcode
        FROM "${aws_glue_catalog_database.security_logs.name}"."${aws_glue_catalog_table.cloudtrail.name}" c
        CROSS JOIN params p
        WHERE c.region = '${var.region}'
          AND c.event_date = p.date_key
          AND c.sourceipaddress = p.source_ip
        ORDER BY eventtime DESC
        LIMIT 200;
      SQL
    }

    "IR-02 IAM activity by actor" = {
      description = "CloudTrail: 특정 날짜·행위자 문자열의 권한 변경 조사. date_key와 actor_fragment만 교체"
      query = <<-SQL
        WITH params AS (
          SELECT 'YYYY/MM/DD' AS date_key, 'REPLACE_WITH_ACTOR_FRAGMENT' AS actor_fragment
        )
        SELECT
          eventtime,
          eventsource,
          eventname,
          COALESCE(useridentity.arn, useridentity.username, useridentity.principalid) AS actor,
          sourceipaddress,
          requestparameters,
          errorcode
        FROM "${aws_glue_catalog_database.security_logs.name}"."${aws_glue_catalog_table.cloudtrail.name}" c
        CROSS JOIN params p
        WHERE c.region = '${var.region}'
          AND c.event_date = p.date_key
          AND lower(COALESCE(useridentity.arn, useridentity.username, useridentity.principalid))
              LIKE concat('%', lower(p.actor_fragment), '%')
        ORDER BY eventtime DESC
        LIMIT 200;
      SQL
    }

    "IR-03 WAF blocked requests by IP" = {
      description = "WAF: 특정 날짜·IP가 차단된 규칙·URI·User-Agent 확인. date_key와 source_ip만 교체"
      query = <<-SQL
        WITH params AS (
          SELECT 'YYYY/MM/DD' AS date_key, 'REPLACE_WITH_SOURCE_IP' AS source_ip
        )
        SELECT
          from_unixtime(w."timestamp" / 1000.0) AS event_time,
          w.terminatingruleid,
          w.action,
          w.httprequest.clientip AS client_ip,
          w.httprequest.country AS country,
          w.httprequest.httpmethod AS method,
          w.httprequest.uri AS uri
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_waf_table_name}" w
        CROSS JOIN params p
        WHERE w.year = substr(p.date_key, 1, 4)
          AND w.month = substr(p.date_key, 6, 2)
          AND w.day = substr(p.date_key, 9, 2)
          AND w.action = 'BLOCK'
          AND w.httprequest.clientip = p.source_ip
        ORDER BY event_time DESC
        LIMIT 200;
      SQL
    }

    "IR-04 VPC flow investigation by IP" = {
      description = "VPC Flow Logs: 특정 날짜·IP의 ACCEPT/REJECT·대상 포트·전송량 조사. date_key와 source_ip만 교체"
      query = <<-SQL
        WITH params AS (
          SELECT 'YYYY/MM/DD' AS date_key, 'REPLACE_WITH_SOURCE_IP' AS source_ip
        )
        SELECT
          from_unixtime(f."start") AS first_seen,
          from_unixtime(f."end") AS last_seen,
          f.srcaddr,
          f.dstaddr,
          f.dstport,
          f.action,
          SUM(f.packets) AS packets,
          SUM(f.bytes) AS bytes
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_flowlogs_table_name}" f
        CROSS JOIN params p
        WHERE f.region = '${var.region}'
          AND f.event_date = p.date_key
          AND f.srcaddr = p.source_ip
        GROUP BY f."start", f."end", f.srcaddr, f.dstaddr, f.dstport, f.action
        ORDER BY last_seen DESC
        LIMIT 200;
      SQL
    }

    "IR-05 ALB requests by IP" = {
      description = "ALB: 특정 날짜·IP의 요청 URI·응답 코드·응답시간 조사. date_key와 source_ip만 교체"
      query = <<-SQL
        WITH params AS (
          SELECT 'YYYY/MM/DD' AS date_key, 'REPLACE_WITH_SOURCE_IP' AS source_ip
        )
        SELECT
          time,
          client_ip,
          request_verb,
          request_url,
          elb_status_code,
          target_status_code,
          target_processing_time,
          user_agent,
          trace_id
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_alb_table_name}" a
        CROSS JOIN params p
        WHERE a.day = p.date_key
          AND a.client_ip = p.source_ip
        ORDER BY try(from_iso8601_timestamp(time)) DESC
        LIMIT 200;
      SQL
    }

    "IR-06 RDS audit by date" = {
      description = "RDS Audit: 특정 날짜의 인증 실패·권한 변경·DDL 조사. date_key만 교체"
      query = <<-SQL
        WITH params AS (SELECT 'YYYY/MM/DD' AS date_key)
        SELECT year, month, day, hour, message
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_rds_audit_table_name}" r
        CROSS JOIN params p
        WHERE r.year = substr(p.date_key, 1, 4)
          AND r.month = substr(p.date_key, 6, 2)
          AND r.day = substr(p.date_key, 9, 2)
          AND regexp_like(lower(r.message), '(access denied|authentication failed|login failed|create|alter|drop|grant|revoke)')
        ORDER BY hour DESC
        LIMIT 500;
      SQL
    }
  }
}

resource "aws_athena_named_query" "incident_response" {
  for_each = local.incident_response_queries

  name        = each.key
  description = each.value.description
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id
  query       = each.value.query

  depends_on = [
    aws_glue_catalog_table.cloudtrail,
    aws_glue_catalog_table.waf_logs,
    aws_glue_catalog_table.vpc_flow_logs,
    aws_glue_catalog_table.alb_access_logs,
    aws_glue_catalog_table.rds_audit_logs,
  ]
}
