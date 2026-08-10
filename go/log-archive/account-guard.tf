resource "terraform_data" "account_guard" {
  input = data.aws_caller_identity.current.account_id

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == "564186750363"
      error_message = "log-archive/는 Security/Log 계정 564186750363에서만 실행할 수 있습니다."
    }
  }
}
