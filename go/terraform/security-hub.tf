# =============================================================================
# Security Hub CSPM
#
# AWS Config가 기록한 리소스 구성을 근거로 보안 표준(Control)을 평가합니다.
# AWS 기본 표준 자동 활성화는 끄고, 활성화할 표준을 코드로 명시해서 관리합니다.
#
# 주의: Security Hub는 module.aws_config가 Recorder를 켠 뒤에 활성화되어야
#       Control 평가가 정상적으로 시작됩니다(아래 depends_on).
# =============================================================================

module "security_hub" {
  source = "./module/security-hub"

  # AWS Foundational Security Best Practices - 기본 활성화
  enable_foundational_security_best_practices = true

  # CIS AWS Foundations Benchmark v3.0.0 - 점검 항목/비용이 늘어나므로 선택
  enable_cis_aws_foundations_benchmark_v3 = var.security_hub_enable_cis_benchmark_v3

  # AWS가 표준에 새 Control을 추가하면 자동으로 켬
  auto_enable_new_controls = true

  depends_on = [
    module.aws_config
  ]
}
