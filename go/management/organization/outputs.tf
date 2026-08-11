output "organization_id" {
  value       = aws_organizations_organization.this.id
  description = "Security/Log 버킷 정책에 전달할 Organization ID"
}

output "organization_root_id" {
  value       = aws_organizations_organization.this.roots[0].id
  description = "Organizations Root ID"
}

output "security_ou_id" {
  value       = aws_organizations_organizational_unit.security.id
  description = "Security/Log 계정을 수동으로 이동할 OU"
}

output "workloads_ou_id" {
  value       = aws_organizations_organizational_unit.workloads.id
  description = "Workload 계정을 수동으로 이동할 OU"
}

output "account_map" {
  value = {
    management  = var.management_account_id
    log_archive = var.log_archive_account_id
    workload    = var.workload_account_id
  }
}

# Security/Log 계정 담당자에게 넘기는 인계 지점.
# 이 값이 채워지면 Log 계정에서 조직 단위 GuardDuty·Security Hub 설정을 시작할 수 있다.
output "security_services_delegated_admin" {
  value = var.enable_security_services_delegation ? {
    account_id  = var.log_archive_account_id
    region      = var.region
    guardduty   = one(aws_guardduty_organization_admin_account.log_archive[*].admin_account_id)
    securityhub = one(aws_securityhub_organization_admin_account.log_archive[*].admin_account_id)
  } : null
  description = "GuardDuty·Security Hub 위임 관리자로 지정된 계정과 리전. 미지정 시 null"
}

output "management_guardduty_detector_id" {
  value       = one(aws_guardduty_detector.management[*].id)
  description = "Management 계정 자체 탐지기 ID. Log 계정에서 멤버로 관리할 때 참조"
}
