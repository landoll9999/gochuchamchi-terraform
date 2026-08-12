# =============================================================================
# Workload ALB access logs -> dedicated immutable S3 bucket in the Log account
#
# ALB access-log delivery supports SSE-S3 only. It therefore cannot write to
# the central KMS-encrypted CloudTrail/Firehose bucket. This dedicated bucket
# stays in the Log account and uses Object Lock COMPLIANCE + versioning.
# =============================================================================

locals {
  alb_access_log_bucket_name = "gochuchamchi-alb-access-logs-${data.aws_caller_identity.current.account_id}"
  alb_access_log_prefix      = "alb"
  athena_alb_table_name      = "alb_access_logs"

  alb_access_log_columns = [
    { name = "type", type = "string" },
    { name = "time", type = "string" },
    { name = "elb", type = "string" },
    { name = "client_ip", type = "string" },
    { name = "client_port", type = "int" },
    { name = "target_ip", type = "string" },
    { name = "target_port", type = "int" },
    { name = "request_processing_time", type = "double" },
    { name = "target_processing_time", type = "double" },
    { name = "response_processing_time", type = "double" },
    { name = "elb_status_code", type = "int" },
    { name = "target_status_code", type = "string" },
    { name = "received_bytes", type = "bigint" },
    { name = "sent_bytes", type = "bigint" },
    { name = "request_verb", type = "string" },
    { name = "request_url", type = "string" },
    { name = "request_proto", type = "string" },
    { name = "user_agent", type = "string" },
    { name = "ssl_cipher", type = "string" },
    { name = "ssl_protocol", type = "string" },
    { name = "target_group_arn", type = "string" },
    { name = "trace_id", type = "string" },
    { name = "domain_name", type = "string" },
    { name = "chosen_cert_arn", type = "string" },
    { name = "matched_rule_priority", type = "string" },
    { name = "request_creation_time", type = "string" },
    { name = "actions_executed", type = "string" },
    { name = "redirect_url", type = "string" },
    { name = "lambda_error_reason", type = "string" },
    { name = "target_port_list", type = "string" },
    { name = "target_status_code_list", type = "string" },
    { name = "classification", type = "string" },
    { name = "classification_reason", type = "string" },
    { name = "conn_trace_id", type = "string" }
  ]

  # AWS Athena official ALB access-log RegexSerDe pattern. Keep the optional
  # trailing group so future ALB fields do not make every column NULL.
  alb_access_log_regex = trimspace(<<-REGEX
    ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*)[:-]([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-.0-9]*) (|[-0-9]*) (-|[-0-9]*) ([-0-9]*) ([-0-9]*) "([^ ]*) (.*) (- |[^ ]*)" "([^"]*)" ([A-Z0-9-_]+) ([A-Za-z0-9.-]*) ([^ ]*) "([^"]*)" "([^"]*)" "([^"]*)" ([-.0-9]*) ([^ ]*) "([^"]*)" "([^"]*)" "([^ ]*)" "([^\s]+?)" "([^\s]+)" "([^ ]*)" "([^ ]*)" ?([^ ]*)? ?( .*)?
  REGEX
  )
}

resource "aws_s3_bucket" "alb_access_logs" {
  bucket              = local.alb_access_log_bucket_name
  object_lock_enabled = true
  force_destroy       = false

  tags = merge(local.cloudwatch_log_archive_tags, {
    Name      = "gochuchamchi-alb-access-logs"
    Component = "alb-access-logs"
  })
}

resource "aws_s3_bucket_ownership_controls" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.log_archive_object_lock_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.alb_access_logs]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    id     = "archive-alb-access-logs"
    status = "Enabled"

    filter {
      prefix = "${local.alb_access_log_prefix}/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.cloudwatch_log_archive_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  depends_on = [aws_s3_bucket_versioning.alb_access_logs]
}

