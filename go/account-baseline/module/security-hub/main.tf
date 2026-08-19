data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  foundational_standard_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  cis_v3_standard_arn       = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.region}::standards/cis-aws-foundations-benchmark/v/3.0.0"

  enabled_standards = merge(
    var.enable_foundational_security_best_practices ? {
      foundational = local.foundational_standard_arn
    } : {},
    var.enable_cis_aws_foundations_benchmark_v3 ? {
      cis_v3 = local.cis_v3_standard_arn
    } : {}
  )
}

# Security Hub CSPM 활성화
# 기본 표준은 자동 활성화하지 않고 아래 구독 리소스로 명시적으로 관리합니다.

resource "aws_securityhub_account" "this" {
  enable_default_standards  = false
  auto_enable_controls      = var.auto_enable_new_controls
  control_finding_generator = "SECURITY_CONTROL"
}

# AWS Foundational Security Best Practices를 기본으로 활성화하고,
# CIS AWS Foundations Benchmark v3.0.0은 필요할 때만 선택적으로 활성화합니다.

resource "aws_securityhub_standards_subscription" "this" {
  for_each = local.enabled_standards

  standards_arn = each.value

  depends_on = [
    aws_securityhub_account.this
  ]

  timeouts {
    create = "10m"
    delete = "10m"
  }
}

data "aws_caller_identity" "current" {}

# 이 프로젝트에서 쓰지 않는 서비스의 FSBP Control을 DISABLED 처리한다.
# 표준 구독으로 Control이 생성된 뒤에 상태만 바꾸므로 subscription에 의존한다.
# 리소스가 없어 판정 노이즈와 securityhub-* Config 규칙·CI·finding 비용만
# 만들던 Control을 꺼서 비용을 줄인다.
resource "aws_securityhub_standards_control" "disabled" {
  for_each = toset(var.disabled_control_ids)

  standards_control_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:control/aws-foundational-security-best-practices/v/1.0.0/${each.value}"

  control_status  = "DISABLED"
  disabled_reason = "Service not used in this project; disabled to reduce Config CI and Security Hub finding cost."

  depends_on = [
    aws_securityhub_standards_subscription.this
  ]
}