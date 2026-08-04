variable "waf_log_retention_days" {
  description = "CloudWatch Logs retention period for WAF request logs"
  type        = number
  default     = 90

  validation {
    condition = contains([
      1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731,
      1096, 1827, 2192, 2557, 2922, 3288, 3653
    ], var.waf_log_retention_days)
    error_message = "waf_log_retention_days must be a CloudWatch Logs supported retention value."
  }
}

variable "cdn_log_retention_days" {
  description = "S3 retention period for CloudFront access logs"
  type        = number
  default     = 365

  validation {
    condition     = var.cdn_log_retention_days > 90
    error_message = "cdn_log_retention_days must be greater than 90 because logs transition to Glacier on day 90."
  }
}
