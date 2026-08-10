<#
=============================================================================
 account-baseline 이관용 import 블록 생성기 — 2026-08-07

 메인 state(../terraform)에서 account-baseline으로 옮길 리소스들의 실제 ID를
 뽑아 import 블록으로 만든다.

 ⚠️ 반드시 ../terraform 에 `removed` 블록을 apply하기 "전에" 돌릴 것.
    apply한 뒤에는 state에 리소스가 없어서 ID를 못 뽑는다.

 사용:
   $env:AWS_PROFILE = "admin"
   cd C:\terraform\go\scripts
   .\generate-baseline-imports.ps1
   -> ..\account-baseline\imports.tf 생성

 그 다음:
   cd ..\account-baseline
   terraform init
   terraform plan      # "N to import", create 0건이어야 정상
=============================================================================
#>

$ErrorActionPreference = "Stop"

$mainDir     = Join-Path $PSScriptRoot "..\terraform"
$baselineDir = Join-Path $PSScriptRoot "..\account-baseline"
$outFile     = Join-Path $baselineDir "imports.tf"

# --- 옮길 대상. removed 블록과 같은 목록이어야 한다 -------------------------
$targets = @(
  "aws_s3_bucket.athena_results", "aws_s3_bucket_ownership_controls.athena_results",
  "aws_s3_bucket_public_access_block.athena_results",
  "aws_s3_bucket_server_side_encryption_configuration.athena_results",
  "aws_s3_bucket_lifecycle_configuration.athena_results", "aws_s3_bucket_policy.athena_results",
  "aws_glue_catalog_database.security_logs", "aws_glue_catalog_table.cloudtrail",
  "aws_athena_workgroup.security_logs", "aws_athena_named_query.recent_management_events",
  "aws_athena_named_query.failed_api_calls", "aws_athena_named_query.write_events",
  "aws_s3_bucket.aws_config", "aws_s3_bucket_public_access_block.aws_config",
  "aws_s3_bucket_server_side_encryption_configuration.aws_config",
  "aws_s3_bucket_lifecycle_configuration.aws_config", "aws_s3_bucket_policy.aws_config",
  "module.aws_config",
  "aws_cloudtrail.central",
  "aws_budgets_budget.monthly", "aws_ce_anomaly_monitor.services", "aws_ce_anomaly_subscription.email",
  "aws_inspector2_enabler.this", "aws_ecr_registry_scanning_configuration.this",
  "aws_glue_catalog_table.vpc_flow_logs", "aws_athena_named_query.flowlogs",
  "aws_guardduty_detector.this", "aws_guardduty_detector_feature.eks_audit_logs",
  "aws_guardduty_detector_feature.s3_data_events", "aws_guardduty_detector_feature.ebs_malware",
  "aws_guardduty_detector_feature.runtime_monitoring",
  "aws_accessanalyzer_analyzer.account", "aws_iam_group.console_admins",
  "aws_iam_group_policy.force_mfa", "aws_iam_group_policy_attachment.console_admins_admin",
  "aws_iam_group_membership.console_admins", "aws_iam_policy.region_guard",
  "aws_iam_group_policy_attachment.console_admins_region_guard",
  "aws_kms_key.logs", "aws_kms_alias.logs",
  "aws_s3_bucket.cloudwatch_log_archive", "aws_s3_bucket_ownership_controls.cloudwatch_log_archive",
  "aws_s3_bucket_public_access_block.cloudwatch_log_archive",
  "aws_s3_bucket_versioning.cloudwatch_log_archive",
  "aws_s3_bucket_server_side_encryption_configuration.cloudwatch_log_archive",
  "aws_s3_bucket_lifecycle_configuration.cloudwatch_log_archive",
  "aws_s3_bucket_policy.cloudwatch_log_archive",
  "aws_cloudwatch_log_group.cloudwatch_log_archive_firehose",
  "aws_cloudwatch_log_stream.cloudwatch_log_archive_firehose",
  "aws_iam_role.cloudwatch_log_archive_firehose", "aws_iam_role_policy.cloudwatch_log_archive_firehose",
  "aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive",
  "aws_iam_role.cloudwatch_logs_to_firehose", "aws_iam_role_policy.cloudwatch_logs_to_firehose",
  "module.security_hub"
)

Write-Host "메인 state 읽는 중..." -ForegroundColor Cyan
Push-Location $mainDir
try   { $json = terraform show -json | ConvertFrom-Json }
finally { Pop-Location }

# --- state 전체를 (address -> values) 로 펼친다 -----------------------------
$flat = @{}
function Walk($mod) {
  foreach ($r in $mod.resources) { if ($r.mode -eq "managed") { $flat[$r.address] = $r } }
  foreach ($c in $mod.child_modules) { Walk $c }
}
Walk $json.values.root_module

# --- import ID가 state의 id와 다른 예외들 ----------------------------------
#     대부분의 AWS 리소스는 import ID = state의 id 이지만, 몇 개는 복합 키다.
function Get-ImportId($r) {
  $v = $r.values
  switch ($r.type) {
    # 스트림은 id가 이름뿐이라 로그 그룹을 앞에 붙여야 한다
    "aws_cloudwatch_log_stream" { return "$($v.log_group_name):$($v.name)" }
    # 구독은 ARN으로 import한다
    "aws_ce_anomaly_subscription" { return $v.arn }
    "aws_ce_anomaly_monitor"      { return $v.arn }
    default { return $v.id }
  }
}

$lines = @()
$lines += "# ============================================================================="
$lines += "# state 이관용 임시 파일 — 2026-08-07 (generate-baseline-imports.ps1 자동 생성)"
$lines += "#"
$lines += "# ../terraform 에서 옮겨오는 리소스들. 실물은 이미 AWS에 있고, 이 계층의"
$lines += "# state가 그것을 흡수하기만 한다."
$lines += "#"
$lines += "#   terraform plan   -> `"N to import`", create/destroy 0건이어야 정상"
$lines += "#   terraform apply"
$lines += "#   확인 후 이 파일과 ../terraform/migration-2026-08-07-removed.tf 삭제"
$lines += "# ============================================================================="
$lines += ""

$missing = @()
$count = 0
foreach ($t in ($targets | Sort-Object)) {
  $matched = $flat.Keys | Where-Object { $_ -eq $t -or $_ -like "$t[[]*" -or $_ -like "$t.*" }
  if (-not $matched) { $missing += $t; continue }
  foreach ($addr in ($matched | Sort-Object)) {
    $id = Get-ImportId $flat[$addr]
    if ([string]::IsNullOrEmpty($id)) { $missing += "$addr (id 비어 있음)"; continue }
    $lines += "import {"
    $lines += "  to = $addr"
    $lines += "  id = `"$id`""
    $lines += "}"
    $lines += ""
    $count++
  }
}

$lines | Set-Content -Path $outFile -Encoding UTF8

Write-Host "생성 완료: $outFile ($count 개)" -ForegroundColor Green
if ($missing.Count -gt 0) {
  Write-Host ""
  Write-Host "!! state에서 못 찾은 대상 $($missing.Count)개 — 수동 확인 필요:" -ForegroundColor Yellow
  $missing | ForEach-Object { Write-Host "   $_" -ForegroundColor Yellow }
  Write-Host "   (이미 옮겼거나, 애초에 apply된 적 없는 리소스일 수 있음)" -ForegroundColor Yellow
}
