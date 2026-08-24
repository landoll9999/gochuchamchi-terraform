# =============================================================================
# Athena - CloudTrail 중앙 로그 조회 (로그 계정 버전)
#
# ../account-baseline/athena.tf 에서 이식. 전환일 이후 로그는 여기서 조회하고,
# 전환일 이전 로그는 워크로드 계정 Athena(구 버킷)에 남는다 — runbook 참고.
#
# org trail의 경로 차이:
#   management(=이 계정) 자신의 이벤트 -> AWSLogs/<이계정ID>/CloudTrail/...
#   멤버 계정(워크로드) 이벤트         -> AWSLogs/<org-ID>/<워크로드계정ID>/CloudTrail/...
# 조사 대상의 대부분은 워크로드 이벤트라 테이블은 워크로드의 org 경로를 잡는다.
# 이 계정 자신의 이벤트를 봐야 하면 앞 경로로 테이블을 하나 더 만들면 된다.
# =============================================================================

locals {
  athena_security_database_name       = "gochuchamchi_security_logs"
  athena_cloudtrail_table_name        = "cloudtrail_logs"
  athena_workgroup_name               = "gochuchamchi-security-logs"
  athena_investigation_workgroup_name = "gochuchamchi-security-investigation"

  cloudtrail_s3_base_prefix = "${local.cloudtrail_s3_key_prefix}/AWSLogs/${local.org_id}/${local.workload_account_id}/CloudTrail"

  cloudtrail_athena_columns = [
    { name = "eventversion", type = "string" },
    {
      name = "useridentity"
      type = "struct<type:string,principalid:string,arn:string,accountid:string,invokedby:string,accesskeyid:string,username:string,onbehalfof:struct<userid:string,identitystorearn:string>,sessioncontext:struct<attributes:struct<mfaauthenticated:string,creationdate:string>,sessionissuer:struct<type:string,principalid:string,arn:string,accountid:string,username:string>,ec2roledelivery:string,webidfederationdata:struct<federatedprovider:string,attributes:map<string,string>>>>"
    },
    { name = "eventtime", type = "string" },
    { name = "eventsource", type = "string" },
    { name = "eventname", type = "string" },
    { name = "awsregion", type = "string" },
    { name = "sourceipaddress", type = "string" },
    { name = "useragent", type = "string" },
    { name = "errorcode", type = "string" },
    { name = "errormessage", type = "string" },
    { name = "requestparameters", type = "string" },
    { name = "responseelements", type = "string" },
    { name = "additionaleventdata", type = "string" },
    { name = "requestid", type = "string" },
    { name = "eventid", type = "string" },
    { name = "readonly", type = "string" },
    { name = "resources", type = "array<struct<arn:string,accountid:string,type:string>>" },
    { name = "eventtype", type = "string" },
    { name = "apiversion", type = "string" },
    { name = "recipientaccountid", type = "string" },
    { name = "serviceeventdetails", type = "string" },
    { name = "sharedeventid", type = "string" },
    { name = "vpcendpointid", type = "string" },
    { name = "vpcendpointaccountid", type = "string" },
    { name = "eventcategory", type = "string" },
    { name = "addendum", type = "struct<reason:string,updatedfields:string,originalrequestid:string,originaleventid:string>" },
    { name = "sessioncredentialfromconsole", type = "string" },
    { name = "edgedevicedetails", type = "string" },
    { name = "tlsdetails", type = "struct<tlsversion:string,ciphersuite:string,clientprovidedhostheader:string>" }
  ]

  athena_tags = merge(
    local.cloudwatch_log_archive_tags,
    {
      Component = "athena"
    }
  )
}


# =============================================================================
# Athena 쿼리 결과 S3 - 원본 로그와 분리된 임시 결과 저장소
# =============================================================================

