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