data "aws_iam_policy_document" "alb_access_logs_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alb_access_logs.arn,
      "${aws_s3_bucket.alb_access_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AllowWorkloadAlbLogDelivery"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }

    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.alb_access_logs.arn}/${local.alb_access_log_prefix}/AWSLogs/${local.workload_account_id}/*"
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgId"
      values   = [local.org_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:elasticloadbalancing:${var.region}:${local.workload_account_id}:loadbalancer/*"]
    }
  }
}

resource "aws_s3_bucket_policy" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id
  policy = data.aws_iam_policy_document.alb_access_logs_bucket.json

  depends_on = [
    aws_s3_bucket_ownership_controls.alb_access_logs,
    aws_s3_bucket_public_access_block.alb_access_logs
  ]
}

resource "aws_glue_catalog_table" "alb_access_logs" {
  name          = local.athena_alb_table_name
  database_name = aws_glue_catalog_database.security_logs.name
  description   = "Workload account ALB access logs stored in the Log account"
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    EXTERNAL = "TRUE"

    "projection.enabled"           = "true"
    "projection.day.type"          = "date"
    "projection.day.range"         = "${var.athena_alb_projection_start_date},NOW"
    "projection.day.format"        = "yyyy/MM/dd"
    "projection.day.interval"      = "1"
    "projection.day.interval.unit" = "DAYS"

    "storage.location.template" = "s3://${aws_s3_bucket.alb_access_logs.id}/${local.alb_access_log_prefix}/AWSLogs/${local.workload_account_id}/elasticloadbalancing/${var.region}/$${day}/"
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.alb_access_logs.id}/${local.alb_access_log_prefix}/AWSLogs/${local.workload_account_id}/elasticloadbalancing/${var.region}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    dynamic "columns" {
      for_each = local.alb_access_log_columns

      content {
        name = columns.value.name
        type = columns.value.type
      }
    }

    ser_de_info {
      name                  = "alb-access-log-regex-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"

      parameters = {
        "serialization.format" = "1"
        "input.regex"          = local.alb_access_log_regex
      }
    }
  }

  depends_on = [aws_s3_bucket_policy.alb_access_logs]
}

locals {
  alb_access_log_named_queries = {
    "14-alb-status-codes-24h" = {
      description = "최근 24시간 ALB와 Target 상태 코드별 요청 수"
      query       = <<-SQL
        SELECT
          elb_status_code,
          target_status_code,
          COUNT(*) AS request_count
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_alb_table_name}"
        WHERE day >= date_format(current_timestamp - INTERVAL '1' DAY, '%Y/%m/%d')
          AND try(from_iso8601_timestamp(time)) >= current_timestamp - INTERVAL '24' HOUR
        GROUP BY elb_status_code, target_status_code
        ORDER BY request_count DESC;
      SQL
    }

    "15-alb-error-request-details" = {
      description = "최근 24시간 ALB 4xx/5xx 요청 상세와 처리 지연"
      query       = <<-SQL
        SELECT
          time,
          client_ip,
          request_verb,
          request_url,
          elb_status_code,
          target_status_code,
          request_processing_time,
          target_processing_time,
          response_processing_time,
          user_agent,
          trace_id,
          classification,
          classification_reason
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_alb_table_name}"
        WHERE day >= date_format(current_timestamp - INTERVAL '1' DAY, '%Y/%m/%d')
          AND try(from_iso8601_timestamp(time)) >= current_timestamp - INTERVAL '24' HOUR
          AND (elb_status_code >= 400 OR try_cast(target_status_code AS integer) >= 400)
        ORDER BY time DESC
        LIMIT 500;
      SQL
    }
  }
}

resource "aws_athena_named_query" "alb_access_logs" {
  for_each = local.alb_access_log_named_queries

  name        = each.key
  description = each.value.description
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id
  query       = each.value.query

  depends_on = [aws_glue_catalog_table.alb_access_logs]
}

output "alb_access_log_bucket_name" {
  description = "Workload ALB가 액세스 로그를 전달할 Log 계정 S3 버킷"
  value       = aws_s3_bucket.alb_access_logs.id
}

output "athena_alb_access_log_table_name" {
  description = "ALB 액세스 로그 Athena 테이블"
  value       = aws_glue_catalog_table.alb_access_logs.name
}
