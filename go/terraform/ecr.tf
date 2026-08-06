# =============================================================================
# ECR 관련 계정 단위 설정
#
# 저장소 자체(aws_ecr_repository)와 CI push 권한(OIDC provider / IAM role)은
# 2026-08-06에 ../persistent 로 옮겼다 — destroy가 이미지를 지워 매번 503을 만들던
# 문제를 끊기 위해서다. 조회는 persistent-data.tf의 data source가 담당한다.
#
# 여기 남은 둘은 "계정 단위 스캔 설정"이라 재구축해도 다시 켜면 그만이고, 이미지
# 보존과는 무관하므로 메인 state에 둔다.
# =============================================================================

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

output "ecr_repository_url" {
  value       = data.aws_ecr_repository.gochuchamchi.repository_url
  description = "gochuchamchi-gitops의 이미지 참조와 gochuchamchi-spring CI 워크플로의 push 대상으로 사용 (실체는 ../persistent 관리)"
}

output "github_actions_ecr_role_arn" {
  value       = data.aws_iam_role.github_actions_ecr_push.arn
  description = "gochuchamchi-spring CI 워크플로의 role-to-assume 값 (실체는 ../persistent 관리)"
}
