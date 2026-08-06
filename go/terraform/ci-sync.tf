# =============================================================================
# 재구축 후 "사람이 손으로 메우던 간극"을 apply 안으로 넣는다  — 2026-08-06
#
# 왜 만드나 — 2026-08-06 재구축 직후 사이트가 503이었다. apply는 성공했는데
# 서비스는 죽어 있었고, 원인은 terraform 바깥에 흩어져 있었다:
#
#   1) kubeconfig가 옛 클러스터를 가리킴
#        증상이 인증 실패가 아니라 DNS 실패(no such host)라 원인을 오해하기 쉽다.
#        운영자가 kubectl로 상태를 못 보니 진단 자체가 막힌다.
#
#   2) GitHub Actions 변수 IMAGE_SIGNING_KMS_KEY_ARN이 옛 KMS 키를 가리킴
#        재구축하면 KMS 키가 새로 생기는데(30일 삭제 대기로 옛 키는 PendingDeletion),
#        GitHub 쪽 값은 수동 관리라 그대로 남는다. 그 상태로 CI를 돌리면 서명 잡이
#        "PendingDeletion 키로 서명" 시도로 실패하고 -> ECR에 이미지가 안 올라가고
#        -> 앱이 배포되지 않아 503이 유지된다. 원인이 3단계 떨어져 있어 추적이 길다.
#
#   3) ECR이 비어 있음
#        force_delete = true 때문에 destroy가 이미지까지 지웠다.
#        이 원인 자체는 같은 날 ../persistent 로 state를 분리해 제거했다. 다만
#        "이미지가 없다"는 상태는 다른 경로로도(수동 삭제, lifecycle 만료, 최초 구축)
#        생길 수 있고 그때 증상은 똑같이 503이므로, 확인 단계는 그대로 둔다.
#
# 설계 원칙 — 1)과 2)는 자동으로 고친다(멱등, 부작용 없음). 3)은 자동 복구가 불가능
# (이미지를 만들 수 있는 건 CI뿐)하므로 진단만 한다. 어느 쪽도 apply를 실패시키지
# 않는다 — 재구축 도중에는 "아직 안 된 상태"가 정상이기 때문이다. smoke-test.tf가
# 세운 경고 모드 원칙을 그대로 따른다.
# =============================================================================

# -----------------------------------------------------------------------------
# 1/3 — kubeconfig를 방금 만든 클러스터로 갱신
#
# 이후 단계(wait_for_app_ready, smoke test)가 전부 kubectl에 의존하므로 가장 먼저
# 돈다. 재구축이 아니어도 매번 실행되지만 update-kubeconfig는 멱등이라 무해하다.
# -----------------------------------------------------------------------------
resource "null_resource" "sync_kubeconfig" {
  triggers = {
    # 클러스터가 새로 생기면 엔드포인트가 바뀐다 -> 재구축마다 다시 돈다.
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Host "aws CLI가 없어 kubeconfig 갱신을 건너뜁니다."
        exit 0
      }

      aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile ${var.aws_profile}
      if ($LASTEXITCODE -ne 0) {
        Write-Host "kubeconfig 갱신에 실패했습니다 — 아래를 직접 실행하세요."
        Write-Host "  aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region} --profile ${var.aws_profile}"
        exit 0
      }
      Write-Host "kubeconfig를 ${module.eks.cluster_name} 로 갱신했습니다."
    EOT
  }
}

