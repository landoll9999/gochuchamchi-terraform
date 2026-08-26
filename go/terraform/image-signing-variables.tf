# (2026-08-26) image_signing_github_environment 변수는 여기서 삭제했다.
# 서명 role·신뢰 정책의 실체가 persistent/image-signing.tf 로 이관된 뒤에도
# 참조 없는 사본이 남아 있던 것(ci-gate-pr 의 tflint terraform_unused_declarations 검출).
# 실제 값은 go/persistent/variables.tf 의 동명 변수를 본다.

variable "image_signature_validation_action" {
  description = "Kyverno image signature action: Audit records failures; Deny blocks unsigned images"
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Audit", "Deny"], var.image_signature_validation_action)
    error_message = "image_signature_validation_action must be Audit or Deny."
  }
}
