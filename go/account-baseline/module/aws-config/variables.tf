variable "name_prefix" {
  description = "AWS Config 리소스 이름에 사용할 접두사"
  type        = string
  default     = "gochuchamchi"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.name_prefix)) && length(var.name_prefix) <= 45
    error_message = "name_prefix는 영문자, 숫자, 하이픈만 사용할 수 있으며 45자 이하여야 합니다."
  }
}

variable "s3_bucket_name" {
  description = "AWS Config 이력과 스냅샷을 저장할 기존 S3 버킷 이름"
  type        = string

  validation {
    condition     = length(trimspace(var.s3_bucket_name)) > 0
    error_message = "s3_bucket_name은 비어 있을 수 없습니다."
  }
}

variable "s3_bucket_arn" {
  description = "AWS Config 이력과 스냅샷을 저장할 기존 S3 버킷 ARN"
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:s3:::[^/]+$", var.s3_bucket_arn))
    error_message = "s3_bucket_arn은 arn:aws:s3:::bucket-name 형식이어야 합니다."
  }
}

variable "s3_key_prefix" {
  description = "중앙 로그 버킷 안에서 AWS Config가 사용할 경로 접두사"
  type        = string
  default     = "config"
}

variable "include_global_resource_types" {
  description = "IAM 사용자, 그룹, 역할, 정책 등 글로벌 리소스 기록 여부"
  type        = bool
  default     = true
}

variable "snapshot_delivery_frequency" {
  description = "AWS Config 전체 스냅샷 전달 주기"
  type        = string
  default     = "Six_Hours"

  validation {
    condition = contains([
      "One_Hour",
      "Three_Hours",
      "Six_Hours",
      "Twelve_Hours",
      "TwentyFour_Hours"
    ], var.snapshot_delivery_frequency)
    error_message = "snapshot_delivery_frequency는 AWS Config가 지원하는 전달 주기여야 합니다."
  }
}

variable "tags" {
  description = "AWS Config IAM Role에 추가할 공통 태그"
  type        = map(string)
  default     = {}
}

variable "kms_key_arn" {
  description = "대상 버킷의 기본 암호화 CMK ARN. 지정하면 delivery channel에 명시하고 Config 역할에 해당 키 사용 권한을 부여한다 (CMK 강제 암호화 버킷에서 필수 — 2026-08-03 InsufficientDeliveryPolicyException 원인)"
  type        = string
  default     = null
}