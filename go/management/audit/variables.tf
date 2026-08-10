variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "Management 계정 전용 AWS CLI 프로파일"
  type        = string
  default     = "management-admin"
}

variable "management_account_id" {
  type    = string
  default = "307223751140"
}

variable "log_archive_account_id" {
  type    = string
  default = "564186750363"
}

variable "workload_account_id" {
  type    = string
  default = "828885965304"
}

variable "cloudtrail_name" {
  type    = string
  default = "gochuchamchi-org-trail"
}

variable "cloudtrail_s3_key_prefix" {
  type    = string
  default = "cloudtrail"
}

variable "log_archive_bucket_name" {
  description = "Security/Log 계정의 Object Lock 중앙 로그 버킷"
  type        = string
  default     = "gochuchamchi-log-archive-564186750363"
}

variable "log_archive_kms_key_arn" {
  description = "log-archive apply 출력 kms_logs_key_arn. null이면 버킷 기본 SSE-KMS를 사용"
  type        = string
  default     = null
  nullable    = true
}
