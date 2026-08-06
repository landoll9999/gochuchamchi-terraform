# 메인(../terraform)은 이 값들을 output이 아니라 data source로 직접 조회한다
# (persistent-data.tf). remote state를 참조하지 않는 이유는, 이름이 고정된
# 리소스뿐이라 data source 쪽이 결합도가 낮고 apply 순서에도 덜 민감하기 때문이다.
# 아래 output은 사람이 값을 확인할 때 쓴다.

output "ecr_repository_url" {
  description = "gochuchamchi-spring CI의 push 대상, GitOps 매니페스트의 이미지 참조"
  value       = aws_ecr_repository.gochuchamchi.repository_url
}

output "github_actions_ecr_role_arn" {
  description = "CI 빌드 잡의 role-to-assume (GitHub 변수 AWS_ECR_BUILD_ROLE_ARN)"
  value       = aws_iam_role.github_actions_ecr_push.arn
}

output "github_actions_image_signer_role_arn" {
  description = "CI 서명 잡의 role-to-assume (GitHub 변수 AWS_IMAGE_SIGNER_ROLE_ARN)"
  value       = aws_iam_role.github_actions_image_signer.arn
}

output "image_signing_kms_key_arn" {
  description = "cosign --key awskms:///... 에 쓰는 KMS 키 (GitHub 변수 IMAGE_SIGNING_KMS_KEY_ARN)"
  value       = aws_kms_key.image_signing.arn
}

output "argocd_git_pat_secret_name" {
  description = "ArgoCD PAT 시크릿 이름 — 값 주입은 aws secretsmanager put-secret-value로"
  value       = aws_secretsmanager_secret.argocd_git_pat.name
}
