#Requires -Version 5.1
<#
  verify-auto-response.ps1 — 신규 자동대응이 배포됐고 드라이런 스위치가 어떤
  상태인지 점검한다: WAF IP 차단 / 파드 K8s 격리 / SIEM 크로스계정 / Security Hub
  입력원 / GuardDuty features.

  이 검증은 "코드가 배포됐나 + 대응이 켜졌나"까지만 본다. 실제 대응 동작은 전부
  드라이런 기본이라 실행되지 않으며, 스위치를 켠 뒤의 동작은 Lambda 로그로 본다.

  종료 코드: 0=전부 확인 / 2=미결(대응 스위치 off 등 — 실패 아님) / 1=배포 누락

  PS 5.1 주의:
   - aws 출력은 --query 로 ASCII 필드만 뽑는다(비ASCII em-dash 가 섞이면 cp949
     인코딩 오류로 CLI 가 죽는다).
   - native 명령 stderr 를 리다이렉트하지 않는다($ErrorActionPreference=Stop 에서
     리다이렉트하면 ErrorRecord 로 감싸여 죽는다). 실패는 $LASTEXITCODE 로 본다.
   - 이 파일은 UTF-8 BOM 으로 저장한다(없으면 PS 5.1 이 한글을 cp949 로 읽어 깨짐).
#>
param(
  [string]$Profile = "workload-admin",
  [string]$Region = "ap-northeast-2"
)

$ErrorActionPreference = "Stop"
$results = New-Object System.Collections.ArrayList
$script:pending = $false
$script:failed = $false

function Add-Result([string]$Name, [string]$Status, [string]$Detail) {
  $null = $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
  if ($Status -eq "FAIL") { $script:failed = $true }
  if ($Status -eq "PENDING") { $script:pending = $true }
}

Write-Host "자동대응 배포·스위치 점검 (profile=$Profile)" -ForegroundColor Cyan

# 1. 격리 Lambda 드라이런 스위치 -------------------------------------------------
try {
  $envJson = aws lambda get-function-configuration --function-name gochuchamchi-guardduty-isolation `
    --region $Region --profile $Profile --query "Environment.Variables" --output json
  if ($LASTEXITCODE -ne 0) { throw "get-function-configuration 실패 (권한/미배포)" }
  $envVars = $envJson | ConvertFrom-Json
  foreach ($key in @("WAF_RESPONSE_ENABLED", "POD_RESPONSE_ENABLED", "WAF_BLOCKLIST_IP_SET_NAME",
      "IAM_SUBJECT_RESPONSE_ENABLED", "S3_RESPONSE_ENABLED", "SG_RESPONSE_ENABLED", "SNAPSHOT_ON_ISOLATE_ENABLED")) {
    if ($envVars.PSObject.Properties.Name -contains $key) {
      $val = [string]$envVars.$key
      if ($key -like "*_ENABLED" -and $val -ne "true") {
        Add-Result "격리 Lambda: $key" "PENDING" "$val (드라이런 — 관찰 후 켜기)"
      }
      else {
        Add-Result "격리 Lambda: $key" "PASS" "$val"
      }
    }
    else {
      Add-Result "격리 Lambda: $key" "FAIL" "환경변수 없음 — Lambda 코드 미배포"
    }
  }
}
catch {
  Add-Result "격리 Lambda 환경변수" "SKIP" $_.Exception.Message
}

# 2. WAF 차단 IP set (us-east-1 CLOUDFRONT) --------------------------------------
try {
  $ipsetName = aws wafv2 list-ip-sets --scope CLOUDFRONT --region us-east-1 --profile $Profile `
    --query "IPSets[?Name=='gochuchamchi-guardduty-blocklist'].Name | [0]" --output text
  if ($LASTEXITCODE -eq 0 -and $ipsetName -eq "gochuchamchi-guardduty-blocklist") {
    Add-Result "WAF 차단 IP set" "PASS" "존재 (us-east-1)"
  }
  else {
    Add-Result "WAF 차단 IP set" "FAIL" "없음 — persistent apply 필요"
  }
}
catch {
  Add-Result "WAF 차단 IP set" "SKIP" $_.Exception.Message
}

# 3. 입력원/크로스계정 EventBridge rule ------------------------------------------
$rules = @(
  @{ n = "gochuchamchi-siem-response"; label = "SIEM 크로스계정 대응" },
  @{ n = "gochuchamchi-securityhub-finding-critical"; label = "Security Hub 입력원" }
)
foreach ($rule in $rules) {
  try {
    $state = aws events describe-rule --name $rule.n --region $Region --profile $Profile `
      --query "State" --output text
    if ($LASTEXITCODE -eq 0 -and $state) {
      $st = if ($state -eq "ENABLED") { "PASS" } else { "PENDING" }
      Add-Result ("rule: " + $rule.label) $st "$state"
    }
    else {
      Add-Result ("rule: " + $rule.label) "FAIL" "rule 없음 — cloudwatch-notifications apply 필요"
    }
  }
  catch {
    Add-Result ("rule: " + $rule.label) "SKIP" $_.Exception.Message
  }
}

# 4. GuardDuty detector + features ----------------------------------------------
try {
  $detId = aws guardduty list-detectors --region $Region --profile $Profile `
    --query "DetectorIds | [0]" --output text
  if ($LASTEXITCODE -eq 0 -and $detId -and $detId -ne "None") {
    Add-Result "GuardDuty detector" "PASS" $detId
  }
  else {
    Add-Result "GuardDuty detector" "FAIL" "detector 없음"
  }
}
catch {
  Add-Result "GuardDuty detector" "SKIP" $_.Exception.Message
}

# 요약 --------------------------------------------------------------------------
Write-Host ""
Write-Host "결과 요약" -ForegroundColor Cyan
foreach ($r in $results) {
  $color = switch ($r.Status) {
    "PASS" { "Green" }
    "PENDING" { "Yellow" }
    "SKIP" { "DarkGray" }
    default { "Red" }
  }
  Write-Host ("  [{0}] {1} - {2}" -f $r.Status, $r.Name, $r.Detail) -ForegroundColor $color
}

Write-Host ""
if ($script:failed) {
  Write-Host "일부 항목이 배포되지 않았습니다 (FAIL). 해당 계층을 apply 하세요." -ForegroundColor Red
  exit 1
}
if ($script:pending) {
  Write-Host "배포는 됐고 대응 스위치가 아직 드라이런입니다 (PENDING = 정상). 관찰 후 켜세요." -ForegroundColor Yellow
  exit 2
}
Write-Host "자동대응 배포·활성 상태 전부 확인." -ForegroundColor Green
exit 0
