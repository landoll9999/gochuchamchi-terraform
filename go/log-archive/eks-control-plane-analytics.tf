# =============================================================================
# Athena — centralized EKS control-plane logs
#
# control-plane 로그(api / audit / authenticator 3종)는 workload 계정에서 이 중앙
# 버킷의 cloudwatch/control-plane/ 로 배송된다(log-archive.tf Firehose). Firehose가
# DataMessageExtraction 으로 각 로그 라인만 뽑으므로, 여기 저장되는 것은 CloudWatch
# 래핑이 벗겨진 원문 한 줄이다. 원문 형식은 로그 종류마다 다르다:
#   - kube-apiserver-audit : K8s audit event JSON   ← 탐지가 쓰는 것
#   - kube-apiserver       : 평문 로그
#   - authenticator        : 평문/JSON 혼재
# 그래서 rds-audit 과 같이 message 한 컬럼 원문 테이블로 두고, 정규화 뷰
# (security-events-view.tf 의 eks 분기)와 아래 룰이 kind='Event' 인 audit JSON 만
# 골라 json_extract 로 파싱한다. 타입 파서를 테이블에 박지 않는 이유가 이 혼재다.
# =============================================================================

locals {
  athena_eks_control_plane_table_name = "eks_control_plane_logs"
  eks_control_plane_s3_prefix         = "cloudwatch/control-plane"

  eks_control_plane_recent_partition = <<-SQL
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

  eks_control_plane_named_queries = {
    "21-eks-audit-pod-exec-24h" = {
      description = "최근 24시간 kubectl exec/attach into pod (컨테이너 셸 접근)"
      query       = <<-SQL
        SELECT year, month, day, hour,
          json_extract_scalar(message, '$.user.username')        AS username,
          json_extract_scalar(message, '$.objectRef.namespace')  AS namespace,
          json_extract_scalar(message, '$.objectRef.name')       AS pod,
          json_extract_scalar(message, '$.objectRef.subresource') AS subresource,
          json_extract_scalar(message, '$.responseStatus.code')  AS code
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_eks_control_plane_table_name}"
        WHERE ${local.eks_control_plane_recent_partition}
          AND try(json_extract_scalar(message, '$.kind')) = 'Event'
          AND json_extract_scalar(message, '$.verb') = 'create'
          AND json_extract_scalar(message, '$.objectRef.subresource') IN ('exec', 'attach')
        LIMIT 500;
      SQL
    }

    "22-eks-audit-secret-access-24h" = {
      description = "최근 24시간 Secret 조회(get/list/watch) — 주체별 집계"
      query       = <<-SQL
        SELECT
          json_extract_scalar(message, '$.user.username')       AS username,
          json_extract_scalar(message, '$.objectRef.namespace') AS namespace,
          json_extract_scalar(message, '$.verb')                AS verb,
          count(*)                                              AS reads
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_eks_control_plane_table_name}"
        WHERE ${local.eks_control_plane_recent_partition}
          AND try(json_extract_scalar(message, '$.kind')) = 'Event'
          AND json_extract_scalar(message, '$.objectRef.resource') = 'secrets'
          AND json_extract_scalar(message, '$.verb') IN ('get', 'list', 'watch')
        GROUP BY 1, 2, 3
        ORDER BY reads DESC
        LIMIT 500;
      SQL
    }

    "23-eks-audit-forbidden-24h" = {
      description = "최근 24시간 인가 거부(HTTP 403) — 권한 탐색 흔적"
      query       = <<-SQL
        SELECT year, month, day, hour,
          json_extract_scalar(message, '$.user.username') AS username,
          json_extract_scalar(message, '$.verb')          AS verb,
          json_extract_scalar(message, '$.objectRef.resource') AS resource,
          json_extract_scalar(message, '$.requestURI')    AS uri
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_eks_control_plane_table_name}"
        WHERE ${local.eks_control_plane_recent_partition}
          AND try(json_extract_scalar(message, '$.kind')) = 'Event'
          AND json_extract_scalar(message, '$.responseStatus.code') = '403'
        LIMIT 500;
      SQL
    }

    "24-eks-audit-rbac-change-24h" = {
      description = "최근 24시간 RBAC 변경(role/binding create/update/delete)"
      query       = <<-SQL
        SELECT year, month, day, hour,
          json_extract_scalar(message, '$.user.username')      AS username,
          json_extract_scalar(message, '$.verb')               AS verb,
          json_extract_scalar(message, '$.objectRef.resource') AS resource,
          json_extract_scalar(message, '$.objectRef.name')     AS name
        FROM "${aws_glue_catalog_database.security_logs.name}"."${local.athena_eks_control_plane_table_name}"
        WHERE ${local.eks_control_plane_recent_partition}
          AND try(json_extract_scalar(message, '$.kind')) = 'Event'
          AND json_extract_scalar(message, '$.objectRef.resource') IN ('roles', 'clusterroles', 'rolebindings', 'clusterrolebindings')
          AND json_extract_scalar(message, '$.verb') IN ('create', 'update', 'patch', 'delete')
        LIMIT 500;
      SQL
    }
  }
}

resource "aws_glue_catalog_table" "eks_control_plane_logs" {
  name          = local.athena_eks_control_plane_table_name
  database_name = aws_glue_catalog_database.security_logs.name
  description   = "Raw immutable EKS control-plane log lines (audit/api/authenticator) from the Workload account"
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

    "storage.location.template" = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.eks_control_plane_s3_prefix}/year=$${year}/month=$${month}/day=$${day}/hour=$${hour}/"
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
    location      = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.eks_control_plane_s3_prefix}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"
    compressed    = true

    columns {
      name = "message"
      type = "string"
    }

    ser_de_info {
      name                  = "eks-control-plane-raw-message-serde"
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"

      parameters = {
        "input.regex" = "^(.*)$"
      }
    }
  }
}

resource "aws_athena_named_query" "eks_control_plane" {
  for_each = local.eks_control_plane_named_queries

  name        = each.key
  description = each.value.description
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id
  query       = each.value.query

  depends_on = [aws_glue_catalog_table.eks_control_plane_logs]
}

output "athena_eks_control_plane_table_name" {
  description = "EKS 제어평면 로그 Athena 원문 테이블"
  value       = aws_glue_catalog_table.eks_control_plane_logs.name
}

output "eks_control_plane_logs_s3_location" {
  description = "중앙 EKS 제어평면 로그 S3 위치"
  value       = "s3://${aws_s3_bucket.cloudwatch_log_archive.id}/${local.eks_control_plane_s3_prefix}/"
}
