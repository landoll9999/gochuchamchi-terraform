variable "enable_foundational_security_best_practices" {
  description = "AWS Foundational Security Best Practices v1.0.0 활성화 여부"
  type        = bool
  default     = true
}

variable "enable_cis_aws_foundations_benchmark_v3" {
  description = "CIS AWS Foundations Benchmark v3.0.0 추가 활성화 여부"
  type        = bool
  default     = false
}

variable "auto_enable_new_controls" {
  description = "활성화된 표준에 AWS가 새 Control을 추가할 때 자동 활성화할지 여부"
  type        = bool
  default     = true
}

variable "disabled_control_ids" {
  description = "DISABLED로 설정할 FSBP Control ID 목록(이 프로젝트에서 미사용인 서비스). securityhub-* Config 규칙·ResourceCompliance CI·finding 비용을 줄인다."
  type        = list(string)
  default     = []
}