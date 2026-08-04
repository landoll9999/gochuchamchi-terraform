# =============================================================================
# Separated container image build and signing trust paths
#
# Build job:
#   GitHub main branch -> github_actions_ecr_push -> candidate-<commit SHA>
#
# Signing job:
#   Protected GitHub Environment -> github_actions_image_signer -> KMS Sign
#   -> Cosign signature -> signed-<commit SHA>
#
# The build role cannot use the KMS signing key. Kyverno trusts only signatures
# produced by this KMS key and starts in Audit mode so existing workloads are
# not interrupted during rollout.
# =============================================================================

locals {
  image_signing_tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
    Component = "image-signing"
  }
}

# -----------------------------------------------------------------------------
# Asymmetric KMS key used by Cosign. The private key never leaves AWS KMS.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "image_signing" {
  description              = "Cosign key for gochuchamchi ECR release images"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 30

  tags = merge(local.image_signing_tags, { Name = "gochuchamchi-image-signing" })
}

resource "aws_kms_alias" "image_signing" {
  name          = "alias/gochuchamchi-image-signing"
  target_key_id = aws_kms_key.image_signing.key_id
}

data "aws_kms_public_key" "image_signing" {
  key_id = aws_kms_key.image_signing.key_id
}

# -----------------------------------------------------------------------------
# Dedicated GitHub Actions signing role
#
# GitHub must create an Environment named by image_signing_github_environment.
# Protect that Environment with required reviewers and allow only main.
# -----------------------------------------------------------------------------

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
          "token.actions.githubusercontent.com:sub" = "repo:${var.argocd_github_owner}/gochuchamchi-spring:environment:${var.image_signing_github_environment}"
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

# -----------------------------------------------------------------------------
# Kyverno ECR read identity used when fetching private Cosign signatures.
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "kyverno_ecr_signature_read" {
  name        = "gochuchamchi-kyverno-ecr-signature-read"
  description = "Read the gochuchamchi image and attached Cosign signatures"

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
        Sid    = "ReadImageAndSignatureArtifacts"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.gochuchamchi.arn
      }
    ]
  })

  tags = local.image_signing_tags
}

module "kyverno_ecr_pod_identity" {
  source = "terraform-aws-modules/eks-pod-identity/aws"
  name   = "gochuchamchi-kyverno-ecr"

  additional_policy_arns = {
    ecr_signature_read = aws_iam_policy.kyverno_ecr_signature_read.arn
  }

  associations = {
    kyverno_admission = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kyverno"
      service_account = "kyverno-admission-controller"
    }
  }
}

# -----------------------------------------------------------------------------
# Namespaced Kyverno ImageValidatingPolicy
# -----------------------------------------------------------------------------

resource "helm_release" "image_signature_policy" {
  name      = "gochuchamchi-image-signature-policy"
  chart     = "${path.module}/charts/image-signing-policy"
  namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name

  cleanup_on_fail = true

  values = [
    yamlencode({
      validationAction = var.image_signature_validation_action
      failurePolicy    = var.image_signature_validation_action == "Deny" ? "Fail" : "Ignore"
      imageRepository  = aws_ecr_repository.gochuchamchi.repository_url
      publicKey        = data.aws_kms_public_key.image_signing.public_key_pem
      mutateDigest     = var.image_signature_validation_action == "Deny"
      verifyDigest     = var.image_signature_validation_action == "Deny"
    })
  ]

  depends_on = [
    helm_release.kyverno,
    module.kyverno_ecr_pod_identity,
    kubernetes_namespace_v1.gochuchamchi
  ]
}

# -----------------------------------------------------------------------------
# Outputs consumed by the protected signing workflow
# -----------------------------------------------------------------------------

output "github_actions_image_signer_role_arn" {
  description = "AWS role assumed only by the protected GitHub signing Environment"
  value       = aws_iam_role.github_actions_image_signer.arn
}

output "image_signing_kms_key_arn" {
  description = "KMS key ARN used with cosign --key awskms:///..."
  value       = aws_kms_key.image_signing.arn
}

output "image_signing_kms_uri" {
  description = "Cosign KMS URI for the protected signing job"
  value       = "awskms:///${aws_kms_key.image_signing.arn}"
}

output "image_signature_validation_action" {
  description = "Current Kyverno image signature action"
  value       = var.image_signature_validation_action
}
