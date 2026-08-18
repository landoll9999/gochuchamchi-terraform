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
#   t3.small 2대 리소스 절충과 Deny 승격 준비:
#     - admission/reports 컨트롤러만 켜고 background/cleanup 컨트롤러는 끔
#       (mutate-existing/generate/cleanup 정책을 안 쓰므로 불필요)
#     - Audit에서는 admission 1대로 비용을 아끼고, 이미지 서명을 Deny로 올리면
#       admission 3대 + PDB(minAvailable=2)를 자동 적용한다.
#     - restricted 계량 정책의 webhook failurePolicy는 Ignore를 유지한다. 이미지
#       서명 정책만 Deny에서 Fail로 바뀌며, 위 HA 설정이 그 fail-closed 경로를 보호한다.
#
#   ⚠️ validationFailureAction과 failurePolicy는 다른 것이다 (2026-08-04에 혼동으로 사고)
#     - validationFailureAction=Audit : 정책을 "위반한" 요청을 차단하지 않고 기록만
#     - failurePolicy=Fail            : "웹훅에 연결 자체가 안 되면" 요청을 거부
#     Audit으로 뒀다고 안전한 게 아니다. 차트 기본값이 failurePolicy=Fail이라
#     Kyverno가 사라지면 남은 웹훅이 클러스터의 모든 변경 요청을 막는다.
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
  version          = "3.8.2"
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
    module.kyverno_ecr_pod_identity,
  ]

  values = [
    yamlencode({
      # 차트 기본값은 text(ANSI 색상 코드 포함)·verbosity 2인데, verbosity 2는
      # TRACE까지 stderr로 내보낸다. reports-controller가 시스템 DaemonSet을
      # 재평가할 때마다 "failed to apply rule" TRACE가 찍혀 CloudWatch ERROR
      # 패널을 도배했다(2026-08-18). json은 색상 코드 제거, verbosity 1은 v=2
      # 트레이스 억제 — 에러·경고·감사 이벤트는 그대로 나온다.
      features = {
        logging = {
          format    = "json"
          verbosity = 1
        }
      }
      admissionController = {
        # (v8 병합, main 브랜치 보안 작업) Kyverno가 권장하는 HA 최소 수는 3대다.
        # 서명 정책이 Audit인 동안에는 기존 비용 절충(1대)을 유지하고,
        # Deny(fail-closed)를 선택하는 순간 replicas 3 + PDB로 함께 확장한다 —
        # 웹훅 응답자가 전멸하면 클러스터 admission이 잠기는 경로를 보호.
        replicas = var.image_signature_validation_action == "Deny" ? 3 : 1
        podDisruptionBudget = {
          enabled      = var.image_signature_validation_action == "Deny"
          minAvailable = var.image_signature_validation_action == "Deny" ? 2 : 1
        }
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
  version    = "3.8.1"
  namespace  = "kyverno"

  cleanup_on_fail = true
  depends_on      = [helm_release.kyverno]

  values = [
    yamlencode({
      podSecurityStandard     = "restricted"
      validationFailureAction = "Audit" # 준비되면 "Enforce"로 승격 (PSA enforce 승격과 같은 시점에)
      background              = true    # 이미 떠 있는 파드도 리포트 대상에 포함

      # 차트 기본값은 Fail. 그대로 두면 Kyverno가 없을 때 API 서버가 모든 변경을
      # 거부한다 — Kyverno의 resource webhook은 helm이 만드는 게 아니라 컨트롤러가
      # 런타임에 등록하므로, helm uninstall 후에도 웹훅만 클러스터에 남기 때문이다.
      #
      # 2026-08-04 destroy가 실제로 이것 때문에 막혔다 (docs/2026-08-04.md §6):
      #   kyverno 서비스 삭제 -> 웹훅만 잔존 -> "failed calling webhook
      #   validate.kyverno.svc-fail: service kyverno-svc not found"
      #   -> 파드 삭제 불가 -> 네임스페이스 Terminating 고착 -> helm uninstall 실패
      #
      # Ignore면 웹훅이 고아가 돼도 요청이 그냥 통과한다. 이 chart는 restricted
      # 준수 현황을 Audit으로 계량하는 용도이므로 Ignore를 유지한다. 별도의 이미지
      # 서명 정책은 Deny 승격 시 failurePolicy=Fail과 admission HA를 함께 적용한다.
      failurePolicy = "Ignore"

      # 시스템 DaemonSet(kube-proxy·aws-node·fluent-bit·neuron-monitor)은 hostPath가
      # 동작 요건이라 이 정책을 구조적으로 통과할 수 없다 — 고칠 수 없는 대상이
      # 재평가마다 fail을 만들어 PolicyReport 현황판만 오염시킨다(2026-08-18).
      # kinds를 Pod로 적는 이유: autogen이 규칙을 DaemonSet 등 컨트롤러용으로 변환할
      # 때 exclude도 함께 변환된다(로그의 autogen-host-path가 그 규칙). 앱 네임스페이스는
      # 계속 계량 대상이므로 restricted 준수 측정이라는 원래 목적은 훼손되지 않는다.
      policyExclude = {
        "disallow-host-path" = {
          any = [
            {
              resources = {
                kinds      = ["Pod"]
                namespaces = ["kube-system", "amazon-cloudwatch"]
              }
            }
          ]
        }
      }
    })
  ]
}
