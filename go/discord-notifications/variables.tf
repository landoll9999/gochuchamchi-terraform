variable "aws_profile" {
  description = "AWS CLI profile (../terraform/variables.tf와 동일 값 사용)"
  type        = string
  default     = "admin"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "cluster_name" {
  description = "이미 떠 있어야 하는 EKS 클러스터 이름 (../terraform 디렉토리를 먼저 apply한 뒤 이 모듈을 적용)"
  type        = string
  default     = "gochuchamchi-eks"
}

variable "discord_webhook_url" {
  description = "Discord 채널 웹훅 URL (채널 설정 > 연동 > 웹훅 만들기에서 발급). TF_VAR_discord_webhook_url 환경변수로 주입 — git에 커밋 금지."
  type        = string
  sensitive   = true
}
