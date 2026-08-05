# =============================================================================
# GitHub Actions -> gochuchamchi-terraform repo 전용 OIDC Role
#
# OIDC provider(aws_iam_openid_connect_provider.github_actions)는 ecr.tf에서
# 이미 만들어져 있음 (gochuchamchi-spring repo가 씀) -> 여기서는 재사용만 하고,
# "문(Role)"만 terraform repo용으로 새로 2개 만든다.
#
#   - plan 열쇠: PR마다 자동 실행, 조회 권한만 있음 (안전)
#   - apply 열쇠: main에 merge된 뒤에만 쓸 수 있음, 실제 변경 권한 있음 (위험하니 제한)
# =============================================================================

# -----------------------------------------------------------------------------
# Plan용 Role — 아무 브랜치의 PR에서나 assume 가능 (읽기 전용이라 안전)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "github_actions_terraform_plan" {
  name = "gochuchamchi-github-actions-terraform-plan"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # GitHub이 과거 저장소/계정 이름 변경 이력 때문에 sub에 고유 ID를 붙임
          # (landoll9999@278245683, gochuchamchi-terraform@1322393704 형태).
          # 이 숫자 ID는 CloudTrail 실제 로그값 기준으로 고정된 값 - 안 바뀜.
          "token.actions.githubusercontent.com:sub" = "repo:landoll9999@278245683/gochuchamchi-terraform@1322393704:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_plan_readonly" {
  role       = aws_iam_role.github_actions_terraform_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# terraform plan도 내부적으로 S3 state lock 파일을 생성/삭제함 (backend.tf의
# use_lockfile = true 방식). ReadOnlyAccess에는 s3:PutObject/DeleteObject가
# 없어서 이것만 예외로, state 버킷 하나에 한정해서 추가.
resource "aws_iam_role_policy" "github_actions_terraform_plan_state_lock" {
  name = "state-lock-access"
  role = aws_iam_role.github_actions_terraform_plan.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "StateLockReadWrite"
      Effect = "Allow"
      Action = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ]
      Resource = "arn:aws:s3:::gochuchamchi-tfstate-307223751140/*"
    }]
  })
}

# -----------------------------------------------------------------------------
# Apply용 Role — main 브랜치에 push(=merge)된 경우에만 assume 가능
# -----------------------------------------------------------------------------
resource "aws_iam_role" "github_actions_terraform_apply" {
  name = "gochuchamchi-github-actions-terraform-apply"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # main 브랜치 push(merge)에서만 assume 가능. GitHub이 붙이는 고유 ID
          # 형식(owner@id/repo@id) 반영 - plan role과 동일한 이유.
          "token.actions.githubusercontent.com:sub" = "repo:landoll9999@278245683/gochuchamchi-terraform@1322393704:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions_terraform_apply_admin" {
  role       = aws_iam_role.github_actions_terraform_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# -----------------------------------------------------------------------------
# 출력값 — GitHub Actions workflow의 role-to-assume에 그대로 넣을 값
# -----------------------------------------------------------------------------
output "github_actions_terraform_plan_role_arn" {
  value       = aws_iam_role.github_actions_terraform_plan.arn
  description = "terraform-plan.yml 워크플로의 role-to-assume 값"
}

output "github_actions_terraform_apply_role_arn" {
  value       = aws_iam_role.github_actions_terraform_apply.arn
  description = "terraform-apply.yml 워크플로의 role-to-assume 값"
}