resource "aws_s3_bucket" "athena_results" {
  # 구 워크로드 시절의 athena-results 버킷과 이름 충돌을 피하려고 log- 접두사를 붙인다
  bucket = "gochuchamchi-log-athena-results-${data.aws_caller_identity.current.account_id}"

  # 쿼리 결과는 재생성할 수 있으므로 프로젝트 정리 시 함께 삭제 가능
  force_destroy = true

  tags = merge(
    local.athena_tags,
    {
      Name = "gochuchamchi-athena-results"
    }
  )
}

resource "aws_s3_bucket_ownership_controls" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-athena-query-results"
    status = "Enabled"

    filter {
      prefix = "results/"
    }

    expiration {
      days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "athena_results_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.athena_results.arn,
      "${aws_s3_bucket.athena_results.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  policy = data.aws_iam_policy_document.athena_results_bucket.json

  depends_on = [
    aws_s3_bucket_ownership_controls.athena_results,
    aws_s3_bucket_public_access_block.athena_results
  ]
}


# =============================================================================
# Glue Data Catalog - Athena에서 CloudTrail JSON을 읽는 스키마
# =============================================================================

resource "aws_glue_catalog_database" "security_logs" {
  name        = local.athena_security_database_name
  description = "CloudTrail 중앙 감사 로그 조회용 Athena 데이터베이스 (전환일 이후분)"
}

resource "aws_glue_catalog_table" "cloudtrail" {
  name          = local.athena_cloudtrail_table_name
  database_name = aws_glue_catalog_database.security_logs.name
  description   = "중앙 S3에 저장된 org trail 관리 이벤트 (워크로드 계정 경로)"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL = "TRUE"

    classification = "cloudtrail"

    "projection.enabled"                  = "true"
    "projection.region.type"              = "injected"
    "projection.event_date.type"          = "date"
    "projection.event_date.format"        = "yyyy/MM/dd"
    "projection.event_date.interval"      = "1"
    "projection.event_date.interval.unit" = "DAYS"
    "projection.event_date.range"         = "${var.athena_cloudtrail_projection_start_date},NOW"

    "storage.location.template" = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.cloudtrail_s3_base_prefix}/$${region}/$${event_date}/"
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
    location      = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.cloudtrail_s3_base_prefix}/"
    input_format  = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    dynamic "columns" {
      for_each = local.cloudtrail_athena_columns

      content {
        name = columns.value.name
        type = columns.value.type
      }
    }

    ser_de_info {
      name                  = "cloudtrail-json-serde"
      serialization_library = "org.apache.hive.hcatalog.data.JsonSerDe"

      parameters = {
        "serialization.format" = "1"
      }
    }
  }
}


# =============================================================================
# Athena Workgroup - 결과 위치/암호화/쿼리 비용 제한 강제
# =============================================================================

