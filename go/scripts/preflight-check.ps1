<#
.SYNOPSIS
  apply 전 이름 충돌 사전 점검  (2026-08-05 자동화 4/4)

.DESCRIPTION
  "state에는 없는데 AWS에는 살아있는" 리소스를 apply 전에 찾아낸다.

  왜 필요한가 — 2026-08-05 재구축에서 apply가 20분을 태운 뒤 이 에러로 죽었다:
    · BucketAlreadyOwnedByYou  (gochuchamchi-cloudwatch-log-archive-...)
    · AlreadyExistsException   (alias/gochuchamchi-logs)
  destroy 교착을 풀면서 `state rm`으로 빼낸 리소스가 실물로 남아 있었고,
  다음 apply가 같은 이름으로 다시 만들려다 충돌한 것이다. 이 함정은 이미
  pitfalls-checklist.md 79·80번에 적혀 있었지만 "사람이 매번 기억해야 하는
  절차"였기 때문에 재구축 압박 상황에서 그대로 생략됐다. 그래서 점검을
  스크립트로 옮긴다.

  어떻게 — plan이 "만들겠다"고 한 것(actions=["create"])만 본다. 리소스 목록을
  손으로 관리하지 않으므로 코드가 늘어도 자동으로 따라온다. 그중 이름이 전역
  고정된 타입(아래 $Checkers)만 골라 AWS에 이미 있는지 조회하고, 있으면
  그대로 붙여넣을 수 있는 `terraform import` 명령을 출력한다.

  검사 대상이 아닌 것 — 이름이 AWS 생성값인 리소스(VPC, EC2, 보안그룹 등)는
  애초에 이름 충돌이 나지 않으므로 조용히 건너뛴다. 교체(replace)도 제외한다.
  이미 state에 있어서 terraform이 삭제 후 생성하기 때문이다.

.EXAMPLE
  .\preflight-check.ps1
      plan을 새로 뜬 뒤 점검 (임시 plan은 검사 후 삭제)

.EXAMPLE
  .\preflight-check.ps1 -PlanFile ..\terraform\tfplan
      이미 떠 둔 plan 파일로 점검 (TF_VAR 시크릿을 다시 넣을 필요 없음)

.EXAMPLE
  .\preflight-check.ps1 -Fix
      충돌을 찾으면 terraform import까지 자동 실행

.NOTES
  이 파일은 반드시 UTF-8 **BOM 포함**으로 저장할 것. PowerShell 5.1은 BOM이
  없으면 CP949로 읽어 한글이 깨지고, 깨진 바이트가 따옴표/괄호를 망가뜨려
  스크립트 전체가 파싱 실패한다 (2026-08-05에 smoke-test.ps1이 실제로 이랬음).
#>
[CmdletBinding()]
param(
  [string] $PlanFile,
  [string] $TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
  [string] $Region = 'ap-northeast-2',
  [string] $AwsProfile = 'admin',
  [switch] $Fix,
  [switch] $KeepPlan
)

$ErrorActionPreference = 'Continue'
$started = Get-Date

function Invoke-Aws {
  param([string[]]$CliArgs)
  $out = (& aws @CliArgs --region $Region --profile $AwsProfile 2>&1) -join "`n"
  return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out }
}

$script:AccountId = $null
function Get-AccountId {
  if (-not $script:AccountId) {
    $r = Invoke-Aws @('sts', 'get-caller-identity', '--query', 'Account', '--output', 'text')
    if (-not $r.Ok) { throw "AWS 자격증명 확인 실패 (--profile $AwsProfile): $($r.Out)" }
    $script:AccountId = $r.Out.Trim()
  }
  return $script:AccountId
}

# 조회 결과가 "비어 있지 않은 텍스트"인지. --query가 빈 배열을 주면 aws는
# 종료코드 0에 빈 문자열(또는 None)을 주므로 종료코드만으로는 판별이 안 된다.
function Test-AwsText {
  param($Result)
  if (-not $Result.Ok) { return $false }
  $t = $Result.Out.Trim()
  return ($t -ne '' -and $t -ne 'None')
}

