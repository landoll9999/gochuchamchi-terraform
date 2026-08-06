# =============================================================================
# apply 후 검증 파이프라인  — 2026-08-04 자동화 2/3, 2026-08-05 대기 단계 추가
#
#   1/2  null_resource.wait_for_app_ready   앱이 실제로 뜰 때까지 기다린다
#   2/2  null_resource.post_apply_smoke_test 뜬 뒤에 상태를 검사한다
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

# =============================================================================
# apply 마지막 단계 1/2 — 앱이 실제로 뜰 때까지 대기  (2026-08-05)
#
# 왜 필요한가 — apply는 "AWS 리소스를 다 만들었다"에서 끝나지만, 앱 자체는 ArgoCD가
# GitOps 저장소를 읽어 배포하므로 apply 완료 시점에는 아직 파드가 없다. 그래서
# apply 직후 사이트를 열면 503("Backend service does not exist")이 뜨고, 사용자
# 입장에서는 "성공했다는데 왜 안 되냐"가 된다. 2026-08-05 재구축이 정확히 이랬다.
#
# 무엇을 기다리나 — Terraform은 이 Deployment를 만들지 않으므로 의존성으로 표현할 수
# 없다. 그래서 (1) ArgoCD가 Deployment를 만들 때까지 폴링하고, (2) 나타나면
# `kubectl rollout status`로 Ready까지 기다린다.
#
# 기본은 경고 모드(enforce = false) — 재구축 직후에는 앱이 안 뜨는 게 "정상"인 경우가
# 있다(GitOps 저장소가 비었거나, PAT를 아직 안 넣었거나). 여기서 apply를 실패시키면
# 재구축 자체가 막히므로 기본은 사유만 출력한다. 운영 중 변경에는 강제를 켠다:
#   $env:TF_VAR_wait_for_app_ready_enforce = "true"; terraform apply
# =============================================================================

variable "wait_for_app_ready" {
  description = "apply 마지막에 앱 파드가 Ready 될 때까지 기다릴지 여부"
  type        = bool
  default     = true
}

variable "wait_for_app_ready_enforce" {
  description = "앱이 시간 안에 뜨지 않으면 apply를 실패로 처리할지 여부 (false = 경고만)"
  type        = bool
  default     = false
}

variable "wait_for_app_ready_timeout_seconds" {
  description = "앱 Ready 대기 제한 시간(초). ArgoCD sync + 이미지 pull + Spring 기동(약 40초) + 노드 스케일업까지 감안"
  type        = number
  default     = 600
}

locals {
  # 계약의 pod_labels를 kubectl -l 셀렉터 문자열로 (예: app=gochuchamchi-web)
  app_ready_selector = join(",", [for k, v in local.deployment_contract.pod_labels : "${k}=${v}"])
}

