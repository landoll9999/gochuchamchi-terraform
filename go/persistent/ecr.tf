# =============================================================================
# ECR — 컨테이너 이미지 레지스트리 + GitHub Actions CI push 권한
#
# ../terraform 과 state를 분리한 이유 (2026-08-06 실행, 계획서 docs/ecr-state-separation.txt)
#   메인 인프라를 destroy하면 force_delete가 이미지까지 전부 지운다. 재구축 후 GitOps
#   매니페스트가 가리키는 태그를 못 찾아 파드가 ImagePullBackOff에 빠지고 ALB가 503을
#   반환한다. 2026-07-31과 2026-08-06에 같은 사고가 반복됐고, 그때마다 CI를 손으로
#   다시 돌려야 했다. 여기로 떼어내면 메인을 destroy/apply해도 이미지가 살아남는다.
#
# ※ 메인(../terraform)보다 먼저 apply해야 한다 — 메인의 persistent-data.tf가
#    data source로 여기 있는 리소스를 조회하기 때문이다.
# =============================================================================

resource "aws_ecr_repository" "gochuchamchi" {
  name = "gochuchamchi"

  # 불변 태그 (PR #5 feat/ecr-tag-immutability에서 이관 — 2026-08-06)
  #
  # release/candidate 태그에는 GitHub run 식별자가 들어가 있어 다른 digest로 옮겨질
  # 이유가 없다. 예외는 Cosign 참조 아티팩트뿐이다 — 서명·어테스테이션을 추가하거나
  # 로테이션하면 이 OCI 태그 매니페스트가 갱신되므로 불변이면 서명 자체가 막힌다.
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

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

  # force_delete 자체는 유지한다 — 정말 이 저장소를 지워야 하는 날 이미지가 남아 있다는
  # 이유로 막히면 곤란하기 때문이다. 실수 방지는 아래 prevent_destroy가 담당한다.
  force_delete = true

  # 이 state를 분리한 목적이 곧 이미지 보존이다. 정말 지워야 한다면 이 블록을 먼저
  # 지우고 destroy할 것.
  lifecycle {
    prevent_destroy = true
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "gochuchamchi" {
  repository = aws_ecr_repository.gochuchamchi.name

  # 3단계 정책 (PR #5에서 이관 — 2026-08-06)
  policy = jsonencode({
    rules = [
      {
        # 우선순위가 가장 높아야 한다 — 같은 digest가 candidate 태그도 함께 갖고
        # 있어서, 아래 규칙이 먼저 걸리면 서명된 릴리스가 만료될 수 있다.
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
        # 서명 잡이 실패해서 남은 candidate는 릴리스 가치가 없다. 규칙 1이 지키는
        # 서명 digest는 우선순위가 낮은 이 규칙의 영향을 받지 않는다.
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
# GitHub Actions(gochuchamchi-spring)가 OIDC로 AWS를 assume해서 ECR에 push한다.
# 액세스키를 GitHub Secret에 두지 않아도 된다.
#
# OIDC provider와 role을 ECR과 같은 state에 두는 이유 — 재구축 때 이것들이 새로
# 만들어지면 GitHub 쪽 변수(AWS_ECR_BUILD_ROLE_ARN 등)와 어긋나 CI가 통째로 실패한다.
# 이미지를 살려둬도 CI를 못 돌리면 복구 수단이 사라지므로 함께 영속화한다.
# ---------------------------------------------------------------------------
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github_actions.certificates[0].sha1_fingerprint]

  lifecycle {
    prevent_destroy = true
  }
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
        # main과 명시적으로 승인한 임시 브랜치만 assume 가능하다. repo 전체(*)를
        # 허용하지 않아 다른 브랜치가 Workload ECR push 권한을 얻지 못하게 한다.
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            for ref in var.github_ecr_build_allowed_refs :
            "repo:${var.github_owner}/gochuchamchi-spring:ref:${ref}"
          ]
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
