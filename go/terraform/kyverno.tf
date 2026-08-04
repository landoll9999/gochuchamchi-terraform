# =============================================================================
# Kyverno — 정책 엔진 (컨테이너 보안 레이어 1/3의 확장, 2026-08-03)
#
#   PSA(k8s-deploy.tf의 namespace 라벨)와의 역할 분담:
#     - PSA(enforce=baseline): privileged/hostPath/hostNetwork 등 컨테이너 탈출
#       벡터를 API 서버 내장 기능으로 "차단". 추가 파드 없이 동작하는 1차 방어선.
#     - Kyverno(audit=restricted): restricted 위반을 PolicyReport 리소스로
#       "계량". PSA warn은 kubectl 친 사람만 보지만, PolicyReport는
#       `kubectl get polr -A`로 조회 가능한 상시 준수 현황판이 된다.
#       gitops Deployment에 securityContext를 다 넣은 뒤 PSA enforce를
#       restricted로 올릴 때, "지금 뭐가 걸리는지"를 이 리포트로 확인하고 올린다.
#
#   t3.small 2대 리소스 절충:
#     - admission/reports 컨트롤러만 켜고 background/cleanup 컨트롤러는 끔
#       (mutate-existing/generate/cleanup 정책을 안 쓰므로 불필요)
#     - replicas 1 (프로덕션 기준은 admission 3대 — HA webhook. 여기선 비용 우선)
#     - webhook failurePolicy는 차트 기본값(Ignore for audit) — Kyverno 파드가
#       죽어도 파드 배포가 막히지 않는다 (가용성 > 정책 계량의 트레이드오프)
#
#   면접 포인트: "PSA는 3단계 고정 프로파일만 제공한다. 조직 커스텀 정책
#   (레지스트리 화이트리스트, 라벨 강제, 이미지 서명 검증 등)이 필요해지는
#   시점에 Kyverno/OPA로 넘어가는데, 그 기반을 미리 깔고 PolicyReport 기반
#   준수 측정부터 시작했다"
# =============================================================================

resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true

  cleanup_on_fail = true
  # destroy 시 NAT 경로보다 먼저 정리 — 다른 helm_release와 동일 패턴.
  # aws_load_balancer_controller: 그 컨트롤러의 mutating webhook이 클러스터 전역
  # Service 생성을 가로채므로, 컨트롤러 파드가 준비되기 전에 Kyverno의 Service를
  # 만들면 "no endpoints available for aws-load-balancer-webhook-service"로 실패
  # (external-dns와 동일한 이유 — 2026-08-03 1차 apply에서 실제 발생, 순서 고정)
  depends_on = [
    module.eks,
    module.nat_instance,
    aws_route.private_subnet,
    module.vpc,
    helm_release.aws_load_balancer_controller,
  ]

  values = [
    yamlencode({
      admissionController = {
        replicas = 1
        container = {
          resources = {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "384Mi" }
          }
        }
      }
      reportsController = {
        resources = {
          requests = { cpu = "50m", memory = "64Mi" }
          limits   = { memory = "256Mi" }
        }
      }
      # 안 쓰는 컨트롤러는 꺼서 t3.small 메모리 절약 (~2파드 분량)
      backgroundController = { enabled = false }
      cleanupController    = { enabled = false }
    })
  ]
}

# restricted 프로파일 전체를 Audit 모드로 — 위반 시 차단하지 않고 PolicyReport 기록
resource "helm_release" "kyverno_policies" {
  name       = "kyverno-policies"
  repository = "https://kyverno.github.io/kyverno/"
  chart      = "kyverno-policies"
  namespace  = "kyverno"

  cleanup_on_fail = true
  depends_on      = [helm_release.kyverno]

  values = [
    yamlencode({
      podSecurityStandard     = "restricted"
      validationFailureAction = "Audit" # 준비되면 "Enforce"로 승격 (PSA enforce 승격과 같은 시점에)
      background              = true    # 이미 떠 있는 파드도 리포트 대상에 포함
    })
  ]
}
