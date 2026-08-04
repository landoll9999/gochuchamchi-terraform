# =============================================================================
# ArgoCD + Image Updater
#   - gochuchamchi-gitops 저장소(Deployment/Service/HPA)를 감시해서 클러스터 상태를 자동 동기화
#   - ECR(ecr.tf의 aws_ecr_repository.gochuchamchi)에 새 이미지가 올라오면 태그를 감지해서
#     write-back(git commit)으로 gitops 저장소에 반영 (예전엔 Docker Hub 사용, 마이그레이션함)
#   - UI는 argocd.gochuchamchi.shop 서브도메인 (기존 앱과 동일하게 ALB가 TLS 종단)
# =============================================================================

locals {
  gitops_repo_url = "https://github.com/${var.argocd_github_owner}/${var.argocd_gitops_repo}.git"

  # "<account>.dkr.ecr.<region>.amazonaws.com" — repository_url에서 저장소 이름을 뗀 부분
  ecr_registry_host = split("/", aws_ecr_repository.gochuchamchi.repository_url)[0]
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true

  cleanup_on_fail = true
  # server.ingress가 만드는 ALB도 aws-load-balancer-controller의 webhook을 타므로,
  # external_dns와 동일한 이유로 컨트롤러 준비 완료 후 생성/삭제되도록 순서 고정
  depends_on = [module.eks, helm_release.aws_load_balancer_controller]

  values = [
    yamlencode({
      configs = merge(
        {
          params = {
            # ALB가 TLS를 종단하므로 argocd-server는 평문 HTTP로 서빙 (앱 Deployment와 동일 패턴)
            "server.insecure" = true
          }
        },
        # (2026-08-04 백로그 B4) admin 비밀번호를 bcrypt "해시"로 코드화.
        # UI에서 바꾼 비밀번호는 코드 밖 수동 조치라 재구축(destroy/apply)마다
        # 초기 비밀번호로 회귀했음(7/30 이력). 해시를 values로 넣으면 재구축에도
        # 유지되고, state에는 평문이 아니라 bcrypt 해시만 남는다.
        # 해시 생성(배스천 또는 아무 리눅스):
        #   sudo dnf install -y httpd-tools
        #   htpasswd -nbBC 10 "" '<새 비밀번호>' | tr -d ':\n'
        # 주입: $env:TF_VAR_argocd_admin_password_bcrypt = '<해시>' (variables.tf 참고)
        # 미설정(기본값 "")이면 기존 동작(initial-admin-secret) 그대로.
        var.argocd_admin_password_bcrypt != "" ? {
          secret = {
            argocdServerAdminPassword = var.argocd_admin_password_bcrypt
          }
        } : {}
      )
      server = {
        ingress = {
          enabled = true
          annotations = {
            "kubernetes.io/ingress.class" = "alb"
            # ArgoCD는 클러스터 admin급 권한 + gitops write-back PAT를 쥔 최고 가치
            # 타겟이라 인터넷 노출 대신 internal ALB로 전환. 접근은 SSM 포트포워딩 +
            # kubectl port-forward로 (private_subnet_tags의 internal-elb 태그로 자동 배치됨)
            "alb.ingress.kubernetes.io/scheme"          = "internal"
            "alb.ingress.kubernetes.io/target-type"     = "ip"
            "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
            "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
            "alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate_validation.this.certificate_arn
            # 앱 ingress(k8s-deploy.tf)와 동일하게 TLS 1.2/1.3만 허용
            # (미지정 시 ALB 기본 정책이 TLS 1.0/1.1까지 열어둠)
            "alb.ingress.kubernetes.io/ssl-policy" = "ELBSecurityPolicy-TLS13-1-2-2021-06"
          }
          # 이 차트 버전은 hosts(list)가 아니라 hostname(단수 string)을 씀 ->
          # hosts로 넣으면 조용히 무시되고 global.domain 기본값(argocd.example.com)이 적용됨
          hostname = "argocd.${var.domain_name}"
        }
      }
      # argocd-notifications-cm/-secret은 ../discord-notifications 디렉토리(별도 state)가
      # 전담 관리함 -> 차트가 이 둘을 만들면 여기 helm_release가 업그레이드될 때마다
      # 빈 기본값으로 덮어써서 Discord 설정이 사라지므로, 차트 쪽에서는 생성 자체를 끔
      notifications = {
        cm     = { create = false }
        secret = { create = false }
      }
    })
  ]
}

# ---------------------------------------------------------------------------
# 저장소 자격증명 Secret — (2026-08-04 백로그 B3로 "제거"됨. 왜 지웠는지가 중요해서 기록)
#   기존: kubernetes_secret_v1이 var.argocd_git_pat를 받아 Secret을 만들면서
#         PAT가 tfstate에 평문 저장 — 감사 #1의 ESO 트리거가 발동된 상태였음.
#         PAT는 gitops write 권한이라 탈취 시 "gitops 커밋 -> ArgoCD 자동 배포"
#         공급망 경로가 열리는 최고가치 시크릿.
#   현재: Secrets Manager(gochuchamchi/argocd/git-pat, 값은 CLI 1회 주입) ->
#         ESO가 동기화 (eso.tf + charts/eso-config). Secret 이름/라벨/키는 동일해서
#         ArgoCD·Image Updater 쪽 변경 없음. TF_VAR_argocd_git_pat도 더 이상 불필요.
# ---------------------------------------------------------------------------

