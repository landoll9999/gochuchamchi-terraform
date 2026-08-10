data "aws_caller_identity" "current" {}

resource "terraform_data" "account_guard" {
  input = data.aws_caller_identity.current.account_id

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == "828885965304"
      error_message = "persistent/는 Workload 계정 828885965304에서만 실행할 수 있습니다."
    }
  }
}
