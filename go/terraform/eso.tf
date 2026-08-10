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

# PAT 컨테이너는 2026-08-06에 ../persistent 로 옮겼다.
#
# 왜 — 이 시크릿은 recovery_window_in_days = 0이라 destroy 때 값까지 즉시 사라졌다.
# 재구축하면 빈 컨테이너만 생기고, 사람이 값을 다시 넣기 전까지
# ESO -> ArgoCD -> 앱 배포가 통째로 멈춰 사이트가 503이 된다(2026-08-05, 08-06 연속 발생).
# 영속 state로 옮기면 PAT가 재구축을 건너 살아남아 이 단계 자체가 사라진다.
#
# 조회는 persistent-data.tf의 data.aws_secretsmanager_secret.argocd_git_pat 가 담당한다.
# 아래 자동 주입은 "값이 이미 있으면 건드리지 않는" 동작이라 그대로 두어도 충돌하지 않고,
# 시크릿을 새로 만든 경우(최초 구축)에만 실제로 값을 넣는다.

# ---------------------------------------------------------------------------
# PAT 자동 주입 (2026-08-05)
#
# 왜 만드나 — 위 시크릿은 recovery_window_in_days = 0이라 destroy 때 즉시 삭제되고,
# 안에 넣어둔 PAT 값도 함께 사라진다. 재구축하면 빈 컨테이너만 생기므로 사람이 값을
# 다시 넣기 전까지 ESO -> ArgoCD -> 앱 배포가 통째로 멈추고 사이트가 503
# ("Backend service does not exist")이 된다. 2026-08-05 재구축에서 실제로 이 상태였고,
# "apply는 성공했는데 서비스는 죽어 있는" 이 프로젝트의 대표적 실패 유형에 해당한다.
#
# 값은 여전히 Terraform을 거치지 않는다 — 환경변수를 local-exec 안에서 셸이 직접
# 읽으므로 terraform 변수에도, state에도, plan 출력에도 PAT가 들어가지 않는다.
# ESO 도입 취지(백로그 B3: state에 secret_string을 남기지 않는다)를 그대로 지키면서
# 수동 단계만 없앤다. TF_VAR_로 받으면 state에 평문이 남으므로 그 방식은 쓰지 않는다.
#
# 사용법 — apply 전에 셸에서 한 번:
#   $env:ARGOCD_GIT_PAT = "<GitHub PAT>"
# 환경변수가 없으면 조용히 건너뛴다(기존처럼 CLI로 직접 주입해도 된다).
#
# 이미 값이 있으면 덮어쓰지 않는다 — 로테이션은 "의도한 사람이 명시적으로" 해야 하는
# 작업이라 자동화 대상에서 뺐다. 낡은 환경변수가 세션에 남아 있다가 운영 중인 PAT를
# 조용히 옛 값으로 되돌리는 사고를 막기 위함이다.
# ---------------------------------------------------------------------------
resource "null_resource" "inject_git_pat" {
  triggers = {
    # 시크릿이 재생성되면 ARN 끝의 랜덤 접미사가 바뀐다 -> 재구축마다 다시 주입된다
    secret_arn = data.aws_secretsmanager_secret.argocd_git_pat.arn
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $secretId = '${data.aws_secretsmanager_secret.argocd_git_pat.name}'
      $region   = '${var.region}'
      $profile  = '${var.aws_profile}'

      if (-not $env:ARGOCD_GIT_PAT) {
        Write-Host "ARGOCD_GIT_PAT 환경변수가 없습니다 — PAT 자동 주입을 건너뜁니다."
        Write-Host "  값을 넣기 전까지 ArgoCD가 GitOps 저장소에 붙지 못해 앱이 배포되지 않습니다(503)."
        Write-Host "  수동 주입: aws secretsmanager put-secret-value --secret-id $secretId --secret-string '<PAT>' --region $region --profile $profile"
        exit 0
      }

      # 값(AWSCURRENT 버전)이 이미 있으면 건드리지 않는다.
      # 컨테이너만 있고 버전이 없으면 ResourceNotFoundException이 난다 — 그게 "빈 상태"의 신호다.
      $null = aws secretsmanager get-secret-value --secret-id $secretId --region $region --profile $profile 2>$null
      if ($LASTEXITCODE -eq 0) {
        Write-Host "PAT 값이 이미 있습니다 — 자동 주입을 건너뜁니다(로테이션은 수동)."
        exit 0
      }

      $null = aws secretsmanager put-secret-value --secret-id $secretId --secret-string "$env:ARGOCD_GIT_PAT" --region $region --profile $profile
      if ($LASTEXITCODE -ne 0) { Write-Error "PAT 주입 실패 — 자격증명/권한을 확인하세요."; exit 1 }
      Write-Host "PAT 주입 완료 (길이 $($env:ARGOCD_GIT_PAT.Length)) — ESO가 클러스터로 동기화합니다."
    EOT
  }
}


# ESO 컨트롤러가 이 스택의 시크릿"만" 읽도록 정확한 ARN으로 제한
# (iamRole.tf에서 rds!* 와일드카드를 걷어낸 것과 같은 원칙)
module "eso_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # (v8) 버전 핀
  name   = "gochuchamchi-eso"

  attach_custom_policy = true
  policy_statements = [
    {
      sid     = "ReadDesignatedSecretsOnly"
      actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [
        data.aws_secretsmanager_secret.argocd_git_pat.arn,
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

  # CRD·webhook은 external_secrets 차트가, 대상 네임스페이스(argocd)는 argocd 차트가 만듦.
  # inject_git_pat을 앞에 두는 이유 — ExternalSecret CR이 배포되는 시점에 값이 이미
  # 있어야 "첫 동기화"에서 바로 성공한다. 값이 없는 채로 CR이 뜨면 SecretSyncedError로
  # 떨어지고, refreshInterval이 1h이라 나중에 값을 넣어도 최대 1시간을 기다리게 된다
  # (2026-08-05에 force-sync 어노테이션으로 수동 재촉해야 했던 이유).
  depends_on = [helm_release.external_secrets, helm_release.argocd, null_resource.inject_git_pat]

  values = [
    yamlencode({
      region        = var.region
      patSecretName = data.aws_secretsmanager_secret.argocd_git_pat.name
      repoURL       = local.gitops_repo_url
      username      = var.argocd_github_owner
    })
  ]
}

output "argocd_git_pat_inject_command" {
  value       = "aws secretsmanager put-secret-value --secret-id ${data.aws_secretsmanager_secret.argocd_git_pat.name} --secret-string '<GitHub PAT>' --region ${var.region} --profile ${var.aws_profile}"
  description = "PAT 수동 주입/로테이션 명령. 재구축 시 자동 주입을 쓰려면 apply 전에 $env:ARGOCD_GIT_PAT를 설정할 것 (null_resource.inject_git_pat)"
}