# ---------------------------------------------------------------------------
# 타입별 검사기
#   Field : plan JSON의 change.after에서 "이름"에 해당하는 필드
#   Test  : AWS에 이미 있으면 $true            (인자: 이름, after 객체)
#   Id    : terraform import에 넘길 ID         (인자: 이름, after 객체)
#
# 새 타입을 추가하려면 여기에 한 줄 넣으면 된다. 이름이 plan 시점에 확정되지
# 않는(known after apply) 리소스는 자동으로 건너뛰므로 신경 쓸 필요 없다.
# ---------------------------------------------------------------------------
$script:Checkers = @{
  'aws_s3_bucket'                    = @{
    Field = 'bucket'
    # 남의 계정 버킷이면 403이 오는데 그래도 이름은 이미 점유된 상태다.
    Test  = { param($n, $a) $r = Invoke-Aws @('s3api', 'head-bucket', '--bucket', $n); return ($r.Ok -or $r.Out -match '403|Forbidden') }
    Id    = { param($n, $a) $n }
  }
  'aws_kms_alias'                    = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('kms', 'describe-key', '--key-id', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_iam_role'                     = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('iam', 'get-role', '--role-name', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_iam_policy'                   = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('iam', 'get-policy', '--policy-arn', "arn:aws:iam::$(Get-AccountId):policy/$n")).Ok }
    Id    = { param($n, $a) "arn:aws:iam::$(Get-AccountId):policy/$n" }
  }
  'aws_iam_instance_profile'         = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('iam', 'get-instance-profile', '--instance-profile-name', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_ecr_repository'               = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('ecr', 'describe-repositories', '--repository-names', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_cloudwatch_log_group'         = @{
    Field = 'name'
    Test  = { param($n, $a) Test-AwsText (Invoke-Aws @('logs', 'describe-log-groups', '--log-group-name-prefix', $n, '--query', "logGroups[?logGroupName=='$n'].logGroupName", '--output', 'text')) }
    Id    = { param($n, $a) $n }
  }
  'aws_cloudtrail'                   = @{
    Field = 'name'
    Test  = { param($n, $a) Test-AwsText (Invoke-Aws @('cloudtrail', 'describe-trails', '--trail-name-list', $n, '--query', "trailList[?Name=='$n'].Name", '--output', 'text')) }
    Id    = { param($n, $a) $n }
  }
  'aws_glue_catalog_database'        = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('glue', 'get-database', '--name', $n)).Ok }
    Id    = { param($n, $a) "$(Get-AccountId):$n" }
  }
  'aws_glue_catalog_table'           = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('glue', 'get-table', '--database-name', $a.database_name, '--name', $n)).Ok }
    Id    = { param($n, $a) "$(Get-AccountId):$($a.database_name):$n" }
  }
  'aws_athena_workgroup'             = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('athena', 'get-work-group', '--work-group', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_sns_topic'                    = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('sns', 'get-topic-attributes', '--topic-arn', "arn:aws:sns:${Region}:$(Get-AccountId):$n")).Ok }
    Id    = { param($n, $a) "arn:aws:sns:${Region}:$(Get-AccountId):$n" }
  }
  'aws_sqs_queue'                    = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('sqs', 'get-queue-url', '--queue-name', $n)).Ok }
    Id    = { param($n, $a) (Invoke-Aws @('sqs', 'get-queue-url', '--queue-name', $n, '--query', 'QueueUrl', '--output', 'text')).Out.Trim() }
  }
  'aws_secretsmanager_secret'        = @{
    Field = 'name'
    # 삭제 예약(PendingDeletion) 상태도 이름을 계속 점유하므로 충돌로 잡아야 한다.
    Test  = { param($n, $a) (Invoke-Aws @('secretsmanager', 'describe-secret', '--secret-id', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_dynamodb_table'               = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('dynamodb', 'describe-table', '--table-name', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_lambda_function'              = @{
    Field = 'function_name'
    Test  = { param($n, $a) (Invoke-Aws @('lambda', 'get-function', '--function-name', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_db_instance'                  = @{
    Field = 'identifier'
    Test  = { param($n, $a) (Invoke-Aws @('rds', 'describe-db-instances', '--db-instance-identifier', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_elasticache_replication_group' = @{
    Field = 'replication_group_id'
    Test  = { param($n, $a) (Invoke-Aws @('elasticache', 'describe-replication-groups', '--replication-group-id', $n)).Ok }
    Id    = { param($n, $a) $n }
  }
  'aws_kinesis_firehose_delivery_stream' = @{
    Field = 'name'
    Test  = { param($n, $a) (Invoke-Aws @('firehose', 'describe-delivery-stream', '--delivery-stream-name', $n)).Ok }
    Id    = { param($n, $a) (Invoke-Aws @('firehose', 'describe-delivery-stream', '--delivery-stream-name', $n, '--query', 'DeliveryStreamDescription.DeliveryStreamARN', '--output', 'text')).Out.Trim() }
  }
  'aws_efs_file_system'              = @{
    Field = 'creation_token'
    Test  = { param($n, $a) Test-AwsText (Invoke-Aws @('efs', 'describe-file-systems', '--creation-token', $n, '--query', 'FileSystems[0].FileSystemId', '--output', 'text')) }
    Id    = { param($n, $a) (Invoke-Aws @('efs', 'describe-file-systems', '--creation-token', $n, '--query', 'FileSystems[0].FileSystemId', '--output', 'text')).Out.Trim() }
  }
}

Write-Host ''
Write-Host '=== apply 사전 점검 (이름 충돌) ===' -ForegroundColor Cyan

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) { Write-Error 'terraform을 찾을 수 없습니다.'; exit 2 }
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) { Write-Error 'aws CLI를 찾을 수 없습니다.'; exit 2 }

$TerraformDir = (Resolve-Path $TerraformDir).Path
Push-Location $TerraformDir
try {
  # -------------------------------------------------------------------------
  # 1. plan 확보
  # -------------------------------------------------------------------------
  $tempPlan = $null
  if ($PlanFile) {
    if (-not (Test-Path $PlanFile)) { Write-Error "plan 파일을 찾을 수 없습니다: $PlanFile"; exit 2 }
    $PlanFile = (Resolve-Path $PlanFile).Path
    Write-Host "  plan 파일 사용: $PlanFile" -ForegroundColor DarkGray
  }
  else {
    # 저장소 밖(TEMP)에 만든다 — plan 파일에는 변수 값이 들어있어서 커밋 사고가 난다
    $tempPlan = Join-Path $env:TEMP ("preflight-{0}.tfplan" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $PlanFile = $tempPlan
    Write-Host '  plan 생성 중... (시크릿 TF_VAR가 필요하면 -PlanFile로 기존 plan을 넘기세요)' -ForegroundColor DarkGray
    # "-out=$PlanFile"을 반드시 큰따옴표로 감쌀 것 — 따옴표가 없으면 PowerShell이
    # 변수를 확장하지 않고 리터럴 `$PlanFile`을 그대로 terraform에 넘긴다. 그러면
    # 현재 디렉토리에 `$PlanFile`이라는 이름의 파일이 생기고(저장소 오염),
    # 정작 의도한 경로에는 아무것도 없어서 다음 단계가 엉뚱한 에러로 죽는다.
    # pitfalls-checklist.md 62번(따옴표 없는 `-target=a.b`가 잘리는 문제)과 같은 뿌리.
    $planOut = (& terraform plan "-out=$PlanFile" -input=false 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) { Write-Error "terraform plan 실패:`n$planOut"; exit 2 }
    # 종료코드가 0이어도 파일이 없으면 인자가 잘못 전달된 것이다 — 조용히 넘어가면
    # 다음 단계에서 원인을 알 수 없는 에러가 난다.
    if (-not (Test-Path $PlanFile)) {
      Write-Error "plan은 성공했는데 파일이 없습니다: $PlanFile`n인자 전달이 깨졌을 가능성이 큽니다(따옴표 확인)."
      exit 2
    }
  }

  $showJson = (& terraform show -json $PlanFile) -join "`n"
  if ($LASTEXITCODE -ne 0) { Write-Error 'terraform show -json 실패'; exit 2 }
  try { $plan = $showJson | ConvertFrom-Json } catch { Write-Error "plan JSON 파싱 실패: $_"; exit 2 }

  # -------------------------------------------------------------------------
  # 2. 순수 생성(create) 대상만 추린다
  # -------------------------------------------------------------------------
  $creates = @()
  foreach ($rc in $plan.resource_changes) {
    if (-not $rc.change) { continue }
    $actions = @($rc.change.actions)
    if ($actions.Count -ne 1 -or $actions[0] -ne 'create') { continue }
    $creates += $rc
  }

  # 현재 state 주소 목록 — 오래된 plan 파일로 돌렸을 때의 오탐을 거른다.
  # 신선한 plan이면 create = state에 없다는 뜻이라 이 대조는 항상 통과하지만,
  # 이미 apply한 plan을 재사용하면 "AWS에 있음 + state에도 있음"이 되어
  # 충돌이 아니라 "plan이 낡음"으로 판정해야 한다.
  $stateAddrs = New-Object 'System.Collections.Generic.HashSet[string]'
  $stateOut = (& terraform state list 2>&1)
  if ($LASTEXITCODE -eq 0) {
    foreach ($line in $stateOut) { [void]$stateAddrs.Add($line.Trim()) }
  }

  $checked = 0
  $skipped = 0
  $stale = 0
  $conflicts = New-Object System.Collections.ArrayList

  Write-Host ("  생성 예정 {0}건 — 이름이 고정된 타입만 검사합니다" -f $creates.Count) -ForegroundColor DarkGray
  Write-Host ''

  foreach ($rc in $creates) {
    $checker = $script:Checkers[$rc.type]
    if (-not $checker) { continue }

    $after = $rc.change.after
    $field = $checker.Field
    $name = $null
    if ($after -and $after.PSObject.Properties[$field]) { $name = $after.$field }

    # known after apply — 이름이 아직 정해지지 않았으면 충돌 판정이 불가능하다
    if (-not $name) {
      $skipped++
      Write-Host ("  [보류] {0}" -f $rc.address) -ForegroundColor DarkGray
      Write-Host ("         이름이 apply 시점에 정해짐 ({0}) — 검사 불가" -f $field) -ForegroundColor DarkGray
      continue
    }

    $checked++
    $exists = $false
    try { $exists = [bool](& $checker.Test $name $after) }
    catch {
      Write-Host ("  [오류] {0}  {1}" -f $rc.address, $name) -ForegroundColor Yellow
      Write-Host ("         조회 실패: {0}" -f $_.Exception.Message) -ForegroundColor DarkGray
      continue
    }

    if (-not $exists) {
      Write-Host ("  [정상] {0}  {1}" -f $rc.address, $name) -ForegroundColor Green
      continue
    }

    if ($stateAddrs.Contains($rc.address)) {
      $stale++
      Write-Host ("  [낡음] {0}  {1}" -f $rc.address, $name) -ForegroundColor Yellow
      Write-Host '         AWS에도 state에도 있습니다 — 이 plan은 이미 적용된 것입니다. plan을 다시 뜨세요.' -ForegroundColor DarkGray
      continue
    }

    $importId = $null
    try { $importId = & $checker.Id $name $after } catch { $importId = $name }

    [void]$conflicts.Add([pscustomobject]@{
        Address  = $rc.address
        Type     = $rc.type
        Name     = $name
        ImportId = $importId
      })

    Write-Host ("  [충돌] {0}  {1}" -f $rc.address, $name) -ForegroundColor Red
    Write-Host '         AWS에 이미 존재하는데 state에는 없습니다 — apply가 AlreadyExists로 실패합니다.' -ForegroundColor DarkGray
  }

  # -------------------------------------------------------------------------
  # 3. 결과
  # -------------------------------------------------------------------------
  $elapsed = [int]((Get-Date) - $started).TotalSeconds
  Write-Host ''
  Write-Host ("=== 사전 점검 결과: 충돌 {0} / 검사 {1} / 보류 {2} / 낡음 {3}  ({4}초) ===" -f $conflicts.Count, $checked, $skipped, $stale, $elapsed) -ForegroundColor Cyan

  if ($conflicts.Count -eq 0) {
    if ($stale -gt 0) {
      Write-Host '  이름 충돌은 없지만 이미 적용된 plan입니다 — 새로 뜬 plan으로 다시 점검하세요.' -ForegroundColor Yellow
      exit 0
    }
    Write-Host '  이름 충돌 없음 — apply를 진행해도 됩니다.' -ForegroundColor Green
    exit 0
  }

  Write-Host ''
  if ($Fix) {
    Write-Host '  -Fix 지정됨 — import를 실행합니다.' -ForegroundColor Yellow
    $failed = 0
    foreach ($c in $conflicts) {
      Write-Host ("  import {0} <- {1}" -f $c.Address, $c.ImportId) -ForegroundColor Yellow
      & terraform import $c.Address $c.ImportId | Out-Null
      if ($LASTEXITCODE -ne 0) { $failed++; Write-Host '         실패 — 수동으로 확인하세요.' -ForegroundColor Red }
    }
    Write-Host ''
    if ($failed -gt 0) { Write-Host ("  {0}건 import 실패. plan을 다시 떠서 확인하세요." -f $failed) -ForegroundColor Red; exit 1 }
    Write-Host '  import 완료 — plan을 다시 뜬 뒤 apply하세요 (기존 plan 파일은 무효입니다).' -ForegroundColor Green
    exit 0
  }

  Write-Host '  아래 명령으로 인수한 뒤 plan을 다시 뜨세요 (-Fix로 자동 실행 가능):' -ForegroundColor Yellow
  Write-Host ''
  foreach ($c in $conflicts) {
    # 인자를 작은따옴표로 감싸는 이유 — PowerShell 5.1은 따옴표 없는 `-target=a.b`
    # 같은 인자를 점에서 잘라먹는다. import 주소도 점을 포함하므로 동일하게 감싼다.
    Write-Host ("    terraform import '{0}' '{1}'" -f $c.Address, $c.ImportId)
  }
  Write-Host ''
  exit 1
}
finally {
  Pop-Location
  if ($tempPlan -and (Test-Path $tempPlan) -and -not $KeepPlan) {
    Remove-Item $tempPlan -Force -ErrorAction SilentlyContinue
  }
}
