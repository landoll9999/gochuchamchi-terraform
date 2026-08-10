# IAM Identity Center 인스턴스 자체는 Management 계정 콘솔에서 먼저 활성화해야 한다.
# 활성화 후 enable_identity_center_configuration=true로 바꾸면 아래 Permission Set을 관리한다.
data "aws_ssoadmin_instances" "this" {
  count = var.enable_identity_center_configuration ? 1 : 0
}

locals {
  identity_center_instance_arn = var.enable_identity_center_configuration ? tolist(data.aws_ssoadmin_instances.this[0].arns)[0] : null
}

resource "aws_ssoadmin_permission_set" "workload_administrator" {
  count = var.enable_identity_center_configuration ? 1 : 0

  name             = "WorkloadAdministrator"
  description      = "Workload 계정 전용 관리자"
  instance_arn     = local.identity_center_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "workload_administrator" {
  count = var.enable_identity_center_configuration ? 1 : 0

  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.workload_administrator[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_ssoadmin_permission_set" "security_log_administrator" {
  count = var.enable_identity_center_configuration ? 1 : 0

  name             = "SecurityLogAdministrator"
  description      = "Security/Log 계정 전용 관리자"
  instance_arn     = local.identity_center_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "security_log_administrator" {
  count = var.enable_identity_center_configuration ? 1 : 0

  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.security_log_administrator[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_ssoadmin_permission_set" "organization_read_only" {
  count = var.enable_identity_center_configuration ? 1 : 0

  name             = "OrganizationReadOnly"
  description      = "조직 전체 조회 전용"
  instance_arn     = local.identity_center_instance_arn
  session_duration = "PT4H"
}

resource "aws_ssoadmin_managed_policy_attachment" "organization_read_only" {
  count = var.enable_identity_center_configuration ? 1 : 0

  instance_arn       = local.identity_center_instance_arn
  permission_set_arn = aws_ssoadmin_permission_set.organization_read_only[0].arn
  managed_policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
