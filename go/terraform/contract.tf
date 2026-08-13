# =============================================================================
# 배포 계약 (Deployment Contract)  — 2026-08-04 자동화 1/3
#
# 왜 만드나
#   2026-08-04 장애의 근본원인은 "terraform apply와 gitops 수정이 한 세트인 작업에서
#   gitops 쪽만 누락"이었다. terraform이 K8s Secret 이름을
#   gochuchamchi-db-secret -> gochuchamchi-db-app 으로 바꿨는데, gitops의
#   03-deployment-web.yml은 옛 이름을 계속 참조 -> 새 파드는
#   CreateContainerConfigError, 기존 파드는 평문 접속 거부로 500. 이중 잠김.
#
#   그때의 교훈이 "체크리스트가 문서에 있어도 강제 장치가 없으면 누락된다"였다.
#   그래서 두 저장소 사이의 인터페이스를 사람이 기억하는 대신 **코드가 선언**하게 한다.
#   이 output이 곧 "terraform이 만들어주는 것 / gitops가 참조해야 하는 것"의 계약서다.
#
# 어떻게 쓰나
#   1) 사람이 볼 때:      terraform output -json deployment_contract
#   2) 자동 검증(수동실행): ..\scripts\verify-contract.ps1 -GitopsPath <gitops 클론 경로>
#   3) 자동 검증(apply 후): smoke-test.tf 의 null_resource가 이 값을 스크립트에 넘겨
#                          "클러스터에 실제로 존재하는지 + 파드가 참조하는 이름이
#                          계약 안에 있는지"를 검사
#   4) (다음 단계) GitHub Actions에서 gitops PR 시 이 JSON과 대조해 머지 차단
#
# 주의 — 이 파일에는 "값"이 아니라 "이름/키"만 넣는다. 비밀값을 넣으면 output이
#   그대로 tfstate·CLI에 노출되어 db-zero-trust.tf/eso.tf로 없앤 노출 경로가 부활한다.
#   (kubernetes_secret_v1.data 는 provider가 sensitive로 표시하므로 keys()로 뽑으면
#    output 자체가 거부된다 — 그래서 secrets의 keys는 의도적으로 문자열 리터럴)
# =============================================================================

locals {
  deployment_contract = {
    # 계약 버전 — 필드를 깨는 변경(이름 삭제/키 변경)을 할 때 올린다.
    # gitops 쪽 검증 스크립트가 모르는 버전을 만나면 경고하도록 하기 위한 장치.
    version = 1

    cluster_name    = module.eks.cluster_name
    namespace       = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
    service_account = kubernetes_service_account_v1.gochuchamchi_app.metadata[0].name

    # ---- terraform이 만들어 주는 것 (gitops는 "참조만" 한다) --------------------
    config_maps = [
      {
        name  = kubernetes_config_map_v1.gochuchamchi_config.metadata[0].name
        keys  = sort(keys(kubernetes_config_map_v1.gochuchamchi_config.data))
        owner = "terraform (k8s-deploy.tf)"
      }
    ]

    secrets = [
      # (2026-08-13) gochuchamchi-db-app 이 목록에서 빠졌다. IAM 토큰 전환으로 앱
      # DB 비밀번호가 없어졌고, 그 Secret 을 만들던 배스천 프로비저닝도 제거했다.
      # 아래 forbidden_refs 로 옮겼다 — gitops 가 계속 참조하면 검증에서 잡힌다.
      {
        name  = kubernetes_secret_v1.gochuchamchi_redis_secret.metadata[0].name
        keys  = ["SPRING_DATA_REDIS_PASSWORD"]
        owner = "terraform (k8s-deploy.tf)"
      },
    ]

    # ---- gitops가 만들어야 하는 것 (terraform이 이 이름을 참조한다) -------------
    # Ingress(k8s-deploy.tf)가 이 Service 이름으로 백엔드를 잡으므로, gitops에서
    # 이름이 바뀌면 ALB 타겟이 사라진다(= 503). 반대 방향의 계약.
    service = {
      name = "gochuchamchi-web-svc"
      port = 80
    }

    # NetworkPolicy(k8s-network-policies.tf)의 pod_selector와 반드시 일치해야 한다.
    # 라벨이 어긋나면 정책이 아무 파드에도 안 걸리고(무해해 보이지만) default-deny만
    # 남아 앱이 전부 죽는다.
    pod_labels     = { app = "gochuchamchi-web" }
    container_port = 8080

    # ---- 참조해서는 안 되는 이름 (과거 계약의 잔재) ----------------------------
    # 8/4 장애의 직접 원인. 지운 이름을 "지웠다"고 기록해두지 않으면 다음 사람이
    # 옛 문서를 보고 되살린다. 검증 스크립트는 이 이름이 gitops에 남아 있으면 실패시킨다.
    forbidden_refs = [
      "gochuchamchi-db-secret", # 마스터 계정 시절의 Secret (제로트러스트 전환으로 삭제)
      # (2026-08-13) 앱 전용 비밀번호 계정 시절의 Secret. IAM 토큰 전환으로 계정도
      # 비밀번호도 없앴다. gitops 가 이걸 envFrom 으로 계속 참조하면 Secret 이
      # 존재하지 않아 파드가 CreateContainerConfigError 로 못 뜬다 — 8/4 장애와
      # 정확히 같은 실패 방식이다. 그래서 gitops 수정이 이 커밋보다 먼저다.
      "gochuchamchi-db-app",
    ]

    # ---- 재구축마다 바뀌는 값 (gitops에 하드코딩하면 안 되는 것들) --------------
    # ConfigMap을 통해 주입되므로 gitops는 이 값을 몰라야 정상이다.
    # 스모크 테스트가 DNS/TCP 도달성을 확인할 때 사용한다.
    endpoints = {
      db_host    = data.aws_db_instance.this.address
      redis_host = aws_elasticache_replication_group.this.primary_endpoint_address
      hosts      = [var.domain_name, "www.${var.domain_name}"]
    }
  }
}

output "deployment_contract" {
  value       = local.deployment_contract
  description = <<-EOT
    terraform <-> gochuchamchi-gitops 사이의 인터페이스 계약.
    사용: terraform output -json deployment_contract | Set-Content contract.json
          ..\scripts\verify-contract.ps1 -GitopsPath <gitops 저장소 경로>
  EOT
}
