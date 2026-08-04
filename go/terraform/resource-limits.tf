# =============================================================================
# LimitRange + ResourceQuota — 리소스 폭주 방어 (2026-08-03)
#
#   문제: t3.small(2GiB, allocatable ~1.4GiB) 2대에서 limits 없는 파드 하나가
#   메모리를 무한정 먹으면 kubelet이 시스템 파드까지 눌러 노드 전체가 NotReady로
#   떨어질 수 있다 (OOMKill 순서는 QoS 클래스 기준 — limits 없는 BestEffort/
#   Burstable 파드가 많을수록 노드가 불안정해짐).
#
#   2단 방어:
#     1. LimitRange — requests/limits를 안 적은 컨테이너에 기본값을 "자동 주입".
#        gitops 저장소의 Deployment가 limits를 빠뜨려도 안전값이 들어간다.
#     2. ResourceQuota — 네임스페이스 총량 상한. HPA가 폭주하거나 파드가 대량
#        생성돼도 노드 용량을 넘는 예약 자체가 거부된다.
#        ⚠️ ResourceQuota가 걸린 네임스페이스에서 requests/limits 없는 파드는
#        생성이 "거부"된다 — LimitRange의 기본값 주입이 먼저 실행되므로
#        (admission 순서: LimitRange → ResourceQuota) 실제로는 거부될 일이 없다.
#        이 조합이 사실상 "limits 필수화"를 코드 수정 없이 달성하는 방법.
#
#   수치 근거 (t3.small 2대, max 4대):
#     - Spring Boot 앱: JVM 힙 + 메타스페이스 감안 요청 256Mi / 상한 768Mi
#     - 총량: 노드 4대 풀스케일 기준 allocatable(~5.6GiB)의 약 70%를 앱
#       네임스페이스에 허용 — 시스템/모니터링 파드 몫을 남겨둠
#
#   면접 포인트: "QoS 클래스(BestEffort→Burstable→Guaranteed 순으로 OOMKill)와
#   LimitRange 기본값 주입 → ResourceQuota 검증의 admission 순서까지 엮어서
#   설명하면 K8s 리소스 모델을 이해하고 있다는 신호가 된다"
# =============================================================================

resource "kubernetes_limit_range_v1" "gochuchamchi" {
  metadata {
    name      = "gochuchamchi-defaults"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of" = "container-security"
    }
  }

  spec {
    limit {
      type = "Container"

      # requests를 안 적은 컨테이너에 주입되는 기본 요청량
      default_request = {
        cpu    = "100m"
        memory = "256Mi"
      }

      # limits를 안 적은 컨테이너에 주입되는 기본 상한
      default = {
        cpu    = "500m"
        memory = "768Mi"
      }

      # 어떤 컨테이너도 이 이상은 선언 불가 (파드 하나가 노드 하나를 통째로 못 먹게)
      max = {
        cpu    = "1"
        memory = "1Gi"
      }
    }
  }
}

resource "kubernetes_resource_quota_v1" "gochuchamchi" {
  metadata {
    name      = "gochuchamchi-quota"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
    labels = {
      "app.kubernetes.io/part-of" = "container-security"
    }
  }

  spec {
    hard = {
      "pods"            = "20"
      "requests.cpu"    = "3"
      "requests.memory" = "3Gi"
      "limits.cpu"      = "6"
      "limits.memory"   = "6Gi"
    }
  }
}
