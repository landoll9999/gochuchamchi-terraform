variable "aws_profile" {
  description = "AWS CLI 프로필 (../terraform/variables.tf와 같은 값)"
  type        = string
  default     = "workload-admin"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "github_owner" {
  description = "CI 워크플로가 있는 GitHub 계정/조직 (../terraform의 argocd_github_owner와 같은 값)"
  type        = string
  default     = "landoll9999"
}

variable "image_signing_github_environment" {
  description = "서명 잡만 assume할 수 있는 보호된 GitHub Environment 이름 (../terraform과 같은 값)"
  type        = string
  default     = "production-signing"
}

variable "cdn_log_retention_days" {
  description = "CloudFront 액세스 로그 S3 보존 기간 (../terraform/edge-logs-variables.tf에서 함께 옮겨옴)"
  type        = number
  default     = 365

  validation {
    condition     = var.cdn_log_retention_days > 90
    error_message = "cdn_log_retention_days must be greater than 90 because logs transition to Glacier on day 90."
  }
}
