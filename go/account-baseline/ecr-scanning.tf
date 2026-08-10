# =============================================================================
# ECR / Inspector 계정 단위 스캔 설정  (../terraform/ecr.tf 에서 이관)
#
# 저장소 실체와 CI push 권한은 ../persistent 가 갖고 있다. 여기 둘은 "계정에 하나만
# 존재하는 스캔 설정"이라 baseline 소속이다.
#
# 특히 aws_inspector2_enabler 는 destroy가 프로바이더 기본 5분을 넘겨 실패하고,
# state에 tainted로 남아 다음 apply가 비활성화->재생성을 반복한다 (8/4 §5.2).
# baseline으로 옮긴 첫 번째 이유가 이것이다 — 일일 destroy 경로에서 빼낸다.
# =============================================================================

resource "aws_inspector2_enabler" "this" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["ECR", "EC2"]

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