resource "aws_athena_workgroup" "security_logs" {
  name        = local.athena_workgroup_name
  description = "CloudTrail 중앙 감사 로그 분석용 Workgroup"
  state       = "ENABLED"

  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # 한 쿼리가 최대 1 GiB까지만 스캔하도록 제한
    bytes_scanned_cutoff_per_query = 1073741824

    engine_version {
      selected_engine_version = "AUTO"
    }

    result_configuration {
      output_location       = "s3://${aws_s3_bucket.athena_results.id}/results/"
      expected_bucket_owner = data.aws_caller_identity.current.account_id

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = local.athena_tags

  depends_on = [
    aws_s3_bucket_policy.athena_results,
    aws_s3_bucket_server_side_encryption_configuration.athena_results,
    aws_s3_bucket_lifecycle_configuration.athena_results
  ]
}

# Grafana의 사람이 수행하는 통합 검색은 VPC Flow를 포함한 7개 소스를 조회하므로
# 매시간 실행되는 탐지 쿼리보다 스캔량이 크다. 탐지용 1 GiB 비용 상한을 완화하지
# 않고 수동 조사만 별도의 제한된 Workgroup에서 실행한다.
resource "aws_athena_workgroup" "security_investigation" {
  name        = local.athena_investigation_workgroup_name
  description = "Grafana SIEM manual investigation queries"
  state       = "ENABLED"

  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    bytes_scanned_cutoff_per_query = var.athena_investigation_bytes_scanned_cutoff

    engine_version {
      selected_engine_version = "AUTO"
    }

    result_configuration {
      output_location       = "s3://${aws_s3_bucket.athena_results.id}/results/"
      expected_bucket_owner = data.aws_caller_identity.current.account_id

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = merge(local.athena_tags, {
    Purpose = "manual-investigation"
  })

  depends_on = [
    aws_s3_bucket_policy.athena_results,
    aws_s3_bucket_server_side_encryption_configuration.athena_results,
    aws_s3_bucket_lifecycle_configuration.athena_results
  ]
}


# =============================================================================
# Athena 콘솔에서 바로 실행할 수 있는 저장 쿼리
# =============================================================================

resource "aws_athena_named_query" "recent_management_events" {
  name        = "01-recent-management-events"
  description = "최근 7일간 현재 Workload 리전의 관리 이벤트 100건"
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id

  query = <<-SQL
    SELECT
      eventtime,
      eventsource,
      eventname,
      COALESCE(useridentity.arn, useridentity.username, useridentity.principalid) AS actor,
      sourceipaddress,
      errorcode,
      errormessage
    FROM "${aws_glue_catalog_database.security_logs.name}"."${aws_glue_catalog_table.cloudtrail.name}"
    WHERE region = '${var.region}'
      AND event_date >= date_format(current_date - INTERVAL '7' DAY, '%Y/%m/%d')
    ORDER BY eventtime DESC
    LIMIT 100;
  SQL
}

resource "aws_athena_named_query" "failed_api_calls" {
  name        = "02-failed-api-calls"
  description = "최근 7일간 AccessDenied 등 실패한 AWS API 호출"
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id

  query = <<-SQL
    SELECT
      eventtime,
      eventsource,
      eventname,
      COALESCE(useridentity.arn, useridentity.username, useridentity.principalid) AS actor,
      sourceipaddress,
      errorcode,
      errormessage
    FROM "${aws_glue_catalog_database.security_logs.name}"."${aws_glue_catalog_table.cloudtrail.name}"
    WHERE region = '${var.region}'
      AND event_date >= date_format(current_date - INTERVAL '7' DAY, '%Y/%m/%d')
      AND errorcode IS NOT NULL
    ORDER BY eventtime DESC
    LIMIT 100;
  SQL
}

resource "aws_athena_named_query" "write_events" {
  name        = "03-write-events"
  description = "최근 7일간 리소스를 변경한 쓰기 관리 이벤트"
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id

  query = <<-SQL
    SELECT
      eventtime,
      eventsource,
      eventname,
      COALESCE(useridentity.arn, useridentity.username, useridentity.principalid) AS actor,
      sourceipaddress,
      requestparameters
    FROM "${aws_glue_catalog_database.security_logs.name}"."${aws_glue_catalog_table.cloudtrail.name}"
    WHERE region = '${var.region}'
      AND event_date >= date_format(current_date - INTERVAL '7' DAY, '%Y/%m/%d')
      AND readonly = 'false'
    ORDER BY eventtime DESC
    LIMIT 100;
  SQL
}

# =============================================================================
# Outputs
# =============================================================================

output "athena_security_database_name" {
  description = "CloudTrail 조회용 Glue/Athena 데이터베이스"
  value       = aws_glue_catalog_database.security_logs.name
}

output "athena_cloudtrail_table_name" {
  description = "CloudTrail 조회용 Athena 테이블"
  value       = aws_glue_catalog_table.cloudtrail.name
}

output "athena_security_workgroup_name" {
  description = "CloudTrail 조회용 Athena Workgroup"
  value       = aws_athena_workgroup.security_logs.name
}

output "athena_investigation_workgroup_name" {
  description = "Grafana SIEM 수동 조사용 Athena Workgroup"
  value       = aws_athena_workgroup.security_investigation.name
}

output "athena_query_results_bucket_name" {
  description = "Athena 쿼리 결과 S3 버킷"
  value       = aws_s3_bucket.athena_results.id
}
