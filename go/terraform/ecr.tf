# =============================================================================
# ECR 관련 계정 단위 설정
#
# 저장소 자체(aws_ecr_repository)와 CI push 권한(OIDC provider / IAM role)은
# 2026-08-06에 ../persistent 로 옮겼다 — destroy가 이미지를 지워 매번 503을 만들던
# 문제를 끊기 위해서다. 조회는 persistent-data.tf의 data source가 담당한다.
#
# 계정 단위 스캔 설정(Inspector2 enabler / 레지스트리 ENHANCED 스캔)은 2026-08-07에
# ../account-baseline 으로 옮겼다 — Inspector2의 destroy가 15분 타임아웃 후 tainted로
# 남아 다음 apply를 망가뜨리던 문제(8/4 §5.2)를 일일 destroy 경로에서 빼내기 위해서다.
#
# 그래서 여기 남은 것은 persistent가 관리하는 값의 재노출 output 둘뿐이다.
# =============================================================================


output "ecr_repository_url" {
  value       = data.aws_ecr_repository.gochuchamchi.repository_url
  description = "gochuchamchi-gitops의 이미지 참조와 gochuchamchi-spring CI 워크플로의 push 대상으로 사용 (실체는 ../persistent 관리)"
}

output "github_actions_ecr_role_arn" {
  value       = data.aws_iam_role.github_actions_ecr_push.arn
  description = "gochuchamchi-spring CI 워크플로의 role-to-assume 값 (실체는 ../persistent 관리)"
}
