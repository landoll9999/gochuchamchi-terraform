# =============================================================================
# 영속 state(../persistent)가 관리하는 리소스 조회  — 2026-08-06
#
# 왜 분리했나 — 아래 리소스들은 "메인 인프라를 destroy/apply해도 살아남아야 하는 것"
# 이다. 메인 state에 있으면 destroy가 함께 지워 버리고, 그 결과가 매번 503이었다:
#
#   ECR            destroy가 force_delete로 이미지까지 삭제 -> ImagePullBackOff
#   서명 KMS 키     새 키가 생기면 GitHub 변수와 어긋나 CI 서명 잡이 실패
#   OIDC/IAM 역할   재생성되면 CI가 AWS를 assume하지 못함
#   PAT 시크릿      값이 사라져 ArgoCD가 GitOps 저장소에 못 붙음
#
# 어느 하나만 살려도 소용이 없다 — 이미지를 살려도 CI를 못 돌리면 갱신할 수 없고,
# CI가 돌아도 PAT가 없으면 배포가 안 된다. 그래서 이 네 가지를 한 묶음으로 옮겼다.
#
# remote state가 아니라 data source로 조회하는 이유 — 전부 이름이 고정된 리소스라
# 결합도가 낮고, ../persistent의 output 구성이 바뀌어도 여기가 깨지지 않는다.
#
# ※ ../persistent를 먼저 apply해야 여기가 조회에 성공한다. 완전 신규 구축이라면:
#     cd ../persistent && terraform apply     (한 번만)
#     cd ../terraform  && terraform apply
# =============================================================================

data "aws_ecr_repository" "gochuchamchi" {
  name = "gochuchamchi"
}

# 별칭으로 조회한다 — 키를 교체하더라도 별칭만 옮기면 여기는 그대로 동작한다.
data "aws_kms_key" "image_signing" {
  key_id = "alias/gochuchamchi-image-signing"
}

data "aws_iam_role" "github_actions_ecr_push" {
  name = "gochuchamchi-github-actions-ecr-push"
}

data "aws_iam_role" "github_actions_image_signer" {
  name = "gochuchamchi-github-actions-image-signer"
}

data "aws_secretsmanager_secret" "argocd_git_pat" {
  name = "gochuchamchi/argocd/git-pat"
}

data "aws_secretsmanager_secret" "argocd_gitops_read_pat" {
  name = "gochuchamchi/argocd/gitops-read-pat"
}

data "aws_secretsmanager_secret" "argocd_image_updater_write_pat" {
  name = "gochuchamchi/argocd/image-updater-write-pat"
}

# 워크로드 데이터 CMK — 별칭으로 조회 (2026-08-07 kms.tf에서 persistent로 이동)
data "aws_kms_key" "data" {
  key_id = "alias/gochuchamchi-data"
}