# ArgoCD Application CR. alekc/kubectl 같은 프로바이더로 직접 만들면 클러스터가
# 아직 없는 첫 apply 시점에 host 값이 "known after apply"라 plan 단계에서 바로
# 에러가 나는 것을 실제로 확인함 -> 이미 이 프로젝트에서 검증된 hashicorp/helm
# 프로바이더로 감싸서(로컬 차트 하나만 있는 helm_release) 동일한 부트스트랩 패턴을 재사용.
resource "helm_release" "gochuchamchi_application" {
  name      = "gochuchamchi-application"
  chart     = "${path.module}/charts/gochuchamchi-application"
  namespace = "argocd"

  # ImageUpdater CR(templates/imageupdater.yaml)이 참조하는 CRD가 argocd_image_updater
  # 차트로 설치되므로, 그 차트가 먼저 적용된 뒤에 이 차트를 적용해야 함.
  # 저장소 자격증명은 ESO가 동기화하므로(eso_config) 그 뒤에 Application을 만든다.
  depends_on = [helm_release.argocd, helm_release.eso_config, helm_release.argocd_image_updater]

  values = [
    yamlencode({
      repoURL              = local.gitops_repo_url
      gitBranch            = "main"
      destinationNamespace = "gochuchamchi"
      appImage             = aws_ecr_repository.gochuchamchi.repository_url
    })
  ]
}

resource "helm_release" "argocd_image_updater" {
  name       = "argocd-image-updater"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-image-updater"
  namespace  = "argocd"

  cleanup_on_fail = true
  # aws-load-balancer-controller의 webhook이 준비되기 전에 이 chart의 Service가
  # 생성되면 webhook 호출이 막혀 helm이 기본 5분 타임아웃(context deadline exceeded)에
  # 걸리는 문제가 있었음 -> 순서 보장 + 여유 있는 타임아웃으로 완화
  depends_on = [helm_release.argocd, helm_release.aws_load_balancer_controller, module.image_updater_ecr_pod_identity]
  timeout    = 600

  values = [
    yamlencode({
      # ECR은 docker.io/ghcr.io처럼 자동 인식되는 레지스트리가 아니라서(공식 문서에도
      # "ECR이 ext: 스크립트 credential이 필요한 대표 사례"라고 명시됨) 커스텀 등록 필요.
      # aws ecr get-login-password는 12시간짜리 토큰을 발급하므로 credsexpire로 여유있게 갱신.
      config = {
        registries = [
          {
            name = "ECR"
            # repository_url은 "<host>/<repo>" 형태라 그대로 쓰면 저장소 경로까지 API
            # 엔드포인트에 섞여 들어감 -> api_url/prefix 모두 레지스트리 호스트까지만 사용
            api_url     = "https://${local.ecr_registry_host}"
            prefix      = local.ecr_registry_host
            ping        = true
            insecure    = false
            credentials = "ext:/scripts/ecr-auth.sh"
            credsexpire = "10h"
          }
        ]
      }
      # authScripts는 차트가 제공하는 기능 - scripts 아래 내용을 ConfigMap으로 만들어
      # /scripts 경로에 자동 마운트해줌 (Azure/ECR 인증 스크립트 용도로 공식 문서에 안내됨).
      # argocd-image-updater 이미지는 alpine 기반이고 Dockerfile에서 aws-cli를 이미
      # 설치해두므로(v1.2.2 태그에서 확인), 별도 initContainer로 CLI를 넣을 필요 없음.
      # 인증 자체는 eks-pod-identity.tf의 image_updater_ecr_pod_identity가 붙여준
      # IAM 권한으로 이뤄짐 (ECR 토큰 사용자명은 항상 고정값 "AWS").
      authScripts = {
        enabled = true
        scripts = {
          "ecr-auth.sh" = <<-EOT
            #!/bin/sh
            echo "AWS:$(aws ecr get-login-password --region ${var.region})"
          EOT
        }
      }
    })
  ]
}

# 초기 비밀번호는 UI에서 변경하는 순간 ArgoCD가 argocd-initial-admin-secret을 삭제한다.
# data source로 값을 직접 출력하면 그 시점부터 plan이 깨지므로 명령어만 내보낸다.
# ※ TF_VAR_argocd_admin_password_bcrypt를 설정했다면(백로그 B4) 초기 Secret은 의미가
#   없고, 해시의 원본 비밀번호로 로그인한다.
output "argocd_admin_password_command" {
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  description = "ArgoCD 초기 admin 비밀번호 조회 명령 (bcrypt 해시를 코드로 지정한 경우에는 해당 없음 — argocd.tf B4 주석 참고)"
}
