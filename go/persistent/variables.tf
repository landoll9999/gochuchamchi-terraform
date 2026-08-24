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

variable "github_ecr_build_allowed_refs" {
  description = "ECR 빌드 역할을 assume할 수 있는 gochuchamchi-spring 브랜치 ref. 임시 브랜치는 배포 완료 후 제거한다."
  type        = list(string)
  default = [
    "refs/heads/main",
    "refs/heads/feat/web-admin-split-20260824",
  ]

  validation {
    condition = length(var.github_ecr_build_allowed_refs) > 0 && alltrue([
      for ref in var.github_ecr_build_allowed_refs : startswith(ref, "refs/heads/") && !strcontains(ref, "*")
    ])
    error_message = "github_ecr_build_allowed_refs에는 와일드카드 없는 refs/heads/<branch> 형식만 사용할 수 있습니다."
  }
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
