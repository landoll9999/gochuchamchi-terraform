# =============================================================================
# ci-gate-pr 의 tflint 잡이 쓰는 공통 설정 (2026-08-26)
#
# 왜 루트에 하나만 두나:
#   레이어마다 .tflint.hcl 을 흩어 두면 "여기는 걸리고 저기는 안 걸리는" 이유를
#   아무도 설명하지 못하게 된다. 워크플로가 --config 로 이 파일의 절대경로를
#   넘기므로, 8개 레이어 전부 같은 규칙으로 검사된다.
#
# 규칙 예외를 추가할 때는 반드시 "왜 이 저장소에서는 해당 없음"인지 근거를
# 주석으로 남긴다. 근거 없는 disable 은 관문을 장식으로 만든다.
# =============================================================================

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.48.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# ElastiCache 를 AWS 기본 파라미터 그룹으로 두는 것은 의도된 선택이다.
# (go/terraform/redis.tf:121,177 — 세션 캐시 용도라 튜닝할 파라미터가 없고,
#  커스텀 그룹을 만들면 관리 대상만 늘어난다.)
# 규칙의 취지는 "기본 그룹은 편집할 수 없다"는 안내인데 우리는 편집하지 않으므로
# 해당 없음. 파라미터 튜닝이 필요해지는 시점에 이 예외를 지우고 커스텀 그룹을 만든다.
rule "aws_elasticache_replication_group_default_parameter_group" {
  enabled = false
}