resource "null_resource" "wait_for_app_ready" {
  count = var.wait_for_app_ready ? 1 : 0

  triggers = {
    always_run = timestamp()
  }

  depends_on = [
    module.eks,
    kubernetes_ingress_v1.gochuchamchi_web,
    kubernetes_network_policy_v1.gochuchamchi_web_allow,
    null_resource.provision_app_db_user,
    null_resource.inject_git_pat,        # PAT가 먼저 들어가야 ArgoCD가 저장소에 붙는다
    null_resource.sync_kubeconfig,       # 아래 kubectl들이 새 클러스터를 보게 한다 (ci-sync.tf)
    null_resource.verify_ecr_has_image,  # 이미지가 없으면 기다려도 안 뜬다 — 먼저 알린다
    helm_release.eso_config,
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $ns       = '${local.deployment_contract.namespace}'
      $selector = '${local.app_ready_selector}'
      $timeout  = ${var.wait_for_app_ready_timeout_seconds}
      $enforce  = ('${var.wait_for_app_ready_enforce}' -eq 'true')

      function Stop-Wait([string]$Message) {
        Write-Host $Message
        if ($enforce) { Write-Error "앱 준비 실패 (enforce 모드) — apply를 실패로 처리합니다."; exit 1 }
        Write-Host "경고 모드이므로 apply는 계속 진행합니다 (강제하려면 TF_VAR_wait_for_app_ready_enforce=true)."
        exit 0
      }

      if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        Stop-Wait "kubectl이 없어 앱 준비 대기를 건너뜁니다."
      }

      # 재구축으로 클러스터가 새로 생기면 kubeconfig가 옛 엔드포인트를 가리킨다.
      # 이때 증상은 인증 실패가 아니라 DNS 해석 실패(no such host)라 원인을 오해하기 쉽다.
      $null = kubectl get namespace $ns 2>$null
      if ($LASTEXITCODE -ne 0) {
        Stop-Wait "클러스터에 접속할 수 없습니다 — kubeconfig가 옛 클러스터를 가리킬 수 있습니다.`n  aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile ${var.aws_profile}"
      }

      # 1) ArgoCD가 Deployment를 만들 때까지
      $deadline = (Get-Date).AddSeconds($timeout)
      $deploy = $null
      while ((Get-Date) -lt $deadline) {
        $out = (kubectl get deploy -n $ns -l $selector -o name 2>$null)
        if ($LASTEXITCODE -eq 0 -and $out) { $deploy = (($out -split "`n") | Where-Object { $_ } | Select-Object -First 1).Trim(); break }
        Write-Host "ArgoCD가 아직 Deployment를 만들지 않았습니다 — 대기 중... (남은 $([int](($deadline - (Get-Date)).TotalSeconds))초)"
        Start-Sleep -Seconds 15
      }

      if (-not $deploy) {
        # 원인이 여러 갈래라 "확인 순서"까지 적는다. 2026-08-06에는 ECR이 비어 있었고
        # (destroy가 이미지까지 지움) 동시에 ArgoCD가 리소스 부족으로 죽어 있어서,
        # PAT만 의심하다가 진단이 길어졌다.
        Stop-Wait ("제한 시간 안에 Deployment($selector)가 나타나지 않았습니다.`n" +
          "  흔한 원인 3가지 — 위에서부터 순서대로 확인하세요.`n" +
          "   1) ECR에 signed- 이미지가 없음 (destroy가 지움) : 이번 apply 로그의 'ECR 확인' 단계 참고`n" +
          "   2) ArgoCD가 저장소에 못 붙음 (PAT 미주입)       : kubectl get externalsecret -n argocd`n" +
          "   3) ArgoCD 자체가 죽어 있음 (노드 리소스 부족)    : kubectl get pods -n argocd  /  kubectl top nodes`n" +
          "  공통 확인: kubectl get application -n argocd -o wide")
      }

      # 2) Ready까지. 남은 시간을 넘기되 최소 30초는 준다.
      $remain = [int](($deadline - (Get-Date)).TotalSeconds)
      if ($remain -lt 30) { $remain = 30 }
      # $remain초 로 쓰면 PowerShell이 "초"까지 변수명으로 먹어 빈 값이 된다
      # (변수명에 유니코드가 허용되기 때문). 한글이 바로 붙을 땐 $() 로 끊을 것.
      Write-Host "$deploy 롤아웃 대기 중 (최대 $($remain)초)..."
      kubectl rollout status $deploy -n $ns --timeout "$($remain)s"
      if ($LASTEXITCODE -ne 0) {
        Stop-Wait "앱이 제한 시간 안에 Ready 되지 않았습니다.`n  확인: kubectl get pod -n $ns  /  kubectl get events -n $ns --sort-by=.lastTimestamp"
      }

      Write-Host "앱 준비 완료 — $deploy"
    EOT
  }
}


# =============================================================================
# apply 마지막 단계 2/2 — 스모크 테스트
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

# 기본이 true인 이유 — Pod Identity 자격증명이 누락된 파드는 재시작 말고 고칠 방법이
# 없다(주입은 파드 생성 시 1회뿐). 그대로 두면 그 파드의 AWS 호출은 영원히 실패하므로,
# 검출과 복구를 분리할 실익이 없다. 재시작을 원치 않으면 false로 두면 FAIL만 보고한다.
variable "pod_identity_autofix" {
  description = "스모크 테스트 #13에서 Pod Identity 자격증명 미주입 파드를 찾으면 워크로드를 자동 재시작할지 여부"
  type        = bool
  default     = true
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
    null_resource.wait_for_app_ready,    # 앱이 뜬 뒤에 검사해야 결과가 의미 있다
  ]

  provisioner "local-exec" {
    # -ExecutionPolicy Bypass — 이 프로비저너는 인라인 명령이 아니라 .ps1 "파일"을
    # 실행한다. CurrentUser 정책이 RemoteSigned이고 git/다운로드로 받은 파일에는
    # Zone.Identifier(인터넷 출처 표시)가 붙어 있어서, 서명 없는 스크립트가
    # "not digitally signed"로 차단된다(2026-08-05 apply 실패).
    # Unblock-File은 파일이 새로 받아질 때마다 다시 해야 하므로, 재현되지 않도록
    # 호출 쪽에서 정책을 우회한다. (프로세스 범위 한정 — 시스템 정책은 안 바뀜)
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    working_dir = path.module

    # 계약(JSON)을 인자로 넘긴다 — apply 도중에는 state가 아직 확정 전이라
    # 스크립트가 `terraform output`을 호출하면 옛 값을 읽거나 실패한다.
    # 작은따옴표 이스케이프: JSON 값에 '가 들어갈 여지는 없지만 방어적으로 처리.
    # 한 줄로 유지 — 여러 줄 + 백틱 연결은 PowerShell -Command 로 넘길 때 개행 처리에
    # 따라 깨질 수 있어서, 길더라도 단일 명령 문자열이 안전하다.
    command = "& '${path.module}/../scripts/smoke-test.ps1' -ContractJson '${replace(jsonencode(local.deployment_contract), "'", "''")}' -Region '${var.region}' -AwsProfile '${var.aws_profile}' ${var.smoke_test_enforce ? "-Enforce" : ""} ${var.pod_identity_autofix ? "-FixPodIdentity" : ""}"
  }
}
