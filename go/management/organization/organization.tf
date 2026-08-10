resource "aws_organizations_organization" "this" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "backup.amazonaws.com",
    "cloudtrail.amazonaws.com",
    "config-multiaccountsetup.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "sso.amazonaws.com",
  ]

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY",
  ]

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.management_account_id
      error_message = "Management 계정(307223751140) 자격증명으로만 실행할 수 있습니다."
    }
  }
}

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = aws_organizations_organization.this.roots[0].id

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = aws_organizations_organization.this.roots[0].id

  lifecycle {
    prevent_destroy = true
  }
}
