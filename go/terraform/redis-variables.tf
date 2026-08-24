# =============================================================================
# Redis 로그·알람 관련 변수 (2026-08-19)
#
# 별도 파일로 둔 이유: variables.tf가 이미 13KB라 도메인별로 나누는 편이
# 찾기 쉽다. edge-logs-variables.tf, image-signing-variables.tf와 같은 관용구.
# =============================================================================

variable "redis_log_retention_days" {
  description = <<-EOT
    Redis slow-log / engine-log의 CloudWatch Logs 보존 기간(일).
    이 클러스터는 매일 재생성되므로 길게 잡을 이유가 없다. 장기 보관이 필요해지면
    log-archive-subscriptions.tf로 중앙 S3에 보내는 쪽이 맞다.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90], var.redis_log_retention_days)
    error_message = "CloudWatch Logs가 허용하는 보존 기간 값이어야 합니다(1/3/5/7/14/30/60/90)."
  }
}

variable "redis_connection_alarm_threshold" {
  description = <<-EOT
    Redis 동시 연결 수 알람 임계값. 상한의 근거는 "앱 파드 수 × Lettuce 커넥션 풀
    크기 + 여유"다. HPA 최대 파드 수를 올리면 이 값도 같이 올려야 오탐이 안 난다.
  EOT
  type        = number
  default     = 50
}
