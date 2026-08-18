variable "image_signing_github_environment" {
  description = "Protected GitHub Environment allowed to assume the image-signing role"
  type        = string
  default     = "production-signing"

  validation {
    condition     = length(trimspace(var.image_signing_github_environment)) > 0
    error_message = "image_signing_github_environment must not be empty."
  }
}

variable "image_signature_validation_action" {
  description = "Kyverno image signature action: Audit records failures; Deny blocks unsigned images"
  type        = string
  default     = "Deny"

  validation {
    condition     = contains(["Audit", "Deny"], var.image_signature_validation_action)
    error_message = "image_signature_validation_action must be Audit or Deny."
  }
}
