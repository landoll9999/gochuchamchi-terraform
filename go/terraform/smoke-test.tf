# =============================================================================
# apply 후 스모크 테스트  — 2026-08-04 자동화 2/3
#
# 왜 만드나 — 이 프로젝트에서 반복된 실패 유형은 "terraform은 성공했는데 서비스는
# 죽어 있는" 상태였다:
#   · 8/3  schema.sql이 한 번도 실행되지 않았는데 프로비저너가 Status를 안 봐서
#          terraform이 성공으로 기록 -> 회원가입 500
#   · 8/3  ECR이 비어 ImagePullBackOff -> 503 (apply는 성공)
#   · 8/4  PAT 미주입으로 ArgoCD가 저장소에 못 붙음 -> 앱이 아예 배포 안 됨 (apply는 성공)
#   · 8/4  NetworkPolicy DNS 결함으로 앱 전체 500 (apply는 성공)
# 공통점: "apply 성공"이 "서비스 정상"을 전혀 보장하지 않는데, 그 간극을 사람이
# 매번 손으로 메우고 있었다. 그 확인 절차를 apply 파이프라인 안으로 넣는다.
#
# 기본은 "경고 모드"다 (smoke_test_enforce = false)
#   재구축 직후에는 PAT 수동 주입 전이라 앱이 정상적으로 안 떠 있는 게 맞다.
#   여기서 apply를 실패시키면 재구축 자체가 막히므로, 기본은 결과만 출력한다.
#   운영에 준하는 상태(정상 가동 중 변경 apply)에서는 -enforce로 올려서
#   "서비스를 깨는 apply는 실패로 기록"되게 하는 것이 목표 상태다.
#     $env:TF_VAR_smoke_test_enforce = "true"; terraform apply
#
# 왜 매번 도는가 — triggers에 timestamp()를 써서 apply마다 실행된다.
#   plan에 항상 1개 변경으로 뜨는 게 단점이지만, 스모크 테스트는 "코드가 바뀔 때"가
#   아니라 "인프라를 건드릴 때마다" 돌아야 의미가 있다. 끄려면 아래 변수를 false로.
# =============================================================================

variable "smoke_test_after_apply" {
  description = "apply 직후 스모크 테스트를 자동 실행할지 여부"
  type        = bool
  default     = true
}

variable "smoke_test_enforce" {
  description = "스모크 테스트 실패 시 apply를 실패로 처리할지 여부 (false = 경고만)"
  type        = bool
  default     = false
}

resource "null_resource" "post_apply_smoke_test" {
  count = var.smoke_test_after_apply ? 1 : 0

  triggers = {
    always_run = timestamp()
  }

  # 검사 대상이 전부 만들어진 뒤에 돌아야 한다. (앱 파드 자체는 ArgoCD가 배포하므로
  # terraform 의존성으로 표현할 수 없다 — 그래서 스크립트가 "아직 안 뜬 상태"를
  # 실패가 아니라 대기/경고로 구분해서 보고한다)
  depends_on = [
    module.eks,
    kubernetes_ingress_v1.gochuchamchi_web,
    kubernetes_network_policy_v1.gochuchamchi_web_allow,
    null_resource.provision_app_db_user, # gochuchamchi-db-app Secret 주입
    helm_release.eso_config,             # ExternalSecret CR
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    working_dir = path.module

    # 계약(JSON)을 인자로 넘긴다 — apply 도중에는 state가 아직 확정 전이라
    # 스크립트가 `terraform output`을 호출하면 옛 값을 읽거나 실패한다.
    # 작은따옴표 이스케이프: JSON 값에 '가 들어갈 여지는 없지만 방어적으로 처리.
    # 한 줄로 유지 — 여러 줄 + 백틱 연결은 PowerShell -Command 로 넘길 때 개행 처리에
    # 따라 깨질 수 있어서, 길더라도 단일 명령 문자열이 안전하다.
    command = "& '${path.module}/../scripts/smoke-test.ps1' -ContractJson '${replace(jsonencode(local.deployment_contract), "'", "''")}' -Region '${var.region}' -AwsProfile '${var.aws_profile}' ${var.smoke_test_enforce ? "-Enforce" : ""}"
  }
}
