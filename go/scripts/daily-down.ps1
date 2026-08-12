# =============================================================================
# daily-down.ps1 — 저녁 종료: 확인 절차를 건너뛸 수 없게
#
#   1. 검역 SG 잔여 확인 — 격리가 발동된 날은 destroy 전 정리 필요 (VPC 삭제를 막음)
#   2. plan -destroy 요약을 먼저 보여주고 사람이 y로 승인
#   3. destroy 실행 (enable_edge 변수 유무는 destroy에 영향 없음)
#
# 사용: go\scripts\daily-down.ps1
# =============================================================================

$ErrorActionPreference = "Stop"
$env:AWS_PROFILE = "workload-admin"

$tfDir = Join-Path $PSScriptRoot "..\terraform"
Set-Location $tfDir

Write-Host "`n══ [1/3] 검역 SG 확인 — 오늘 자동 격리가 발동됐다면 여기 잡힘 ══" -ForegroundColor Cyan
$sg = aws ec2 describe-security-groups `
    --filters "Name=group-name,Values=gochuchamchi-quarantine" `
    --query "SecurityGroups[0].GroupId" --output text 2>$null
if ($sg -and $sg -ne "None") {
    Write-Host "⚠️ 검역 SG($sg)가 존재합니다 — 오늘 격리 이벤트가 있었다는 뜻." -ForegroundColor Yellow
    Write-Host "   Discord 격리 알림을 먼저 확인하세요. 조사할 게 없다면 아래로 정리 후 재실행:"
    Write-Host "   aws ec2 delete-security-group --group-id $sg"
    exit 1
}
Write-Host "검역 SG 없음 — 정상"

Write-Host "`n══ [2/3] destroy 계획 요약 ══" -ForegroundColor Cyan
# 2>&1로 네이티브 stderr를 파이프에 섞으면 PS 5.1이 각 줄을 NativeCommandError로
# 감싸고, 위의 $ErrorActionPreference="Stop" 때문에 plan이 성공해도 스크립트가 죽는다.
# stdout만 변수로 받고 성패는 $LASTEXITCODE로 판정한다 (stderr는 콘솔로 그냥 흐름).
$planOut = terraform plan -destroy -no-color
if ($LASTEXITCODE -ne 0) {
    Write-Host "✖ plan -destroy 실패 — destroy로 진행하지 않습니다. 위 에러를 확인하세요." -ForegroundColor Red
    exit 1
}
$planOut | Select-String "Plan:" | ForEach-Object { $_.Line }

# 상시 계층 리소스가 섞였는지 키워드 검사 (섞였다면 역참조/state 오염 신호)
# log.archive는 패턴에서 뺀다 — aws_cloudwatch_log_subscription_filter.cloudwatch_log_archive[*]
# 는 이 스택의 정상 구성원이라 매일 밤 같이 지워지는 게 맞는데, 그걸 유출로 오탐해
# destroy를 막아 버린다.
$leak = $planOut | Select-String `
    -Pattern "guardduty|cloudtrail|aws_config|security.?hub|sns_topic" `
    -CaseSensitive:$false
if ($leak) {
    Write-Host "✖ destroy 계획에 상시 계층 키워드가 보입니다 — 중단. 아래 항목 확인:" -ForegroundColor Red
    $leak | Select-Object -First 5 | ForEach-Object { Write-Host "   $($_.Line)" }
    exit 1
}

$answer = Read-Host "`n위 계획대로 destroy할까요? (y/N)"
if ($answer -ne "y") { Write-Host "취소됨"; exit 0 }

Write-Host "`n══ [3/3] destroy 실행 ══" -ForegroundColor Cyan
terraform destroy -auto-approve
if ($LASTEXITCODE -ne 0) {
    Write-Host "`n✖ destroy 실패 — 무지성 재시도 금지. 에러 메시지를 먼저 읽으세요." -ForegroundColor Red
    exit 1
}
Write-Host "`n완료 — 시간당 과금 리소스 전멸. 내일 아침은 daily-up.ps1" -ForegroundColor Green