# -----------------------------------------------------------------------------
# 2/3 — GitHub Actions 변수를 terraform이 만든 실제 값으로 동기화
#
# 왜 provider가 아니라 gh CLI인가 — integrations/github provider를 쓰려면 PAT를
# terraform 변수로 받아야 한다. 이 저장소는 이미 ArgoCD용 PAT를 Secrets Manager로
# 옮겨 "terraform 변수에 토큰을 두지 않는" 방향을 잡았고(eso.tf), 같은 목적에
# 두 번째 토큰 경로를 만들고 싶지 않다. gh CLI는 운영자가 이미 로그인해 둔
# 자격증명을 쓰므로 새 비밀이 늘지 않는다.
#
# 실패해도 apply는 계속한다 — gh가 없거나 로그인이 안 된 환경(CI 등)에서 apply가
# 막히면 안 된다. 대신 그 경우 수동 명령을 그대로 출력해서 복사·실행만 하면 되게 한다.
# -----------------------------------------------------------------------------
resource "null_resource" "sync_github_ci_variables" {
  triggers = {
    # 넷 중 하나라도 바뀌면(=재구축) 다시 동기화한다.
    ecr_repository_url = data.aws_ecr_repository.gochuchamchi.repository_url
    build_role_arn     = data.aws_iam_role.github_actions_ecr_push.arn
    signer_role_arn    = data.aws_iam_role.github_actions_image_signer.arn
    signing_key_arn    = data.aws_kms_key.image_signing.arn
  }

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      $repo = '${var.argocd_github_owner}/gochuchamchi-spring'
      $vars = [ordered]@{
        'ECR_REPOSITORY_URL'        = '${data.aws_ecr_repository.gochuchamchi.repository_url}'
        'AWS_ECR_BUILD_ROLE_ARN'    = '${data.aws_iam_role.github_actions_ecr_push.arn}'
        'AWS_IMAGE_SIGNER_ROLE_ARN' = '${data.aws_iam_role.github_actions_image_signer.arn}'
        'IMAGE_SIGNING_KMS_KEY_ARN' = '${data.aws_kms_key.image_signing.arn}'
      }

      function Show-Manual {
        Write-Host "GitHub 변수를 자동 동기화하지 못했습니다 — 아래를 직접 실행하세요."
        foreach ($k in $vars.Keys) {
          Write-Host "  gh variable set $k --repo $repo --body `"$($vars[$k])`""
        }
      }

      if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "gh CLI가 없습니다."
        Show-Manual
        exit 0
      }

      $null = gh auth status 2>&1
      if ($LASTEXITCODE -ne 0) {
        Write-Host "gh CLI에 로그인되어 있지 않습니다 (gh auth login)."
        Show-Manual
        exit 0
      }

      $failed = $false
      foreach ($k in $vars.Keys) {
        $null = gh variable set $k --repo $repo --body $vars[$k] 2>&1
        if ($LASTEXITCODE -ne 0) { $failed = $true; Write-Host "  $k 설정 실패" }
        else { Write-Host "  $k = $($vars[$k])" }
      }

      if ($failed) { Show-Manual; exit 0 }
      Write-Host "GitHub Actions 변수 4개를 현재 인프라 값으로 동기화했습니다."
    EOT
  }
}

# -----------------------------------------------------------------------------
# 3/3 — ECR에 배포 가능한 이미지가 있는지 확인
#
# 자동 복구는 불가능하다. 이미지를 만들 수 있는 주체는 CI뿐이고, CI는 서명까지
# 거쳐야 Kyverno 정책을 통과한다. 그래서 여기서는 "지금 비어 있다"는 사실과
# 복구 명령만 정확히 알려준다. 이 확인이 없으면 운영자는 ECR이 아니라 ArgoCD나
# 네트워크를 먼저 의심하게 되고, 실제로 2026-08-06에 그렇게 시간을 썼다.
#
# 왜 signed- 태그를 세는가 — Image Updater가 감시하는 대상이 정확히
# `^signed-[0-9a-f]{40}$`(argocd.tf의 web.allow-tags)라서, candidate만 있고
# signed가 없으면 배포는 여전히 일어나지 않는다. 즉 "배포 가능한 이미지 수"는
# candidate가 아니라 signed 기준으로 세야 의미가 있다.
# -----------------------------------------------------------------------------
resource "null_resource" "verify_ecr_has_image" {
  triggers = {
    always_run = timestamp()
  }

  depends_on = [
    data.aws_ecr_repository.gochuchamchi,
    null_resource.sync_github_ci_variables,
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-ExecutionPolicy", "Bypass", "-Command"]
    command     = <<-EOT
      if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Host "aws CLI가 없어 ECR 확인을 건너뜁니다."
        exit 0
      }

      $tags = aws ecr list-images --repository-name ${data.aws_ecr_repository.gochuchamchi.name} --region ${var.region} --profile ${var.aws_profile} --query "imageIds[].imageTag" --output json 2>$null
      if ($LASTEXITCODE -ne 0) {
        Write-Host "ECR 조회에 실패했습니다 — 이미지 확인을 건너뜁니다."
        exit 0
      }

      $signed = @($tags | ConvertFrom-Json | Where-Object { $_ -match '^signed-[0-9a-f]{40}$' })

      if ($signed.Count -gt 0) {
        Write-Host "ECR에 배포 가능한 서명 이미지 $($signed.Count)개가 있습니다."
        exit 0
      }

      Write-Host ""
      Write-Host "=============================================================="
      Write-Host " 경고 — ECR에 배포 가능한(signed-) 이미지가 없습니다."
      Write-Host ""
      Write-Host " 이대로 두면 앱이 배포되지 않아 사이트가 503을 반환합니다."
      Write-Host " (최초 구축이거나, 이미지를 수동 삭제했거나, lifecycle 정책으로"
      Write-Host "  만료된 경우에 나타납니다. destroy로 지워지는 문제는 2026-08-06에"
      Write-Host "  ../persistent 로 state를 분리해 해결했습니다.)"
      Write-Host ""
      Write-Host " 복구 — CI를 돌려 빌드/서명/push 하세요:"
      Write-Host "   gh workflow run 'Build and sign release image' --repo ${var.argocd_github_owner}/gochuchamchi-spring"
      Write-Host "   gh run watch --repo ${var.argocd_github_owner}/gochuchamchi-spring"
      Write-Host "=============================================================="
      Write-Host ""
    EOT
  }
}
