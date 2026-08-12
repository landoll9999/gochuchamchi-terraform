variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "log_profile" {
  description = "Security/Log 계정 564186750363의 AWS CLI 프로파일"
  type        = string
  default     = "log-admin"
}

variable "management_account_id" {
  description = "Organization Trail을 소유하는 Management 계정 ID"
  type        = string
  default     = "307223751140"

  validation {
    condition     = var.management_account_id == "307223751140"
    error_message = "Management 계정 ID는 307223751140이어야 합니다."
  }
}

variable "workload_account_id" {
  description = "Workload 계정 ID. Flow Logs/구독 필터 발신자 인가와 Athena 경로에 사용"
  type        = string
  default     = "828885965304"

  validation {
    condition     = can(regex("^\\d{12}$", var.workload_account_id))
    error_message = "workload_account_id는 12자리 AWS 계정 ID여야 합니다."
  }
}

variable "cloudwatch_log_archive_retention_days" {
  description = "중앙 S3에 보관할 로그의 총 보존 기간"
  type        = number
  default     = 365

  validation {
    condition     = var.cloudwatch_log_archive_retention_days > 90
    error_message = "S3 아카이브 보존 기간은 Glacier 전환 시점보다 긴 91일 이상이어야 합니다."
  }
}

variable "log_archive_object_lock_days" {
  description = <<-EOT
    Object Lock COMPLIANCE 기본 보존 일수. 이 기간 동안은 루트를 포함한 누구도
    객체 버전을 삭제할 수 없다 (8/4 §5.5에서 실증). 구 버킷에서 "복원 보류"였던
    fin 라인 설계를 신규 버킷 생성 시점에 반영하는 것.
    수명주기 만료(retention_days)보다 짧아야 만료 정리가 정상 동작한다.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.log_archive_object_lock_days >= 1 && var.log_archive_object_lock_days < 90
    error_message = "Object Lock 보존 일수는 1~89일 범위여야 합니다 (Glacier 전환·만료보다 짧게)."
  }
}

variable "cloudwatch_log_archive_admin_arns" {
  description = "로그 버킷 불변성 Deny에서 예외로 둘 운영 주체 ARN 목록 (비우면 apply 실행 주체 — log-admin IAM user 기준)"
  type        = list(string)
  default     = []
}

variable "athena_cloudtrail_projection_start_date" {
  description = "Athena 파티션 프로젝션 시작일 (yyyy/MM/dd). 새 버킷에는 전환일 이후 로그만 있으므로 전환일로 잡는다"
  type        = string
  default     = "2026/08/10"

  validation {
    condition     = can(regex("^\\d{4}/(0[1-9]|1[0-2])/(0[1-9]|[12]\\d|3[01])$", var.athena_cloudtrail_projection_start_date))
    error_message = "Athena 파티션 시작일은 yyyy/MM/dd 형식이어야 합니다."
  }
}

variable "athena_alb_projection_start_date" {
  description = "ALB 액세스 로그 Athena 파티션 프로젝션 시작일(yyyy/MM/dd)"
  type        = string
  default     = "2026/08/12"

  validation {
    condition     = can(regex("^\\d{4}/(0[1-9]|1[0-2])/(0[1-9]|[12]\\d|3[01])$", var.athena_alb_projection_start_date))
    error_message = "ALB Athena 파티션 시작일은 yyyy/MM/dd 형식이어야 합니다."
  }
}
