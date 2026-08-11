# =============================================================================
# Athena - CloudFront WAF 공격 로그 조회
#
# Workload us-east-1 CloudWatch Logs -> Log 계정 Destination -> 서울 Firehose
# -> 중앙 Object Lock S3의 cloudwatch/waf/year=... 경로를 읽는다.
# =============================================================================

locals {
  athena_waf_table_name = "waf_logs"
  waf_logs_s3_prefix    = "cloudwatch/waf"

  # AWS 공식 WAF Athena 스키마를 기준으로 하되, 새 로그 필드도 함께 수용한다.
  waf_athena_columns = [
    { name = "timestamp", type = "bigint" },
    { name = "formatversion", type = "int" },
    { name = "webaclid", type = "string" },
    { name = "terminatingruleid", type = "string" },
    { name = "terminatingruletype", type = "string" },
    { name = "action", type = "string" },
    { name = "terminatingrulematchdetails", type = "array<struct<conditiontype:string,sensitivitylevel:string,location:string,matcheddata:array<string>>>" },
    { name = "httpsourcename", type = "string" },
    { name = "httpsourceid", type = "string" },
    {
      name = "rulegrouplist"
      type = "array<struct<rulegroupid:string,terminatingrule:struct<ruleid:string,action:string,rulematchdetails:array<struct<conditiontype:string,sensitivitylevel:string,location:string,matcheddata:array<string>>>>,nonterminatingmatchingrules:array<struct<ruleid:string,action:string,overriddenaction:string,rulematchdetails:array<struct<conditiontype:string,sensitivitylevel:string,location:string,matcheddata:array<string>>>>>,excludedrules:array<struct<ruleid:string,exclusiontype:string>>>>"
    },
    { name = "ratebasedrulelist", type = "array<struct<ratebasedruleid:string,limitkey:string,maxrateallowed:bigint,evaluationwindowsec:bigint,limitvalue:string>>" },
    { name = "nonterminatingmatchingrules", type = "array<struct<ruleid:string,action:string,overriddenaction:string,rulematchdetails:array<struct<conditiontype:string,sensitivitylevel:string,location:string,matcheddata:array<string>>>>>" },
    { name = "responsecodesent", type = "int" },
    {
      name = "httprequest"
      type = "struct<clientip:string,country:string,headers:array<struct<name:string,value:string>>,uri:string,args:string,httpversion:string,httpmethod:string,requestid:string,fragment:string,scheme:string,host:string>"
    },
    { name = "labels", type = "array<struct<name:string>>" },
    { name = "captcharesponse", type = "struct<responsecode:string,solvetimestamp:string,failurereason:string>" },
    { name = "challengeresponse", type = "struct<responsecode:string,solvetimestamp:string,failurereason:string>" },
    { name = "ja3fingerprint", type = "string" },
    { name = "ja4fingerprint", type = "string" },
    { name = "oversizefields", type = "array<string>" },
    { name = "requestbodysize", type = "bigint" },
    { name = "requestbodysizeinspectedbywaf", type = "bigint" }
  ]
}

resource "aws_glue_catalog_table" "waf_logs" {
  name          = local.athena_waf_table_name
  database_name = aws_glue_catalog_database.security_logs.name
  description   = "CloudFront WAF request logs centralized from the Workload account"
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

    "storage.location.template" = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.waf_logs_s3_prefix}/year=$${year}/month=$${month}/day=$${day}/hour=$${hour}/"
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
    location      = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.waf_logs_s3_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    dynamic "columns" {
      for_each = local.waf_athena_columns

      content {
        name = columns.value.name
        type = columns.value.type
      }
    }

    ser_de_info {
      name                  = "waf-json-serde"
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"

      parameters = {
        "case.insensitive" = "true"
      }
    }
  }
}


# =============================================================================
# Athena 저장 쿼리 - 오늘 차단 요청 상세와 공격 IP 집계
# =============================================================================

locals {
  waf_today_partition = <<-SQL
    year = date_format(current_timestamp, '%Y')
      AND month = date_format(current_timestamp, '%m')
      AND day = date_format(current_timestamp, '%d')
  SQL

  waf_named_queries = {
    "07-waf-blocked-request-details" = {
      description = "오늘 WAF가 차단한 요청 상세 - 규칙, IP, 국가, 메서드, URI, 쿼리스트링"
      query       = <<-SQL
        SELECT
          from_unixtime("timestamp" / 1000.0) AS event_time,
          terminatingruleid,
          action,
          httprequest.clientip   AS client_ip,
          httprequest.country    AS country,
          httprequest.httpmethod AS method,
          httprequest.uri        AS uri,
          httprequest.args       AS query_string
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_waf_table_name}"
        WHERE ${local.waf_today_partition}
          AND action = 'BLOCK'
        ORDER BY event_time DESC
        LIMIT 200;
      SQL
    }

    "08-waf-top-attacking-ips" = {
      description = "오늘 WAF 차단 횟수가 많은 IP와 매칭 규칙 집계"
      query       = <<-SQL
        SELECT
          httprequest.clientip AS client_ip,
          httprequest.country  AS country,
          terminatingruleid,
          COUNT(*)             AS blocked_count,
          COUNT(DISTINCT httprequest.uri) AS targeted_uri_count
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_waf_table_name}"
        WHERE ${local.waf_today_partition}
          AND action = 'BLOCK'
        GROUP BY httprequest.clientip, httprequest.country, terminatingruleid
        ORDER BY blocked_count DESC
        LIMIT 100;
      SQL
    }
  }
}

resource "aws_athena_named_query" "waf" {
  for_each = local.waf_named_queries

  name        = each.key
  description = each.value.description
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id
  query       = each.value.query

  depends_on = [aws_glue_catalog_table.waf_logs]
}

output "waf_logs_s3_location" {
  description = "중앙 WAF 로그 S3 위치"
  value       = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.waf_logs_s3_prefix}/"
}

output "athena_waf_table_name" {
  description = "WAF 공격 로그 Athena 테이블"
  value       = aws_glue_catalog_table.waf_logs.name
}
