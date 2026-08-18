# =============================================================================
# 컨테이너 이미지 서명 검증 (Kyverno 쪽)
#
# 빌드/서명 신뢰 경로:
#   Build   GitHub main 브랜치 -> github_actions_ecr_push -> candidate-<SHA>
#   Sign    보호된 GitHub Environment -> github_actions_image_signer -> KMS Sign
#           -> Cosign 서명 -> signed-<SHA>
#
# 빌드 역할은 KMS 서명 키를 쓸 수 없다(권한 분리). Kyverno는 이 KMS 키로 만든
# 서명만 신뢰하며, 기존 워크로드를 끊지 않도록 Audit 모드로 시작한다.
#
# 2026-08-06 — KMS 키와 서명 역할은 ../persistent 로 옮겼다. 재구축 때 키가 새로
# 생기면 GitHub 변수(IMAGE_SIGNING_KMS_KEY_ARN)와 어긋나 CI 서명 잡이 실패하고,
# 그러면 ECR에 이미지가 안 올라가 사이트가 503으로 남기 때문이다. 여기에는
# "그 키를 신뢰해서 검증하는" 쪽만 남는다.
# =============================================================================

locals {
  image_signing_tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
    Component = "image-signing"
  }
}

# Kyverno 정책에 넣을 공개키. 개인키는 KMS 밖으로 나오지 않는다.
data "aws_kms_public_key" "image_signing" {
  key_id = data.aws_kms_key.image_signing.key_id
}

# -----------------------------------------------------------------------------
# Kyverno가 private ECR의 Cosign 서명 아티팩트를 읽을 때 쓰는 신원
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
        Resource = data.aws_ecr_repository.gochuchamchi.arn
      }
    ]
  })

  tags = local.image_signing_tags
}

module "kyverno_ecr_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # (v8) 버전 핀
  name    = "gochuchamchi-kyverno-ecr"

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
# 네임스페이스 범위 Kyverno 서명검증 정책 (고전형 verifyImages Policy)
# 신형 IVPol은 kyverno v1.18.2 버그(#15286)로 못 쓴다 — 차트 template 주석 참고.
# -----------------------------------------------------------------------------

resource "helm_release" "image_signature_policy" {
  name      = "gochuchamchi-image-signature-policy"
  chart     = "${path.module}/charts/image-signing-policy"
  namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name

  cleanup_on_fail = true

  values = [
    yamlencode({
      validationAction = var.image_signature_validation_action
      # 고전형 verifyImages는 공용 웹훅이라 Ignore로도 미서명을 거부한다(실증).
      # Fail(fail-closed)은 kyverno 장애 시 gochuchamchi 파드 전체를 막으므로 별도
      # 실측 후에만 승격한다 — 기본은 안전한 Ignore.
      failurePolicy   = "Ignore"
      imageRepository = data.aws_ecr_repository.gochuchamchi.repository_url
      publicKey       = data.aws_kms_public_key.image_signing.public_key_pem
      # A' 설계: digest 고정은 CI/GitOps에서 한다. kyverno의 digest 치환/강제는 끈다.
      # verifyDigest는 write-back을 digest로 전환한 뒤(A' 2단계) 켠다.
      mutateDigest = false
      verifyDigest = false
    })
  ]

  depends_on = [
    helm_release.kyverno,
    module.kyverno_ecr_pod_identity,
    kubernetes_namespace_v1.gochuchamchi
  ]
}

# -----------------------------------------------------------------------------
# 보호된 서명 워크플로가 참조하는 값 (실체는 ../persistent 관리)
# -----------------------------------------------------------------------------

output "github_actions_image_signer_role_arn" {
  description = "AWS role assumed only by the protected GitHub signing Environment"
  value       = data.aws_iam_role.github_actions_image_signer.arn
}

output "image_signing_kms_key_arn" {
  description = "KMS key ARN used with cosign --key awskms:///..."
  value       = data.aws_kms_key.image_signing.arn
}

output "image_signing_kms_uri" {
  description = "Cosign KMS URI for the protected signing job"
  value       = "awskms:///${data.aws_kms_key.image_signing.arn}"
}

output "image_signature_validation_action" {
  description = "Current Kyverno image signature action"
  value       = var.image_signature_validation_action
}
