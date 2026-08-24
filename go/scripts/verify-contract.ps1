<#
.SYNOPSIS
  terraform <-> gochuchamchi-gitops 배포 계약 검증  (2026-08-04 자동화 1/3)

.DESCRIPTION
  2026-08-04 장애(“terraform은 Secret 이름을 바꿨는데 gitops는 옛 이름을 참조”)를
  기계가 잡도록 만든 스크립트. 두 방향으로 검사한다.

    [정적] gitops 저장소의 YAML이 참조하는 Secret/ConfigMap 이름이
           terraform의 계약(contract.tf output) 안에 있는가.
           - 삭제된 이름(forbidden_refs)을 아직 참조하면 실패
           - kustomization.yaml에 등재되지 않은 잔재 매니페스트 적발
             (8/4 §4.5 “고친 파일이 kustomize resources에 없어 반영 안 됨” 재발 방지)

    [라이브] 클러스터에 그 Secret/ConfigMap이 실제로 존재하고 키까지 맞는가.
           - gochuchamchi-db-app 은 배스천이 런타임에 만드는 Secret이라
             “terraform apply 성공”이 존재를 보장하지 않는다 → 반드시 실측
           - 배포된 Deployment가 참조하는 이름이 실제로 해석되는가
             (CreateContainerConfigError의 사전 탐지)

.PARAMETER ContractJson
  계약 JSON 문자열. 생략하면 -TerraformDir에서 `terraform output -json deployment_contract`로 읽는다.
  (apply 도중 호출될 때는 state가 확정 전이라 terraform output을 쓰면 안 되므로
   smoke-test.tf가 이 인자로 값을 넘긴다)

.PARAMETER GitopsPath
  gochuchamchi-gitops 저장소의 로컬 클론 경로. 없으면 정적 검증은 건너뛴다.

.EXAMPLE
  .\verify-contract.ps1 -GitopsPath C:\Users\me\Desktop\3pro\git\gochuchamchi-gitops
#>
[CmdletBinding()]
param(
  [string] $ContractJson,
  [string] $TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
  [string] $GitopsPath,
  [switch] $SkipCluster,
  [switch] $SkipStatic
)

$ErrorActionPreference = 'Continue'
$script:Results = New-Object System.Collections.ArrayList

