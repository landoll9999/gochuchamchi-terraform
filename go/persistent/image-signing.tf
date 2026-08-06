# =============================================================================
# 이미지 서명용 KMS 키 + 서명 전용 GitHub Actions 역할
#
# 왜 영속 state인가 (2026-08-06)
#   재구축하면 KMS 키가 새로 만들어지고 옛 키는 30일 삭제 대기(PendingDeletion)로
#   들어간다. 그런데 GitHub 변수 IMAGE_SIGNING_KMS_KEY_ARN은 수동 관리라 옛 키를
#   그대로 가리키고, 그 상태로 CI를 돌리면 서명 잡이 실패한다 -> ECR에 이미지가
#   안 올라간다 -> 앱이 배포되지 않아 503이 유지된다. 2026-08-06에 실제로 이
#   경로를 탔고, 원인이 세 단계 떨어져 있어 추적에 시간이 걸렸다.
#
#   키를 영속화하면 재구축과 무관하게 ARN이 고정되고, 이미 서명된 이미지의 서명도
#   계속 검증 가능한 상태로 남는다(Kyverno가 이 키의 공개키로 검증한다).
#
# ※ ../terraform/ci-sync.tf가 apply마다 GitHub 변수를 실제 ARN으로 덮어쓰므로
#   수동 동기화 자체가 이제 필요 없다. 이 파일은 "ARN이 애초에 바뀌지 않게" 만든다.
# =============================================================================

locals {
  image_signing_tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
    Component = "image-signing"
  }
}

# 비대칭 KMS 키. 개인키는 KMS 밖으로 나오지 않는다.
resource "aws_kms_key" "image_signing" {
  description              = "Cosign key for gochuchamchi ECR release images"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 30

  tags = merge(local.image_signing_tags, { Name = "gochuchamchi-image-signing" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "image_signing" {
  name          = "alias/gochuchamchi-image-signing"
  target_key_id = aws_kms_key.image_signing.key_id
}

# ---------------------------------------------------------------------------
# 서명 전용 역할 — 보호된 GitHub Environment에서만 assume 가능하다.
# 빌드 역할(github_actions_ecr_push)은 이 키를 쓸 수 없다(권한 분리).
# ---------------------------------------------------------------------------
resource "aws_iam_role" "github_actions_image_signer" {
  name                 = "gochuchamchi-github-actions-image-signer"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github_actions.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}/gochuchamchi-spring:environment:${var.image_signing_github_environment}"
        }
      }
    }]
  })

  tags = local.image_signing_tags
}

resource "aws_iam_role_policy" "github_actions_image_signer" {
  name = "sign-and-publish-cosign-artifact"
  role = aws_iam_role.github_actions_image_signer.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthentication"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ReadCandidateAndPublishSignature"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = aws_ecr_repository.gochuchamchi.arn
      },
      {
        Sid    = "SignWithDedicatedKmsKey"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:GetPublicKey",
          "kms:Sign"
        ]
        Resource = aws_kms_key.image_signing.arn
      }
    ]
  })
}
