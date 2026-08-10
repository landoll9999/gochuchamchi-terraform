# =============================================================================
# ../terraform/variables.tf 에서 이 계층이 쓰는 것만 가져왔다.
# 두 계층이 같은 이름의 변수를 각자 갖는 형태가 되지만, 값이 갈릴 여지가 있는
# 것은 region/aws_profile 둘뿐이고 둘 다 default가 고정이라 실무상 문제가 없다.
# 대신 tfvars를 공유하지 않는다 — 계층별로 독립 apply하는 게 분리의 목적이다.
# =============================================================================

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile (PowerShell에서 관리 중인 프로파일명)"
  type        = string
  default     = "admin"
}

variable "enable_guardduty_runtime_monitoring" {
  description = <<-EOT
    GuardDuty 런타임 모니터링(노드 DaemonSet 에이전트) 활성화 여부.
    프로세스/시스콜 수준 탐지가 추가되지만 t3.small 2대에는 메모리 부담이 있어
    기본 OFF. EKS 감사 로그/CloudTrail/FlowLogs 기반 탐지는 이 값과 무관하게 동작.
  EOT
  type        = bool
  default     = false
}

variable "security_hub_enable_cis_benchmark_v3" {
  description = "Security Hub에 CIS AWS Foundations Benchmark v3.0.0을 추가로 활성화할지 여부"
  type        = bool
  default     = false
}

variable "aws_config_snapshot_delivery_frequency" {
  description = "AWS Config 전체 스냅샷을 중앙 S3로 전달하는 주기. 짧게 잡을수록 S3 객체 수와 비용이 늘어난다."
  type        = string
  default     = "Six_Hours"

  validation {
    condition = contains([
      "One_Hour",
      "Three_Hours",
      "Six_Hours",
      "Twelve_Hours",
      "TwentyFour_Hours"
    ], var.aws_config_snapshot_delivery_frequency)
    error_message = "aws_config_snapshot_delivery_frequency는 AWS Config가 지원하는 전달 주기여야 합니다."
  }
}

variable "athena_cloudtrail_projection_start_date" {
  description = "Athena CloudTrail 파티션 프로젝션 시작일 (yyyy/MM/dd)"
  type        = string
  default     = "2026/01/01"

  validation {
    condition     = can(regex("^\\d{4}/(0[1-9]|1[0-2])/(0[1-9]|[12]\\d|3[01])$", var.athena_cloudtrail_projection_start_date))
    error_message = "Athena 파티션 시작일은 yyyy/MM/dd 형식이어야 합니다."
  }
}

variable "allowed_regions" {
  description = "Region Guard가 허용하는 리전 (서울 워크로드 + 도쿄 DR). 글로벌 서비스는 정책의 NotAction으로 별도 제외"
  type        = list(string)
  default     = ["ap-northeast-2", "ap-northeast-1"]
}

variable "console_admin_users" {
  description = "MFA 강제 콘솔 관리자 그룹에 넣을 IAM 사용자 이름 목록 (콘솔 전용 사용자만)"
  type        = list(string)
  default     = []
}

variable "cloudwatch_log_archive_retention_days" {
  description = "중앙 S3에 보관할 CloudWatch 로그의 총 보존 기간"
  type        = number
  default     = 365

  validation {
    condition     = var.cloudwatch_log_archive_retention_days > 90
    error_message = "S3 아카이브 보존 기간은 Glacier 전환 시점보다 긴 91일 이상이어야 합니다."
  }
}
