# =============================================================================
# daily-up.ps1 — 아침 기동: 2단 apply를 순서 실수 없이  (v8)
#
# 왜 스크립트인가 — enable_edge 2단 apply는 순서 규칙이 3개나 된다:
#   1. 1차 전에 어제의 TF_VAR_enable_edge=true가 세션에 남아 있으면 안 됨
#      (2026-08-08 아침, 잔류 변수로 1차가 data.aws_lb 조회 실패한 실증 있음)
#   2. 1차가 성공한 뒤에만 2차를 실행해야 함
#   3. 2차에는 반드시 true가 주입돼야 함 (빠지면 WAF 없는 반쪽 인프라가 조용히 섬)
# 사람이 매일 지키는 규칙은 언젠가 틀린다 — 스크립트에 박는다.
#
# v8에서 추가된 것 3가지:
#   [0.5] terraform init — 모듈 버전 핀(v8) 이후, 요구사항이 바뀐 날 init 없이
#         apply하면 "Module version requirements have changed"로 즉사한다.
#   [0.7] 코드 변경 게이트 — 마지막 성공한 up 이후 커밋/워킹트리가 바뀐 날만
#         plan 요약을 보여주고 승인 받는다. 안 바뀐 날은 무정차.
#   [3]   smoke-test — "Apply complete!"는 이 프로젝트에서 성공 기준이었던 적이
#         없다(장애 5건 전부 apply 성공 + 서비스 사망). HTTP까지 봐야 끝.
#
# 사용: go\scripts\daily-up.ps1   (어느 위치에서 실행해도 됨)
# =============================================================================

$ErrorActionPreference = "Stop"
$env:AWS_PROFILE = "workload-admin"

# 이 스크립트 기준으로 terraform 디렉토리 고정 (실행 위치 무관)
$tfDir = Join-Path $PSScriptRoot "..\terraform"
Set-Location $tfDir

Write-Host "`n══ [0/4] 세션 청소 — 잔류 enable_edge 제거 ══" -ForegroundColor Cyan
Remove-Item Env:\TF_VAR_enable_edge -ErrorAction SilentlyContinue

Write-Host "`n══ [0.5/4] init — 모듈/프로바이더 요구사항 동기화 ══" -ForegroundColor Cyan
# 주의(2026-08-12) — native 명령 파이프라인에 Select-Object -First 를 직접 붙이지 말 것.
# -First 가 개수를 채우는 순간 PowerShell이 상위 파이프라인을 끊어(StopUpstreamCommands)
# 아직 출력 중이던 terraform.exe를 강제 종료시키고 $LASTEXITCODE 가 -1 이 된다.
# → init 은 성공했는데 "init 실패"로 오판하고 exit 1. 매칭 줄이 5개 이상일 때만 터지므로
#   이미 init 된 디렉토리에서는 4줄이라 드러나지 않았다(최초 init 에서만 재현).
# 출력을 먼저 다 받고, 종료 코드를 즉시 캡처한 뒤에 필터링한다.
$initOut  = terraform init -input=false -no-color
$initCode = $LASTEXITCODE
$initOut | Select-String "Initializing|Downloading|has been successfully" |
    Select-Object -First 5 | ForEach-Object { Write-Host "   $($_.Line)" }
if ($initCode -ne 0) {
    Write-Host "✖ init 실패 — 버전 제약이나 backend 문제. apply로 진행하지 않습니다." -ForegroundColor Red
    $initOut | ForEach-Object { Write-Host "   $_" }
    exit 1
}

# ── [0.7/4] 코드 변경 게이트 ─────────────────────────────────────────────
# 마지막으로 성공한 up의 커밋과 비교. 다르거나 워킹트리가 더럽으면 plan 요약 + 승인.
$lastFile = Join-Path $PSScriptRoot ".last-up-commit"
$head  = git -C $tfDir rev-parse HEAD 2>$null
$dirty = git -C $tfDir status --porcelain 2>$null
$codeChanged = $false
if ($dirty) { $codeChanged = $true }
elseif ($head -and (Test-Path $lastFile) -and ($head -ne (Get-Content $lastFile -ErrorAction SilentlyContinue))) { $codeChanged = $true }

if ($codeChanged) {
    Write-Host "`n⚠️ 마지막 성공한 up 이후 코드 변경 감지 — plan 요약:" -ForegroundColor Yellow
    # [0.5]와 같은 이유로 파이프라인 직결 금지 — 여기는 종료 코드를 보지 않아서, plan 이
    # 중간에 끊겨도 잘린 요약을 그대로 보여주고 승인을 받는다(더 위험).
    # 2>&1 도 제거: PS 5.1 은 native 명령의 stderr 를 ErrorRecord 로 감싸는데 이 스크립트는
    # $ErrorActionPreference="Stop" 이라 plan 이 경고 한 줄만 뱉어도 통째로 죽을 수 있다.
    $planOut  = terraform plan -no-color
    $planCode = $LASTEXITCODE
    $planOut | Select-String "Plan:|will be created|will be destroyed|must be replaced" |
        Select-Object -First 15 | ForEach-Object { Write-Host "   $($_.Line)" }
    if ($planCode -ne 0) {
        Write-Host "✖ plan 실패 — 승인 단계로 진행하지 않습니다." -ForegroundColor Red
        $planOut | Select-Object -Last 20 | ForEach-Object { Write-Host "   $_" }
        exit 1
    }
    $ok = Read-Host "이 변경 포함해서 apply할까요? (y/N)"
    if ($ok -ne "y") { Write-Host "취소됨"; exit 0 }
}

Write-Host "`n══ [1/4] 1차 apply — EKS·ALB까지 (enable_edge=false) ══" -ForegroundColor Cyan
terraform apply -auto-approve
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n✖ 1차 apply 실패 — 2차로 진행하지 않습니다. 에러를 확인하세요." -ForegroundColor Red
    exit 1
}

Write-Host "`n══ [2/4] 2차 apply — CloudFront 전환 (enable_edge=true) ══" -ForegroundColor Cyan
$env:TF_VAR_enable_edge = "true"
terraform apply -auto-approve
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n✖ 2차 apply 실패 — ALB가 아직 안 떴을 수 있습니다. 2~3분 뒤 이 스크립트를 다시 실행하면 1차는 No changes로 지나가고 2차만 재시도됩니다." -ForegroundColor Red
    exit 1
}

Write-Host "`n══ [3/4] 스모크 테스트 — apply 성공 ≠ 서비스 정상 ══" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot "smoke-test.ps1")
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n⚠️ 스모크 테스트 실패 항목 있음 — 위 안내대로 조치 후 재실행하세요." -ForegroundColor Yellow
    Write-Host "   (재구축 직후 PAT 미주입 등 정상 범위의 실패인지 항목별로 확인)"
    exit 1
}

# 성공 기록 — 다음 실행의 [0.7] 게이트 기준점
if ($head) { $head | Set-Content $lastFile }

Write-Host "`n══ [4/4] 완료 — HTTP까지 확인됨 ══" -ForegroundColor Green
Write-Host "https://kycj.click 확인. 저녁 종료는 daily-down.ps1"
