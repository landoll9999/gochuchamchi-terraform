# =============================================================================
# External Secrets Operator (2026-08-04 백로그 B3)
#
# 왜 도입하나 — 감사 #1이 정한 "state에 secret_string이 다시 들어가는 시점 = ESO
# 도입 트리거"가 ArgoCD PAT(구 argocd.tf의 kubernetes_secret_v1)로 발동된 상태였음.
#
# 구조 전환:
#   기존:  TF_VAR_argocd_git_pat -> terraform이 K8s Secret 생성 -> tfstate에 PAT 평문
#   현재:  Secrets Manager(값은 사람이 CLI로 1회 주입) -> 클러스터 안의 ESO가 직접
#          동기화 -> Terraform은 값이 빈 Secret "컨테이너"만 관리 (db-zero-trust.tf의
#          앱 DB 비밀번호와 동일한 원칙) -> PAT가 state에 안 들어감
#
# 최초 1회 (또는 PAT 로테이션 시) — 로컬에서:
#   aws secretsmanager put-secret-value --secret-id gochuchamchi/argocd/git-pat `
#     --secret-string "<GitHub PAT>" --region ap-northeast-2 --profile admin
#   ※ 기존 PAT는 state에 노출됐던 값이므로 이 기회에 재발급(로테이션)해서 넣을 것.
#   ※ 값을 넣기 전까지 ExternalSecret은 SecretSyncedError로 재시도만 반복(무해)하고,
#     ArgoCD 저장소 연결이 안 될 뿐 클러스터는 정상 동작함.
#
# Redis auth_token은 ESO로 못 뺀다 — aws_elasticache_replication_group의 "리소스
# 인자"라서 Terraform이 값을 직접 넣어야 하고, 따라서 state 잔존이 구조적으로
# 불가피함 (redis.tf 주석 참고). ESO가 해결하는 건 "Terraform이 값을 K8s Secret으로
# 나르면서 생기는" 노출이며, PAT가 정확히 그 케이스였음.
# =============================================================================

# PAT 컨테이너 — 값은 위 명령으로 사람이 넣고, Terraform은 값을 절대 읽지 않음
resource "aws_secretsmanager_secret" "argocd_git_pat" {
  name        = "gochuchamchi/argocd/git-pat"
  description = "gochuchamchi-gitops GitHub PAT (Contents: Read/write). Value injected manually via CLI, synced to K8s by ESO — never touched by Terraform."

  # db-zero-trust.tf의 app_db와 동일: 실습용이라 destroy 후 즉시 재생성 가능하게 0일
  recovery_window_in_days = 0
}

# ESO 컨트롤러가 이 스택의 시크릿"만" 읽도록 정확한 ARN으로 제한
# (iamRole.tf에서 rds!* 와일드카드를 걷어낸 것과 같은 원칙)
module "eso_pod_identity" {
  source = "terraform-aws-modules/eks-pod-identity/aws"
  name   = "gochuchamchi-eso"

  attach_custom_policy = true
  policy_statements = [
    {
      sid     = "ReadDesignatedSecretsOnly"
      actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [
        aws_secretsmanager_secret.argocd_git_pat.arn,
        # 앱 DB 시크릿도 나중에 ESO로 이관할 수 있게 미리 포함 (DB_SECRET_SETUP.md)
        aws_secretsmanager_secret.app_db.arn,
      ]
    }
  ]

  associations = {
    eso = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-secrets"
      service_account = "external-secrets"
    }
  }
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true

  cleanup_on_fail = true
  # 이 차트도 webhook Service를 만들므로 aws-load-balancer-controller의 mutating
  # webhook 준비 이후에 설치 (external-dns와 동일한 이유). destroy 시 NAT 경로
  # 순서는 LB controller의 depends_on 체인이 이미 보장함.
  depends_on = [module.eso_pod_identity, module.eks, helm_release.aws_load_balancer_controller]

  set = [
    # Pod Identity association(위 모듈)과 SA 이름이 정확히 일치해야 IAM이 붙는다
    { name = "serviceAccount.name", value = "external-secrets" },
  ]
}

# ClusterSecretStore/ExternalSecret CR 적용. alekc/kubectl 대신 로컬 차트 helm_release로
# 감싸는 이유는 charts/gochuchamchi-application과 동일 — 첫 apply 시점에 클러스터 접속
# 정보가 "known after apply"라 CR 전용 프로바이더는 plan에서 깨짐 (검증된 패턴 재사용).
resource "helm_release" "eso_config" {
  name      = "gochuchamchi-eso-config"
  chart     = "${path.module}/charts/eso-config"
  namespace = "external-secrets"

  # CRD·webhook은 external_secrets 차트가, 대상 네임스페이스(argocd)는 argocd 차트가 만듦
  depends_on = [helm_release.external_secrets, helm_release.argocd]

  values = [
    yamlencode({
      region        = var.region
      patSecretName = aws_secretsmanager_secret.argocd_git_pat.name
      repoURL       = local.gitops_repo_url
      username      = var.argocd_github_owner
    })
  ]
}

output "argocd_git_pat_inject_command" {
  value       = "aws secretsmanager put-secret-value --secret-id ${aws_secretsmanager_secret.argocd_git_pat.name} --secret-string '<GitHub PAT>' --region ${var.region} --profile ${var.aws_profile}"
  description = "PAT 주입/로테이션 명령 (최초 1회 필수). ESO가 1시간 주기 + 에러 재시도로 동기화함"
}
