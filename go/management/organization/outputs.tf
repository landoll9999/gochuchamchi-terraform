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
