# =============================================================================
# state 이관용 임시 파일 — 2026-08-07
#
# 아래 리소스들은 ../account-baseline 계층으로 옮겼다. 실물 AWS 리소스는 그대로
# 두고 이 state의 관리 대상에서만 뺀다.
#
# 왜 `terraform state mv`가 아니라 `removed` 블록인가 —
#   state mv는 S3 백엔드에서 state를 로컬로 뺐다가 다시 push해야 해서, 3인 협업
#   환경에서 state가 갈라질 여지가 있다. removed 블록은 코드로 남고 plan에서
#   검토되며, lifecycle { destroy = false } 때문에 구조적으로 destroy가 불가능하다.
#
#   이 점이 특히 중요한 대상이 셋 있다:
#     aws_inspector2_enabler          destroy가 15분 타임아웃 후 tainted로 남는다 (8/4 §5.2)
#     module.aws_config               레코더 삭제/재생성이 구성 항목 수천 건을 다시 기록한다
#     aws_s3_bucket.cloudwatch_log_archive  Object Lock COMPLIANCE라 애초에 못 지운다 (8/4 §5.5)
#
# 사용 순서 — 반드시 이 순서대로:
#   0) ..\scripts\generate-baseline-imports.ps1   <- 이 apply "전에" 돌릴 것.
#      apply한 뒤에는 state에 리소스가 없어 import ID를 못 뽑는다.
#   1) cd ../account-baseline && terraform init && terraform plan
#      -> "N to import", create/destroy 0건 확인.  여기서 틀리면 아직 피해가 없다.
#   2) 여기로 돌아와 terraform plan -> "N resources to forget", destroy 0건 확인 후 apply
#   3) cd ../account-baseline && terraform apply
#   4) 양쪽 확인 후 이 파일과 baseline의 imports.tf 를 삭제하고 커밋
#
# 2)와 3) 사이에는 리소스가 어느 state에도 없다. 하지만 메인 쪽 코드가 이미 지워져
# 있으므로 재생성을 시도하지 않는다 — 고아 상태로 남을 뿐이고 다시 import하면 된다.
#
# 주의: 4)까지 끝나기 전에는 이 저장소에 다른 apply를 돌리지 말 것.
# =============================================================================

# --- athena.tf ---------------------------------------------------------

removed {
  from = aws_s3_bucket.athena_results

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_ownership_controls.athena_results

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_public_access_block.athena_results

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_server_side_encryption_configuration.athena_results

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_lifecycle_configuration.athena_results

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_policy.athena_results

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_glue_catalog_database.security_logs

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_glue_catalog_table.cloudtrail

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_workgroup.security_logs

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_named_query.recent_management_events

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_named_query.failed_api_calls

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_named_query.write_events

  lifecycle {
    destroy = false
  }
}

# --- aws-config.tf -----------------------------------------------------

removed {
  from = aws_s3_bucket.aws_config

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_public_access_block.aws_config

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_server_side_encryption_configuration.aws_config

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_lifecycle_configuration.aws_config

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_policy.aws_config

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.aws_config

  lifecycle {
    destroy = false
  }
}

# --- cloudtrail.tf -----------------------------------------------------

removed {
  from = aws_cloudtrail.central

  lifecycle {
    destroy = false
  }
}

# --- cost-monitoring.tf ------------------------------------------------

removed {
  from = aws_budgets_budget.monthly

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ce_anomaly_monitor.services

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ce_anomaly_subscription.email

  lifecycle {
    destroy = false
  }
}

# --- ecr-scanning.tf ---------------------------------------------------

removed {
  from = aws_inspector2_enabler.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_ecr_registry_scanning_configuration.this

  lifecycle {
    destroy = false
  }
}

# --- flow-logs-analytics.tf --------------------------------------------

removed {
  from = aws_glue_catalog_table.vpc_flow_logs

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_named_query.flowlogs

  lifecycle {
    destroy = false
  }
}

# --- guardduty.tf ------------------------------------------------------

removed {
  from = aws_guardduty_detector.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_guardduty_detector_feature.eks_audit_logs

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_guardduty_detector_feature.s3_data_events

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_guardduty_detector_feature.ebs_malware

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_guardduty_detector_feature.runtime_monitoring

  lifecycle {
    destroy = false
  }
}

# --- iam-security.tf ---------------------------------------------------

removed {
  from = aws_accessanalyzer_analyzer.account

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_group.console_admins

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_group_policy.force_mfa

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_group_policy_attachment.console_admins_admin

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_group_membership.console_admins

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.region_guard

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_group_policy_attachment.console_admins_region_guard

  lifecycle {
    destroy = false
  }
}

# --- kms-logs.tf -------------------------------------------------------

removed {
  from = aws_kms_key.logs

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_kms_alias.logs

  lifecycle {
    destroy = false
  }
}

# --- log-archive.tf ----------------------------------------------------

removed {
  from = aws_s3_bucket.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_ownership_controls.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_public_access_block.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_versioning.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_server_side_encryption_configuration.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_lifecycle_configuration.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_bucket_policy.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.cloudwatch_log_archive_firehose

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_stream.cloudwatch_log_archive_firehose

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.cloudwatch_log_archive_firehose

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.cloudwatch_log_archive_firehose

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.cloudwatch_logs_to_firehose

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.cloudwatch_logs_to_firehose

  lifecycle {
    destroy = false
  }
}

# --- security-hub.tf ---------------------------------------------------

removed {
  from = module.security_hub

  lifecycle {
    destroy = false
  }
}

