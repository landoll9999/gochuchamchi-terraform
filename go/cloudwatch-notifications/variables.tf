variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI profile (../terraform/variables.tf와 동일 값 사용)"
  type        = string
  default     = "admin"
}

# 개인 이메일을 코드에 하드코딩하지 않기 위해 변수로 주입 (2026-08-04 하드코딩 리뷰 원칙).
# 주입: $env:TF_VAR_alert_emails = '["someone@example.com"]'
# 빈 목록이면 이메일 구독 없이 Discord만 동작 — 단 DLQ 자기 감시 루프의 최종
# 수신자가 없어지므로(sns.tf 주석 참고) 최소 1개 주입을 권장.
variable "alert_emails" {
  description = "SNS 알림 허브를 구독할 이메일 목록. apply 후 각 수신자가 확인 메일을 승인해야 활성화됨"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "alert_emails의 모든 항목은 이메일 주소 형식이어야 합니다."
  }
}