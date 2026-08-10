resource "aws_organizations_policy" "deny_leave_organization" {
  name        = "DenyLeaveOrganization"
  description = "멤버 계정의 root를 포함한 모든 주체가 조직을 이탈하지 못하게 차단"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "DenyLeaveOrganization"
      Effect   = "Deny"
      Action   = ["organizations:LeaveOrganization"]
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_security" {
  policy_id = aws_organizations_policy.deny_leave_organization.id
  target_id = aws_organizations_organizational_unit.security.id
}

resource "aws_organizations_policy_attachment" "deny_leave_workloads" {
  policy_id = aws_organizations_policy.deny_leave_organization.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy" "deny_workload_audit_tampering" {
  name        = "DenyWorkloadAuditTampering"
  description = "Workload 계정에서 조직 감사·보안 서비스 중단을 차단"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyAuditTampering"
      Effect = "Deny"
      Action = [
        "cloudtrail:DeleteTrail",
        "cloudtrail:StopLogging",
        "cloudtrail:UpdateTrail",
        "config:DeleteConfigurationRecorder",
        "config:DeleteDeliveryChannel",
        "config:StopConfigurationRecorder",
        "guardduty:DeleteDetector",
        "guardduty:DisassociateFromAdministratorAccount",
        "securityhub:DisableSecurityHub",
        "securityhub:DisassociateFromAdministratorAccount",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_organizations_policy_attachment" "deny_workload_audit_tampering" {
  policy_id = aws_organizations_policy.deny_workload_audit_tampering.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy" "protect_log_archive" {
  name        = "ProtectLogArchive"
  description = "중앙 로그 버킷·Object Lock·KMS 파괴를 차단"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyCentralLogBucketDestruction"
        Effect = "Deny"
        Action = [
          "s3:DeleteBucket",
          "s3:DeleteBucketPolicy",
          "s3:PutBucketPolicy",
          "s3:PutBucketObjectLockConfiguration",
          "s3:DeleteObject",
          "s3:DeleteObjectVersion",
        ]
        Resource = [
          format("arn:aws:s3:::gochuchamchi-log-archive-%s", var.log_archive_account_id),
          format("arn:aws:s3:::gochuchamchi-log-archive-%s/*", var.log_archive_account_id),
        ]
      },
      {
        Sid    = "DenyLogKmsDestruction"
        Effect = "Deny"
        Action = [
          "kms:DisableKey",
          "kms:PutKeyPolicy",
          "kms:ScheduleKeyDeletion",
        ]
        Resource = format("arn:aws:kms:*:%s:key/*", var.log_archive_account_id)
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "protect_log_archive" {
  count = var.enable_log_archive_protection_scp ? 1 : 0

  policy_id = aws_organizations_policy.protect_log_archive.id
  target_id = aws_organizations_organizational_unit.security.id
}
