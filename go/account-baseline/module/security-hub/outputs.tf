output "security_hub_arn" {
  description = "현재 리전 Security Hub ARN"
  value       = aws_securityhub_account.this.arn
}

output "enabled_standard_arns" {
  description = "명시적으로 활성화한 Security Hub 표준 ARN"
  value       = local.enabled_standards
}

output "standard_subscription_arns" {
  description = "Security Hub 표준 구독 ARN"
  value = {
    for name, subscription in aws_securityhub_standards_subscription.this :
    name => subscription.arn
  }
}

output "control_finding_generator" {
  description = "Security Hub Control Finding 생성 방식"
  value       = aws_securityhub_account.this.control_finding_generator
}