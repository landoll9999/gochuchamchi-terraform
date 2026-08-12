variable "region" {
  description = "Organizations와 IAM Identity Center를 관리할 기본 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "Management 계정 전용 AWS CLI 프로파일"
  type        = string
  default     = "management-admin"
}

variable "management_account_id" {
  description = "AWS Organizations Management 계정"
  type        = string
  default     = "307223751140"

  validation {
    condition     = var.management_account_id == "307223751140"
    error_message = "이 구성의 Management 계정은 307223751140이어야 합니다."
  }
}

variable "log_archive_account_id" {
  description = "Security/Log 멤버 계정"
  type        = string
  default     = "564186750363"

  validation {
    condition     = var.log_archive_account_id == "564186750363"
    error_message = "이 구성의 Security/Log 계정은 564186750363이어야 합니다."
  }
}

variable "workload_account_id" {
  description = "Workload 멤버 계정"
  type        = string
  default     = "828885965304"

  validation {
    condition     = var.workload_account_id == "828885965304"
    error_message = "이 구성의 Workload 계정은 828885965304여야 합니다."
  }
}

variable "enable_identity_center_configuration" {
  description = "Management 콘솔에서 IAM Identity Center를 활성화한 뒤 true로 변경"
  type        = bool
  default     = false
}

variable "enable_log_archive_protection_scp" {
  description = "Log 버킷과 KMS 생성·검증을 마친 뒤 true로 변경해 파괴 방지 SCP를 잠금"
  type        = bool
  default     = false
}

variable "enable_security_services_delegation" {
  description = "Security/Log 계정을 GuardDuty·Security Hub 위임 관리자로 지정. Log 계정이 조직 설정을 받을 준비가 된 뒤 true로 변경"
  type        = bool
  default     = false
}
