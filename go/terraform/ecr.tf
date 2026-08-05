# =============================================================================
# ECR — Docker Hub(dnjstjr504/gochuchamchi) 대체
#   - 같은 리전(ap-northeast-2) private 레지스트리라 pull이 더 빠르고,
#     Docker Hub 익명 접근의 pull/API rate limit 문제가 원천적으로 없음
#   - EKS 노드 IAM 역할에 이미 AmazonEC2ContainerRegistryReadOnly가 붙어있어
#     (terraform-aws-modules/eks 기본값) 파드 pull에는 imagePullSecrets 불필요
# =============================================================================

resource "aws_ecr_repository" "gochuchamchi" {
  name                 = "gochuchamchi"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  # Release/candidate tags include immutable GitHub run identity and must never
  # be moved to another digest. Cosign reference artifacts are the exception:
  # adding or rotating signatures/attestations updates these OCI tag manifests.
  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*.sig"
    filter_type = "WILDCARD"
  }

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*.att"
    filter_type = "WILDCARD"
  }

  image_tag_mutability_exclusion_filter {
    filter      = "sha256-*.sbom"
    filter_type = "WILDCARD"
  }

  # 이미지가 하나라도 남아있으면 destroy가 거부됨(S3의 BucketNotEmpty와 같은 성격).
  # destroy/apply를 반복하는 구조라 자동 삭제를 켠다.
  # ※ destroy 시 푸시된 이미지가 전부 삭제되므로, 재구축 후에는 CI를 다시 돌려야 함
  #    (gochuchamchi-spring 저장소에서 workflow_dispatch로 수동 트리거 가능)
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "gochuchamchi" {
  repository = aws_ecr_repository.gochuchamchi.name

  policy = jsonencode({
    rules = [
      {
        # Highest priority protects the newest signed releases even though the
        # same digest also retains its candidate tag.
        rulePriority = 1
        description  = "최근 서명 릴리스 20개 보존"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["signed-*"]
          countType      = "imageCountMoreThan"
          countNumber    = 20
        }
        action = { type = "expire" }
      },
      {
        # Candidates left by failed signing jobs have no release value. Signed
        # digests retained by rule 1 are protected from this lower-priority rule.
        rulePriority = 2
        description  = "서명되지 않은 candidate 이미지는 7일 후 만료"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["candidate-*"]
          countType      = "sinceImagePushed"
          countUnit      = "days"
          countNumber    = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 3
        description  = "태그 없는 중간 이미지는 7일 후 만료"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# (2026-08-03 full-HA에서 복원) 컨테이너 보안 레이어 3/3 — Amazon Inspector
#   scan_on_push(BASIC)는 push 시 1회 + OS 패키지 CVE만 본다. ENHANCED로 승격하면
#   OS + 언어 패키지(Java 라이브러리 등)까지 Inspector 콘솔로 통합 평가된다.
#   Spring Boot 앱이라 언어 패키지 스캔이 실질적으로 더 중요함 (Log4Shell 류).
#
#   💰 비용: Inspector는 계정당 15일 무료 평가판 → 이후 이미지/인스턴스당 과금.
#      필요 없어지면 aws_inspector2_enabler만 destroy해도 꺼진다.
# ---------------------------------------------------------------------------
resource "aws_inspector2_enabler" "this" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2"]

  # EC2+ECR 활성화/비활성화가 프로바이더 기본 5분을 넘길 때가 있다. 타임아웃이 나도
  # AWS 쪽 작업은 계속 진행돼 결국 ENABLED/DISABLED가 되지만 Terraform은 실패로 본다.
  # (2026-08-04 apply/destroy 양쪽에서 실제로 발생 — apply는 tainted가 남아 다음 실행이
  #  destroy→재생성을 반복했고, destroy는 state에 남아 재시도가 막혔다.)
  timeouts {
    create = "15m"
    update = "15m"
    delete = "15m"
  }
}

# 레지스트리 스캔을 Inspector 기반 ENHANCED로 승격 (계정 단위 설정)
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "SCAN_ON_PUSH"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }

  depends_on = [aws_inspector2_enabler.this]
}

# ---------------------------------------------------------------------------
# GitHub Actions(gochuchamchi-spring 저장소)가 OIDC로 AWS를 assume해서 ECR에
# push. 액세스키를 GitHub Secret에 저장할 필요가 없어 Docker Hub 방식(계정+토큰)
# 보다 안전함.
# ---------------------------------------------------------------------------
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "github_actions_ecr_push" {
  name = "gochuchamchi-github-actions-ecr-push"

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
        # main 브랜치 push(=CI 워크플로 트리거 조건)에서만 assume 가능하도록 제한
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.argocd_github_owner}/gochuchamchi-spring:ref:refs/heads/main"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.github_actions_ecr_push.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
        ]
        Resource = aws_ecr_repository.gochuchamchi.arn
      }
    ]
  })
}

output "ecr_repository_url" {
  value       = aws_ecr_repository.gochuchamchi.repository_url
  description = "gochuchamchi-gitops의 이미지 참조와 gochuchamchi-spring CI 워크플로의 push 대상으로 사용"
}

output "github_actions_ecr_role_arn" {
  value       = aws_iam_role.github_actions_ecr_push.arn
  description = "gochuchamchi-spring CI 워크플로의 aws-actions/configure-aws-credentials role-to-assume 값으로 사용"
}