function Add-Result {
  param([string]$Section, [string]$Check, [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')][string]$Status, [string]$Detail = '')
  [void]$script:Results.Add([pscustomobject]@{ Section = $Section; Check = $Check; Status = $Status; Detail = $Detail })
}

function Test-Command { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# ---------------------------------------------------------------------------
# 0. 계약 로드
# ---------------------------------------------------------------------------
if (-not $ContractJson) {
  if (-not (Test-Command 'terraform')) {
    Write-Error 'terraform 실행 파일을 찾을 수 없고 -ContractJson도 없습니다.'
    exit 2
  }
  Push-Location $TerraformDir
  $ContractJson = (& terraform output -json deployment_contract 2>&1) -join "`n"
  $tfExit = $LASTEXITCODE
  Pop-Location
  if ($tfExit -ne 0) {
    Write-Error "terraform output 실패. contract.tf가 apply되지 않았을 수 있습니다.`n$ContractJson"
    exit 2
  }
}

try { $contract = $ContractJson | ConvertFrom-Json }
catch { Write-Error "계약 JSON 파싱 실패: $_"; exit 2 }

if ($contract.version -ne 1) {
  Add-Result '계약' "버전 $($contract.version)" 'WARN' '이 스크립트는 version 1 기준입니다. 필드가 바뀌었을 수 있습니다.'
}

$ns = $contract.namespace
$allowedNames = @()
$allowedNames += $contract.secrets | ForEach-Object { $_.name }
$allowedNames += $contract.config_maps | ForEach-Object { $_.name }
$forbidden = @($contract.forbidden_refs)

# ---------------------------------------------------------------------------
# 1. 정적 검증 — gitops 매니페스트
# ---------------------------------------------------------------------------
if ($SkipStatic -or -not $GitopsPath) {
  Add-Result '정적' 'gitops 매니페스트 대조' 'SKIP' '-GitopsPath 미지정 (라이브 검증만 수행)'
}
elseif (-not (Test-Path $GitopsPath)) {
  Add-Result '정적' 'gitops 매니페스트 대조' 'FAIL' "경로 없음: $GitopsPath"
}
else {
  $yamlFiles = Get-ChildItem -Path $GitopsPath -Recurse -Include *.yaml, *.yml -File |
    Where-Object { $_.FullName -notmatch '\\\.git\\' }

  if ($yamlFiles.Count -eq 0) {
    Add-Result '정적' 'gitops 매니페스트 대조' 'FAIL' "YAML 파일을 찾지 못함: $GitopsPath"
  }
  else {
    # secretRef/configMapRef/secretKeyRef/configMapKeyRef 바로 뒤의 name: 값을 수집.
    # 블록 스타일(줄바꿈 후 name:)과 인라인 플로우({name: x}) 둘 다 대응.
    $refRegex = [regex]'(?m)(secretRef|configMapRef|secretKeyRef|configMapKeyRef)\s*:\s*\{?\s*(?:\r?\n\s*)?name\s*:\s*["'']?([A-Za-z0-9._-]+)'

    $found = @{}
    foreach ($f in $yamlFiles) {
      $text = Get-Content -Raw -LiteralPath $f.FullName
      foreach ($m in $refRegex.Matches($text)) {
        $name = $m.Groups[2].Value
        if (-not $found.ContainsKey($name)) { $found[$name] = @() }
        if ($found[$name] -notcontains $f.Name) { $found[$name] += $f.Name }
      }
      # forbidden은 참조 형태와 무관하게 문자열 자체를 금지 (주석에 남아 있어도 알림)
      foreach ($bad in $forbidden) {
        if ($text -match [regex]::Escape($bad)) {
          Add-Result '정적' "금지된 이름 참조: $bad" 'FAIL' "$($f.Name) — 제로트러스트 전환으로 삭제된 이름입니다. gochuchamchi-db-app 으로 교체하세요."
        }
      }
    }

    # 참조하는데 계약에 없는 이름
    foreach ($name in $found.Keys) {
      if ($forbidden -contains $name) { continue }
      if ($allowedNames -contains $name) {
        Add-Result '정적' "참조 OK: $name" 'PASS' ($found[$name] -join ', ')
      }
      else {
        Add-Result '정적' "계약에 없는 이름 참조: $name" 'FAIL' "$($found[$name] -join ', ') — terraform이 만들지 않는 이름입니다."
      }
    }

    # 계약에 있는데 아무도 참조 안 하는 이름 (주입해도 앱이 안 쓰는 상태)
    foreach ($name in $allowedNames) {
      if (-not $found.ContainsKey($name)) {
        Add-Result '정적' "미참조: $name" 'WARN' 'terraform이 만들지만 gitops가 참조하지 않습니다 (envFrom 누락 가능성).'
      }
    }

    # Service 이름 / 파드 라벨 — 방향이 반대인 계약 (terraform이 gitops를 참조)
    $allText = ($yamlFiles | ForEach-Object { Get-Content -Raw -LiteralPath $_.FullName }) -join "`n"
    if ($allText -match ("(?m)^\s*name\s*:\s*" + [regex]::Escape($contract.service.name) + "\s*$")) {
      Add-Result '정적' "Service 이름: $($contract.service.name)" 'PASS' 'Ingress 백엔드와 일치'
    }
    else {
      Add-Result '정적' "Service 이름: $($contract.service.name)" 'FAIL' 'gitops에 이 이름의 Service가 없습니다 → ALB 타겟 미등록(503)'
    }

    if ($contract.services) {
      foreach ($entry in $contract.services.PSObject.Properties) {
        $serviceName = $entry.Value.name
        if ($allText -match ("(?m)^\s*name\s*:\s*" + [regex]::Escape($serviceName) + "\s*$")) {
          Add-Result '정적' "Service[$($entry.Name)]: $serviceName" 'PASS' 'Ingress 배포 계약과 일치'
        }
        else {
          Add-Result '정적' "Service[$($entry.Name)]: $serviceName" 'FAIL' 'gitops에 이 이름의 Service가 없습니다.'
        }
      }
    }

    $labelKey = ($contract.pod_labels.PSObject.Properties | Select-Object -First 1)
    if ($allText -match ("(?m)^\s*" + [regex]::Escape($labelKey.Name) + "\s*:\s*" + [regex]::Escape($labelKey.Value) + "\s*$")) {
      Add-Result '정적' "파드 라벨: $($labelKey.Name)=$($labelKey.Value)" 'PASS' 'NetworkPolicy pod_selector와 일치'
    }
    else {
      Add-Result '정적' "파드 라벨: $($labelKey.Name)=$($labelKey.Value)" 'FAIL' 'NetworkPolicy가 어떤 파드에도 안 걸립니다 → default-deny만 남아 앱 전체 차단'
    }


    if ($contract.pod_labels_all) {
      foreach ($workload in $contract.pod_labels_all.PSObject.Properties) {
        $workloadLabel = ($workload.Value.PSObject.Properties | Select-Object -First 1)
        if ($allText -match ("(?m)^\s*" + [regex]::Escape($workloadLabel.Name) + "\s*:\s*" + [regex]::Escape($workloadLabel.Value) + "\s*$")) {
          Add-Result '정적' "파드 라벨[$($workload.Name)]: $($workloadLabel.Name)=$($workloadLabel.Value)" 'PASS' 'Deployment와 NetworkPolicy 계약 일치'
        }
        else {
          Add-Result '정적' "파드 라벨[$($workload.Name)]: $($workloadLabel.Name)=$($workloadLabel.Value)" 'FAIL' 'gitops에 이 파드 라벨이 없습니다.'
        }
      }
    }

    # kustomization 잔재 파일 (8/4 §4.5 재발 방지)
    $kust = $yamlFiles | Where-Object { $_.Name -match '^kustomization\.ya?ml$' } | Select-Object -First 1
    if ($kust) {
      $kustText = Get-Content -Raw -LiteralPath $kust.FullName
      $orphans = $yamlFiles |
        Where-Object {
          $_.DirectoryName -eq $kust.DirectoryName -and
          $_.Name -ne $kust.Name -and
          $_.Name -notmatch '^\.argocd-source-.*\.ya?ml$'
        } |
        Where-Object { $kustText -notmatch [regex]::Escape($_.Name) }
      if ($orphans) {
        Add-Result '정적' 'kustomize 미등재 매니페스트' 'FAIL' (($orphans | ForEach-Object { $_.Name }) -join ', ')
      }
      else {
        Add-Result '정적' 'kustomize 미등재 매니페스트' 'PASS' '모든 매니페스트가 resources에 등재됨'
      }
    }
    else {
      Add-Result '정적' 'kustomization.yaml' 'WARN' 'plain YAML 구조 — 잔재 파일이 조용히 무시될 수 있고 Image Updater git write-back도 불가 (백로그)'
    }
  }
}

# ---------------------------------------------------------------------------
# 2. 라이브 검증 — 클러스터 실측
# ---------------------------------------------------------------------------
if ($SkipCluster) {
  Add-Result '라이브' '클러스터 실측' 'SKIP' '-SkipCluster 지정'
}
elseif (-not (Test-Command 'kubectl')) {
  Add-Result '라이브' '클러스터 실측' 'FAIL' 'kubectl을 찾을 수 없습니다.'
}
else {
  $liveNames = @{}

  foreach ($cm in $contract.config_maps) {
    $json = (& kubectl -n $ns get configmap $cm.name -o json 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
      Add-Result '라이브' "ConfigMap $($cm.name)" 'FAIL' '클러스터에 없음'
      continue
    }
    $obj = $json | ConvertFrom-Json
    $keys = @($obj.data.PSObject.Properties.Name)
    $missing = @($cm.keys | Where-Object { $keys -notcontains $_ })
    if ($missing) { Add-Result '라이브' "ConfigMap $($cm.name)" 'FAIL' "키 누락: $($missing -join ', ')" }
    else { Add-Result '라이브' "ConfigMap $($cm.name)" 'PASS' "키 $($keys.Count)개" }
    $liveNames[$cm.name] = $true
  }

  foreach ($sec in $contract.secrets) {
    $json = (& kubectl -n $ns get secret $sec.name -o json 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0) {
      $hint = if ($sec.owner -match 'bastion') { '배스천 프로비저너 미실행 → terraform taint null_resource.provision_app_db_user 후 apply' } else { 'terraform apply 필요' }
      Add-Result '라이브' "Secret $($sec.name)" 'FAIL' "클러스터에 없음 ($hint)"
      continue
    }
    $obj = $json | ConvertFrom-Json
    $keys = @($obj.data.PSObject.Properties.Name)
    $missing = @($sec.keys | Where-Object { $keys -notcontains $_ })
    if ($missing) { Add-Result '라이브' "Secret $($sec.name)" 'FAIL' "키 누락: $($missing -join ', ')" }
    else { Add-Result '라이브' "Secret $($sec.name)" 'PASS' "키: $($keys -join ', ')" }
    $liveNames[$sec.name] = $true
  }

  # 실제 배포된 Deployment가 참조하는 이름이 전부 해석되는가
  $depJson = (& kubectl -n $ns get deploy -o json 2>&1) -join "`n"
  if ($LASTEXITCODE -ne 0) {
    Add-Result '라이브' 'Deployment 참조 해석' 'WARN' "Deployment 조회 실패 (ArgoCD 미배포 상태일 수 있음)"
  }
  else {
    $deps = ($depJson | ConvertFrom-Json).items
    if (-not $deps -or $deps.Count -eq 0) {
      Add-Result '라이브' 'Deployment 참조 해석' 'WARN' "$ns 에 Deployment가 없음 — ArgoCD가 아직 배포하지 않음(PAT 주입 확인)"
    }
    else {
      foreach ($d in $deps) {
        $refs = New-Object System.Collections.ArrayList
        foreach ($c in @($d.spec.template.spec.containers)) {
          foreach ($ef in @($c.envFrom)) {
            if ($ef.secretRef.name) { [void]$refs.Add($ef.secretRef.name) }
            if ($ef.configMapRef.name) { [void]$refs.Add($ef.configMapRef.name) }
          }
          foreach ($e in @($c.env)) {
            if ($e.valueFrom.secretKeyRef.name) { [void]$refs.Add($e.valueFrom.secretKeyRef.name) }
            if ($e.valueFrom.configMapKeyRef.name) { [void]$refs.Add($e.valueFrom.configMapKeyRef.name) }
          }
        }
        foreach ($v in @($d.spec.template.spec.volumes)) {
          if ($v.secret.secretName) { [void]$refs.Add($v.secret.secretName) }
          if ($v.configMap.name) { [void]$refs.Add($v.configMap.name) }
        }

        $bad = @()
        foreach ($r in ($refs | Select-Object -Unique)) {
          if ($liveNames.ContainsKey($r)) { continue }
          $exists = $false
          & kubectl -n $ns get secret $r -o name 2>&1 | Out-Null
          if ($LASTEXITCODE -eq 0) { $exists = $true }
          else {
            & kubectl -n $ns get configmap $r -o name 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $exists = $true }
          }
          if (-not $exists) { $bad += $r }
        }

        if ($bad) {
          Add-Result '라이브' "Deployment $($d.metadata.name) 참조" 'FAIL' "해석 불가: $($bad -join ', ') → 새 파드는 CreateContainerConfigError로 못 뜹니다"
        }
        else {
          Add-Result '라이브' "Deployment $($d.metadata.name) 참조" 'PASS' "$(($refs | Select-Object -Unique).Count)개 참조 모두 해석됨"
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 3. 결과 출력
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 배포 계약 검증 ===' -ForegroundColor Cyan
foreach ($r in $script:Results) {
  $color = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
  Write-Host ("  [{0}] {1,-10} {2}" -f $r.Status, $r.Section, $r.Check) -ForegroundColor $color
  if ($r.Detail) { Write-Host ("         {0}" -f $r.Detail) -ForegroundColor DarkGray }
}

$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
Write-Host ''
Write-Host ("계약 검증: 실패 {0} / 경고 {1} / 전체 {2}" -f $failCount, $warnCount, $script:Results.Count)

if ($failCount -gt 0) { exit 1 } else { exit 0 }
