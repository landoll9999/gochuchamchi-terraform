# =============================================================================
# IAM 보안 잔여 항목 (격차분석 §2.9, 계획 D03~D04)
#   1. IAM Access Analyzer — 외부에 노출된 리소스 정책 상시 탐지
#   2. MFA 강제 IAM 그룹 — 콘솔 사용자용
#   3. Region Guard — 허용 리전 밖 API 호출 명시적 Deny (단일 계정이라 SCP 불가)
#
# ⚠️⚠️ 그룹 멤버십은 기본값이 "비어 있음"이고, 반드시 비워둔 채 유지 조건을
#      이해하고 넣어야 한다. 07/29에 작업 계정이 explicit deny 그룹(3pro)에
#      들어가 있어서 terraform plan 전체가 AccessDenied로 마비된 사고가 있었다
#      (docs/architecture.md §4.2). 이 그룹의 두 정책 모두 explicit Deny를
#      포함하므로:
#        - MFA 강제: CLI 액세스 키는 MFA 세션이 아니라서, Terraform을 돌리는
#          계정을 넣는 순간 모든 apply가 죽는다. "콘솔 전용 사용자"만 넣을 것.
#        - Region Guard: 허용 리전 목록(var.allowed_regions)에 없는 리전 작업이
#          전부 막힌다.
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Access Analyzer — 계정 밖(외부 주체)에서 접근 가능한 리소스를 상시 분석
#    (S3 버킷 정책, KMS 키 정책, IAM 역할 신뢰 정책 등)
#    이미지 버킷의 public read는 의도적 유지 항목이라 finding이 하나 뜨는 게
#    정상이다 — 콘솔에서 archive 처리하고 사유를 남길 것.
# ---------------------------------------------------------------------------
resource "aws_accessanalyzer_analyzer" "account" {
  analyzer_name = "gochuchamchi-account-analyzer"
  type          = "ACCOUNT"

  tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
  }
}

# ---------------------------------------------------------------------------
# 2. 콘솔 관리자 그룹 + MFA 강제
# ---------------------------------------------------------------------------
resource "aws_iam_group" "console_admins" {
  name = "gochuchamchi-console-admins"
}

# AWS 표준 패턴: MFA 없이 로그인하면 "자기 MFA 등록"에 필요한 액션만 허용하고
# 나머지는 전부 거부 -> 사용자가 스스로 MFA를 켜기 전엔 아무것도 못 함
resource "aws_iam_group_policy" "force_mfa" {
  name  = "force-mfa"
  group = aws_iam_group.console_admins.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowViewAccountInfo"
        Effect = "Allow"
        Action = [
          "iam:GetAccountPasswordPolicy",
          "iam:ListVirtualMFADevices"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowManageOwnMFA"
        Effect = "Allow"
        Action = [
          "iam:CreateVirtualMFADevice",
          "iam:DeleteVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:ListMFADevices",
          "iam:GetUser",
          "iam:ChangePassword"
        ]
        Resource = [
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:mfa/$${aws:username}",
          "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/$${aws:username}"
        ]
      },
      {
        Sid    = "DenyAllExceptListedIfNoMFA"
        Effect = "Deny"
        NotAction = [
          "iam:CreateVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:GetUser",
          "iam:ListMFADevices",
          "iam:ListVirtualMFADevices",
          "iam:ResyncMFADevice",
          "iam:ChangePassword",
          "sts:GetSessionToken"
        ]
        Resource = "*"
        Condition = {
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_iam_group_policy_attachment" "console_admins_admin" {
  group      = aws_iam_group.console_admins.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# 멤버십은 명시적으로만. 기본 [] — Terraform 실행 계정을 절대 넣지 말 것 (상단 경고).
resource "aws_iam_group_membership" "console_admins" {
  count = length(var.console_admin_users) > 0 ? 1 : 0

  name  = "gochuchamchi-console-admins-membership"
  group = aws_iam_group.console_admins.name
  users = var.console_admin_users
}

# ---------------------------------------------------------------------------
# 3. Region Guard — 허용 리전 밖 API 호출 차단
#    단일 계정이라 Organizations SCP를 못 쓰므로 IAM 명시적 Deny로 대신한다.
#    글로벌 서비스는 NotAction으로 제외 — 특히 acm/cloudfront/wafv2를 빼지
#    않으면 us-east-1 인증서 발급(edge.tf)이 막혀서 D13이 통째로 멈춘다
#    (격차분석 §2.1 경고 그대로).
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "region_guard" {
  name        = "gochuchamchi-region-guard"
  description = "허용 리전(서울/도쿄DR) 밖 리소스 생성·조작 차단. 글로벌 서비스는 제외"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyOutsideAllowedRegions"
      Effect = "Deny"
      NotAction = [
        "iam:*",
        "sts:*",
        "s3:*",
        "route53:*",
        "cloudfront:*",
        "wafv2:*",
        "acm:*",
        "support:*",
        "health:*",
        "budgets:*",
        "ce:*"
      ]
      Resource = "*"
      Condition = {
        StringNotEquals = {
          "aws:RequestedRegion" = var.allowed_regions
        }
      }
    }]
  })
}

# 그룹에만 부착. Terraform 실행 계정에 직접 붙이고 싶으면 허용 리전 목록이
# 충분한지(도쿄 DR, us-east-1 글로벌 예외) 확인한 뒤 콘솔에서 수동으로 붙일 것 —
# 코드로 실행 계정에 Deny를 붙였다가 잘못되면 그 Deny를 풀 apply조차 못 돌린다.
resource "aws_iam_group_policy_attachment" "console_admins_region_guard" {
  group      = aws_iam_group.console_admins.name
  policy_arn = aws_iam_policy.region_guard.arn
}


# =============================================================================
# Outputs
# =============================================================================

output "access_analyzer_arn" {
  description = "IAM Access Analyzer ARN"
  value       = aws_accessanalyzer_analyzer.account.arn
}

output "region_guard_policy_arn" {
  description = "Region Guard 정책 ARN (콘솔 관리자 그룹에 부착됨)"
  value       = aws_iam_policy.region_guard.arn
}
