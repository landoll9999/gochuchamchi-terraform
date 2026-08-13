# =============================================================================
# verify-all.ps1 — 검증 스크립트를 한 번에 돌리고 요약한다
#
#   아침 daily-up 이후 "무엇이 확인됐고 무엇이 안 됐는가"를 한 화면에 만든다.
#   개별 스크립트를 따로 돌려도 되지만, 따로 돌리면 어느 걸 안 돌렸는지
#   기억에 의존하게 된다 — 검증에서 가장 흔한 실패는 틀린 결과가 아니라
#   빠뜨린 항목이다.
#
#   ── 판정을 3단계로 두는 이유 ─────────────────────────────────────────────
#   실패(1)와 미결(2)을 섞으면 아침마다 헛경보가 난다. 토큰 재발급처럼
#   시간이 지나야 관찰되는 항목은 "아직 모른다"가 정확한 답이고, 그건
#   고칠 것이 있다는 뜻이 아니다. 러너는 이 구분을 그대로 보존한다.
#
#   ── 순서 ──────────────────────────────────────────────────────────────────
#   빠르고 광범위한 것(smoke-test)을 먼저 돌려서 크게 망가진 날 일찍 멈춘다.
#   -ContinueOnFail 을 주면 끝까지 다 돌린다.
#
# 사용:
#   go\scripts\verify-all.ps1
#   go\scripts\verify-all.ps1 -ContinueOnFail      # 실패해도 전부 실행
#   go\scripts\verify-all.ps1 -Only db,waf         # 일부만
#   go\scripts\verify-all.ps1 -Skip schema         # 느린 것 제외
#
# 종료 코드: 0 전부 통과 / 1 실패 있음 / 2 실패는 없고 미결만 있음
# =============================================================================

param(
    [switch]$ContinueOnFail,
    [string[]]$Only = @(),
    [string[]]$Skip = @()
)

$ErrorActionPreference = "Continue"
$env:AWS_PROFILE = "workload-admin"
# 개별 스크립트도 각자 걸지만, 여기서도 걸어 둔다 — 이 값이 빠지면 AWS CLI 가
# 한글·em-dash 를 cp949 로 인코딩하려다 죽고, 그 실패가 "리소스 0개"로 보인다.
$env:PYTHONIOENCODING = "utf-8"

$scriptDir = $PSScriptRoot

# key      : -Only / -Skip 에서 쓰는 짧은 이름
# name     : 화면에 찍을 이름
# file     : 스크립트 파일
# args     : 인자
# slow     : 오래 걸리는 것(사용자에게 미리 알린다)
$suite = @(
    @{ key = "smoke";   name = "스모크 테스트 (전반)";        file = "smoke-test.ps1";           args = @(); slow = $false },
    @{ key = "contract";name = "배포 계약 (Secret/ConfigMap)"; file = "verify-contract.ps1";      args = @(); slow = $false },
    @{ key = "db";      name = "DB IAM 전용";                  file = "verify-db-iam-only.ps1";   args = @(); slow = $false },
    @{ key = "notify";  name = "알림 경로";                    file = "verify-notifications.ps1"; args = @(); slow = $false },
    @{ key = "logs";    name = "로그 파이프라인";              file = "verify-log-pipeline.ps1";  args = @(); slow = $false },
    @{ key = "waf";     name = "WAF (우회·SQLi·로그·알람)";    file = "verify-waf.ps1";           args = @(); slow = $true  },
    @{ key = "schema";  name = "schema.sql 동기화";            file = "verify-schema-sync.ps1";   args = @(); slow = $true  }
)

if ($Only.Count -gt 0) { $suite = $suite | Where-Object { $Only -contains $_.key } }
if ($Skip.Count -gt 0) { $suite = $suite | Where-Object { $Skip -notcontains $_.key } }

if ($suite.Count -eq 0) {
    Write-Host "실행할 항목이 없습니다. -Only / -Skip 값을 확인하세요." -ForegroundColor Red
    Write-Host "사용 가능한 키: smoke, contract, db, notify, logs, waf, schema"
    exit 1
}

Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " 전체 검증 — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host " 대상 $($suite.Count)개: $(($suite | ForEach-Object { $_.key }) -join ', ')" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$results = @()
$startAll = Get-Date

foreach ($item in $suite) {
    $path = Join-Path $scriptDir $item.file
    Write-Host ""
    Write-Host "────────────────────────────────────────────────────────────────"
    Write-Host " ▶ $($item.name)" -ForegroundColor White
    if ($item.slow) { Write-Host "   (오래 걸립니다)" -ForegroundColor DarkGray }
    Write-Host "────────────────────────────────────────────────────────────────"

    if (-not (Test-Path $path)) {
        Write-Host "   스크립트를 찾을 수 없음: $path" -ForegroundColor Red
        $results += [pscustomobject]@{ Key = $item.key; Name = $item.name; Code = -1; Sec = 0 }
        continue
    }

    $t0 = Get-Date
    if ($item.args -and $item.args.Count -gt 0) {
        & $path @($item.args)
    } else {
        & $path
    }
    $code = $LASTEXITCODE
    $sec  = [math]::Round(((Get-Date) - $t0).TotalSeconds)

    $results += [pscustomobject]@{ Key = $item.key; Name = $item.name; Code = $code; Sec = $sec }

    if ($code -eq 1 -and -not $ContinueOnFail) {
        Write-Host ""
        Write-Host "실패가 나와 여기서 멈춥니다. 끝까지 돌리려면 -ContinueOnFail" -ForegroundColor Red
        break
    }
}

# --- 요약 --------------------------------------------------------------------
Write-Host ""
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " 요약 (총 $([math]::Round(((Get-Date) - $startAll).TotalMinutes, 1))분)" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════" -ForegroundColor Cyan

foreach ($r in $results) {
    $label = "?"
    $color = "Gray"
    if ($r.Code -eq 0)      { $label = "통과"; $color = "Green" }
    elseif ($r.Code -eq 2)  { $label = "미결"; $color = "Yellow" }
    elseif ($r.Code -eq 1)  { $label = "실패"; $color = "Red" }
    elseif ($r.Code -eq -1) { $label = "없음"; $color = "Red" }
    else                    { $label = "코드 $($r.Code)"; $color = "Red" }
    Write-Host ("  {0,-6} {1,-34} {2,4}초" -f $label, $r.Name, $r.Sec) -ForegroundColor $color
}

$notRun = $suite | Where-Object { $k = $_.key; -not ($results | Where-Object { $_.Key -eq $k }) }
if ($notRun) {
    Write-Host ""
    Write-Host "  실행되지 않음: $(($notRun | ForEach-Object { $_.key }) -join ', ')" -ForegroundColor DarkGray
}

$failed  = @($results | Where-Object { $_.Code -ne 0 -and $_.Code -ne 2 })
$pending = @($results | Where-Object { $_.Code -eq 2 })

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "판정: 실패 $($failed.Count)건 — 위 스크립트의 출력에서 원인을 볼 것" -ForegroundColor Red
    exit 1
}
if ($pending.Count -gt 0) {
    Write-Host "판정: 미결 $($pending.Count)건 — 실패는 없다. 시간이 지나야 관찰되는 항목이다" -ForegroundColor Yellow
    Write-Host "      (토큰 재발급은 파드 기동 후 약 35분, WAF 로그는 몇 분 지연)"
    exit 2
}
Write-Host "판정: 전부 통과" -ForegroundColor Green
exit 0
