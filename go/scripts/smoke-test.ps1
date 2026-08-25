<#
.SYNOPSIS
  apply 후 스모크 테스트  (2026-08-04 자동화 2/3)

.DESCRIPTION
  "terraform apply는 성공했는데 서비스는 죽어 있는" 상태를 자동으로 잡아낸다.
  이 프로젝트에서 실제로 겪은 실패를 하나씩 검사 항목으로 옮겨놨다:

    #2  kubectl 컨텍스트가 지금 클러스터인가        <- 8/3 "no such host" (옛 클러스터 kubeconfig)
    #4  배포 계약 (Secret/ConfigMap 이름·키)         <- 8/4 CreateContainerConfigError
    #5  파드 상태 / 이미지 pull                      <- 8/3 ImagePullBackOff (빈 ECR)
    #6  ExternalSecret 동기화                        <- 8/4 PAT 미주입 -> 앱 미배포(503)
    #8  파드에서 DNS 해석                            <- 8/4 NetworkPolicy DNS 차단(전체 500)
    #9  파드에서 RDS 3306 / Redis 6379 도달          <- 제로트러스트 SG/netpol 회귀 감지
    #11 사이트 HTTP 응답 (/ , /api/health)           <- 최종 사용자 관점 확인
    #12 ALB 타겟 헬스                                 <- 타겟 미등록/헬스체크 실패
    #13 Pod Identity 자격증명 주입                    <- 8/6 Grafana No data (IMDS 폴백)

  기본은 경고 모드(-Enforce 미지정): 결과만 출력하고 종료코드 0.
  재구축 직후에는 PAT 수동 주입 전이라 앱이 안 떠 있는 게 정상이기 때문.

.EXAMPLE
  .\smoke-test.ps1                       # 로컬에서 수동 실행 (terraform output에서 계약 조회)
  .\smoke-test.ps1 -Enforce              # 실패 시 종료코드 1
  .\smoke-test.ps1 -FixPodIdentity       # #13에서 자격증명 누락 파드를 찾으면 재시작까지

.NOTES
  이 파일은 반드시 UTF-8 **BOM 포함**으로 저장할 것 (preflight-check.ps1과 동일 이유).
#>
[CmdletBinding()]
param(
  [string] $ContractJson,
  [string] $TerraformDir = (Join-Path $PSScriptRoot '..\terraform'),
  [string] $GitopsPath,
  [string] $Region = 'ap-northeast-2',
  [string] $AwsProfile = 'workload-admin',
  [switch] $Enforce,
  [switch] $SkipHttp,
  # #13에서 자격증명 누락 파드를 찾으면 rollout restart까지 실행한다.
  # 누락된 파드는 재시작 말고는 고칠 방법이 없어서(주입은 파드 생성 시 1회뿐)
  # apply 파이프라인에서는 기본으로 켠다 — smoke-test.tf의 pod_identity_autofix.
  [switch] $FixPodIdentity
)

$ErrorActionPreference = 'Continue'
$script:Results = New-Object System.Collections.ArrayList
$started = Get-Date

function Add-Result {
  param([string]$Check, [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')][string]$Status, [string]$Detail = '')
  [void]$script:Results.Add([pscustomobject]@{ Check = $Check; Status = $Status; Detail = $Detail })
  $color = switch ($Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } 'WARN' { 'Yellow' } default { 'DarkGray' } }
  Write-Host ("  [{0}] {1}" -f $Status, $Check) -ForegroundColor $color
  if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor DarkGray }
}
function Test-Command { param([string]$Name) return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }
# $Args는 PowerShell 자동 변수라 파라미터 이름으로 쓰지 않는다 (충돌 방지)
function Invoke-Cli {
  param([string]$File, [string[]]$CliArgs)
  $out = (& $File @CliArgs 2>&1) -join "`n"
  return [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Out = $out }
}

Write-Host ''
Write-Host '=== gochuchamchi 스모크 테스트 ===' -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 0. 계약 로드
# ---------------------------------------------------------------------------
if (-not $ContractJson) {
  if (-not (Test-Command 'terraform')) { Write-Error 'terraform도 -ContractJson도 없습니다.'; exit 2 }
  Push-Location $TerraformDir
  $ContractJson = (& terraform output -json deployment_contract 2>&1) -join "`n"
  $tfExit = $LASTEXITCODE
  Pop-Location
  if ($tfExit -ne 0) { Write-Error "terraform output 실패 — contract.tf가 apply되었는지 확인하세요.`n$ContractJson"; exit 2 }
}
try { $contract = $ContractJson | ConvertFrom-Json } catch { Write-Error "계약 JSON 파싱 실패: $_"; exit 2 }

$ns = $contract.namespace
$labelKey = ($contract.pod_labels.PSObject.Properties | Select-Object -First 1)
$selector = "$($labelKey.Name)=$($labelKey.Value)"
$dbHost = $contract.endpoints.db_host
$redisHost = $contract.endpoints.redis_host
$primaryHost = @($contract.endpoints.hosts)[0]

# ---------------------------------------------------------------------------
# 1. 도구
# ---------------------------------------------------------------------------
$hasKubectl = Test-Command 'kubectl'
$hasAws = Test-Command 'aws'
$hasCurl = Test-Command 'curl.exe'
if ($hasKubectl) { Add-Result '1. kubectl 존재' 'PASS' } else { Add-Result '1. kubectl 존재' 'FAIL' 'kubectl 없이는 대부분의 검사를 못 합니다' }

# ---------------------------------------------------------------------------
# 2. kubectl 컨텍스트가 "지금" 클러스터를 가리키는가
#    8/3: destroy/apply로 클러스터를 새로 만들었는데 kubeconfig가 삭제된 옛 클러스터를
#    가리켜 모든 kubectl이 no such host. 검증 전에 이것부터 봐야 나머지가 의미가 있다.
# ---------------------------------------------------------------------------
if ($hasKubectl) {
  $ctx = Invoke-Cli 'kubectl' @('config', 'current-context')
  if ($ctx.Ok -and $ctx.Out -match [regex]::Escape($contract.cluster_name)) {
    Add-Result '2. kubectl 컨텍스트' 'PASS' $ctx.Out.Trim()
  }
  else {
    Add-Result '2. kubectl 컨텍스트' 'FAIL' "현재: $($ctx.Out.Trim()) / 기대: *$($contract.cluster_name)* → aws eks update-kubeconfig --name $($contract.cluster_name) --region $Region --profile $AwsProfile"
  }
}

# ---------------------------------------------------------------------------
# 3. 노드
# ---------------------------------------------------------------------------
if ($hasKubectl) {
  $nodes = Invoke-Cli 'kubectl' @('get', 'nodes', '-o', 'json')
  if (-not $nodes.Ok) {
    Add-Result '3. 노드 Ready' 'FAIL' "API 서버 접속 실패 — EKS 퍼블릭 엔드포인트 /32 허용목록에 현재 IP가 있는지 확인 (variables.tf endpoint_public_access_cidrs)"
  }
  else {
    $items = ($nodes.Out | ConvertFrom-Json).items
    $ready = @($items | Where-Object { ($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }) }).Count
    if ($ready -ge 2) { Add-Result '3. 노드 Ready' 'PASS' "$ready/$($items.Count) Ready (t3.small 노드그룹 min 2)" }
    elseif ($ready -gt 0) { Add-Result '3. 노드 Ready' 'WARN' "$ready/$($items.Count) Ready — 롤링 중이거나 축소된 상태" }
    else { Add-Result '3. 노드 Ready' 'FAIL' '준비된 노드가 없습니다' }
  }
}

# ---------------------------------------------------------------------------
# 4. 배포 계약 검증 (별도 스크립트 위임)
# ---------------------------------------------------------------------------
$verifier = Join-Path $PSScriptRoot 'verify-contract.ps1'
if (Test-Path $verifier) {
  # 해시테이블 스플래팅 — 배열 스플래팅(@배열)은 요소가 위치 인자로 해석되는
  # 경우가 있어 파라미터 바인딩이 깨진다. 이름-값 쌍은 해시테이블로 넘긴다.
  $vParams = @{ ContractJson = $ContractJson }
  if ($GitopsPath) { $vParams['GitopsPath'] = $GitopsPath }
  if (-not $hasKubectl) { $vParams['SkipCluster'] = $true }
  & $verifier @vParams
  if ($LASTEXITCODE -eq 0) { Add-Result '4. 배포 계약' 'PASS' 'Secret/ConfigMap 이름·키 일치' }
  else { Add-Result '4. 배포 계약' 'FAIL' '위 계약 검증 출력 참고 (gitops 이름 불일치 또는 Secret 미주입)' }
}
else {
  Add-Result '4. 배포 계약' 'SKIP' "verify-contract.ps1 없음: $verifier"
}

# ---------------------------------------------------------------------------
# 5. 파드 상태
# ---------------------------------------------------------------------------
$appPod = $null
if ($hasKubectl) {
  $pods = Invoke-Cli 'kubectl' @('-n', $ns, 'get', 'pods', '-o', 'json')
  if (-not $pods.Ok) {
    Add-Result '5. 파드 상태' 'FAIL' "네임스페이스 $ns 조회 실패"
  }
  else {
    $items = @(($pods.Out | ConvertFrom-Json).items)
    if ($items.Count -eq 0) {
      Add-Result '5. 파드 상태' 'WARN' "$ns 에 파드가 없습니다 — ArgoCD 미배포 상태(#6 확인)"
    }
    else {
      $bad = @()
      foreach ($p in $items) {
        $waiting = @($p.status.containerStatuses | ForEach-Object { $_.state.waiting.reason } | Where-Object { $_ })
        $restarts = (@($p.status.containerStatuses | ForEach-Object { $_.restartCount }) | Measure-Object -Sum).Sum
        $isReady = @($p.status.conditions | Where-Object {
            $_.type -eq 'Ready' -and $_.status -eq 'True'
          }).Count -gt 0
        if ($p.status.phase -ne 'Running' -or $waiting.Count -gt 0 -or -not $isReady) {
          $state = if (-not $isReady -and $p.status.phase -eq 'Running' -and $waiting.Count -eq 0) {
            'Running but NotReady — readiness/startup probe 확인'
          } else {
            "$($p.status.phase) $($waiting -join ',')"
          }
          $bad += "$($p.metadata.name): $state"
        }
        elseif ($restarts -ge 5) {
          # $restarts회 로 쓰면 "회"까지 변수명으로 먹혀 값이 사라진다 — $() 로 끊을 것
          $bad += "$($p.metadata.name): 재시작 $($restarts)회"
        }
      }
      if ($bad.Count -eq 0) {
        Add-Result '5. 파드 상태' 'PASS' "$($items.Count)개 Running"
        $appPod = (@($items | Where-Object { $_.metadata.labels.$($labelKey.Name) -eq $labelKey.Value }) | Select-Object -First 1).metadata.name
      }
      else {
        $hint = if ($bad -match 'CreateContainerConfigError') { ' → Secret/ConfigMap 이름 불일치(#4)' } elseif ($bad -match 'ImagePull') { ' → ECR이 비었을 수 있음. 앱 CI 재실행' } else { '' }
        Add-Result '5. 파드 상태' 'FAIL' (($bad -join ' | ') + $hint)
      }
    }
  }
}

# ---------------------------------------------------------------------------
# 6. ExternalSecret (ESO) — PAT 주입 여부가 여기서 드러난다
# ---------------------------------------------------------------------------
if ($hasKubectl) {
  $es = Invoke-Cli 'kubectl' @('get', 'externalsecret', '-A', '-o', 'json')
  if (-not $es.Ok) {
    Add-Result '6. ExternalSecret' 'WARN' 'CRD 없음 — ESO 미설치 상태일 수 있음(eso.tf apply 확인)'
  }
  else {
    $items = @(($es.Out | ConvertFrom-Json).items)
    if ($items.Count -eq 0) { Add-Result '6. ExternalSecret' 'WARN' 'ExternalSecret CR이 없습니다 (helm_release.eso_config 확인)' }
    else {
      $notReady = @()
      foreach ($e in $items) {
        $ok = @($e.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        if (-not $ok) { $notReady += "$($e.metadata.namespace)/$($e.metadata.name)" }
      }
      if ($notReady.Count -eq 0) { Add-Result '6. ExternalSecret' 'PASS' "$($items.Count)개 SecretSynced" }
      else { Add-Result '6. ExternalSecret' 'FAIL' "$($notReady -join ', ') — PAT 미주입 가능성. terraform output argocd_git_pat_inject_command 참고" }
    }
  }
}

# ---------------------------------------------------------------------------
# 7. ArgoCD Application
# ---------------------------------------------------------------------------
if ($hasKubectl) {
  $apps = Invoke-Cli 'kubectl' @('-n', 'argocd', 'get', 'applications', '-o', 'json')
  if (-not $apps.Ok) {
    Add-Result '7. ArgoCD Application' 'SKIP' 'CRD/네임스페이스 조회 실패'
  }
  else {
    $items = @(($apps.Out | ConvertFrom-Json).items)
    if ($items.Count -eq 0) { Add-Result '7. ArgoCD Application' 'WARN' 'Application이 없습니다' }
    else {
      $bad = @($items | Where-Object { $_.status.sync.status -ne 'Synced' -or $_.status.health.status -ne 'Healthy' } |
          ForEach-Object { "$($_.metadata.name): $($_.status.sync.status)/$($_.status.health.status)" })
      if ($bad.Count -eq 0) { Add-Result '7. ArgoCD Application' 'PASS' "$($items.Count)개 Synced/Healthy" }
      else { Add-Result '7. ArgoCD Application' 'FAIL' ($bad -join ' | ') }
    }
  }
}

# ---------------------------------------------------------------------------
# 8. 파드에서 DNS 해석 — netpol 검증은 반드시 여기서 시작 (8/4 교훈)
# ---------------------------------------------------------------------------
if ($hasKubectl -and $appPod) {
  $dns = Invoke-Cli 'kubectl' @('-n', $ns, 'exec', $appPod, '--', 'getent', 'hosts', $dbHost)
  if ($dns.Ok -and $dns.Out.Trim()) {
    Add-Result '8. 파드 DNS 해석' 'PASS' $dns.Out.Trim()
  }
  elseif ($dns.Out -match 'executable file not found|OCI runtime') {
    Add-Result '8. 파드 DNS 해석' 'SKIP' '컨테이너에 getent 없음'
  }
  else {
    Add-Result '8. 파드 DNS 해석' 'FAIL' "RDS 호스트명 해석 실패 → NetworkPolicy DNS egress에 서비스 CIDR($($contract.cluster_name)의 cluster_service_cidr)이 열려 있는지 확인. 롤백: kubectl -n $ns delete netpol --all"
  }
}
else { Add-Result '8. 파드 DNS 해석' 'SKIP' '앱 파드를 찾지 못함' }

# ---------------------------------------------------------------------------
# 9. 파드에서 RDS 3306 / Redis 6379 TCP 도달
# ---------------------------------------------------------------------------
if ($hasKubectl -and $appPod) {
  foreach ($t in @(@{ n = 'RDS 3306'; h = $dbHost; p = 3306 }, @{ n = 'Redis 6379'; h = $redisHost; p = 6379 })) {
    if (-not $t.h) { Add-Result "9. TCP $($t.n)" 'SKIP' '엔드포인트 미확인'; continue }
    $probe = "timeout 5 bash -c 'exec 3<>/dev/tcp/$($t.h)/$($t.p)' && echo OPEN"
    $r = Invoke-Cli 'kubectl' @('-n', $ns, 'exec', $appPod, '--', 'sh', '-c', $probe)
    if ($r.Out -match 'OPEN') { Add-Result "9. TCP $($t.n)" 'PASS'; continue }

    # `/dev/tcp`는 bash 전용 기능이라 sh만 있는 이미지(alpine/distroless 계열)에서는
    # 쓸 수 없다. 이때 나오는 메시지는 'not found'가 아니라
    # `timeout: failed to run command 'bash': No such file or directory`여서
    # 예전에는 이게 FAIL로 떨어졌다 — 앱이 멀쩡히 DB에 붙어 있는데도 매번 실패 2건이
    # 찍혀 경고 피로를 만들었다 (2026-08-05). 도구 부재와 진짜 차단을 구분한다.
    if ($r.Out -match 'not found|No such file|exit code 127') {
      # 검사 목적(SG 참조 규칙·NetworkPolicy egress 회귀 감지)은 앱이 실제로 커넥션을
      # 맺었는지로 대신 확인할 수 있다. RDS는 HikariPool 로그가 확정적인 증거다.
      if ($t.n -like 'RDS*') {
        $lg = Invoke-Cli 'kubectl' @('logs', '-n', $ns, $appPod, '--tail=500')
        if ($lg.Out -match 'HikariPool-\d+ - Added connection') {
          Add-Result "9. TCP $($t.n)" 'PASS' '컨테이너에 bash 없음 — 앱 로그의 HikariPool 커넥션으로 확인'
          continue
        }
      }
      Add-Result "9. TCP $($t.n)" 'SKIP' '컨테이너에 bash 없음 (/dev/tcp는 bash 전용) — 도달성 미확인'
      continue
    }

    Add-Result "9. TCP $($t.n)" 'FAIL' 'SG(참조 규칙) 또는 NetworkPolicy egress 확인'
  }
}

# ---------------------------------------------------------------------------
# 10. Ingress / ALB
# ---------------------------------------------------------------------------
$albDns = $null
if ($hasKubectl) {
  $ing = Invoke-Cli 'kubectl' @('-n', $ns, 'get', 'ingress', '-o', 'json')
  if ($ing.Ok) {
    $items = @(($ing.Out | ConvertFrom-Json).items)
    $albDns = (@($items | ForEach-Object { $_.status.loadBalancer.ingress.hostname }) | Where-Object { $_ } | Select-Object -First 1)
    if ($albDns) { Add-Result '10. Ingress ALB 할당' 'PASS' $albDns }
    else { Add-Result '10. Ingress ALB 할당' 'FAIL' 'ALB 주소 미할당 — aws-load-balancer-controller 로그 확인' }
  }
  else { Add-Result '10. Ingress ALB 할당' 'FAIL' 'Ingress 조회 실패' }
}

# ---------------------------------------------------------------------------
# 11. 사이트 HTTP 응답
#     /api/health 는 인증 필요 경로라 302(로그인 리다이렉트)가 정상 — 500이면 장애.
#     (2026-08-04 복구 검증에서 확정된 기준)
# ---------------------------------------------------------------------------
if ($SkipHttp) { Add-Result '11. HTTP 응답' 'SKIP' '-SkipHttp 지정' }
elseif (-not $hasCurl) { Add-Result '11. HTTP 응답' 'SKIP' 'curl.exe 없음' }
else {
  foreach ($t in @(@{ path = '/'; expect = @('200') }, @{ path = '/api/health'; expect = @('302', '200') })) {
    $url = "https://$primaryHost$($t.path)"
    $code = (& curl.exe -s -o NUL -w "%{http_code}" -m 15 $url 2>&1)
    if ($t.expect -contains "$code") { Add-Result "11. HTTP $($t.path)" 'PASS' "$url -> $code" }
    elseif ("$code" -eq '000') { Add-Result "11. HTTP $($t.path)" 'FAIL' "$url 접속 불가 (DNS/ALB/인증서)" }
    else { Add-Result "11. HTTP $($t.path)" 'FAIL' "$url -> $code (기대: $($t.expect -join '/'))" }
  }
}

# ---------------------------------------------------------------------------
# 12. ALB 타겟 헬스 — 파드는 Running인데 타겟이 unhealthy인 구간을 잡는다
# ---------------------------------------------------------------------------
if ($hasAws -and $albDns) {
  $lbs = Invoke-Cli 'aws' @('elbv2', 'describe-load-balancers', '--region', $Region, '--profile', $AwsProfile, '--output', 'json')
  if ($lbs.Ok) {
    $lb = @(($lbs.Out | ConvertFrom-Json).LoadBalancers | Where-Object { $_.DNSName -eq $albDns }) | Select-Object -First 1
    if ($lb) {
      $tgs = Invoke-Cli 'aws' @('elbv2', 'describe-target-groups', '--load-balancer-arn', $lb.LoadBalancerArn, '--region', $Region, '--profile', $AwsProfile, '--output', 'json')
      $unhealthy = @(); $healthy = 0
      foreach ($tg in ($tgs.Out | ConvertFrom-Json).TargetGroups) {
        $th = Invoke-Cli 'aws' @('elbv2', 'describe-target-health', '--target-group-arn', $tg.TargetGroupArn, '--region', $Region, '--profile', $AwsProfile, '--output', 'json')
        foreach ($d in ($th.Out | ConvertFrom-Json).TargetHealthDescriptions) {
          if ($d.TargetHealth.State -eq 'healthy') { $healthy++ }
          else { $unhealthy += "$($tg.TargetGroupName)/$($d.Target.Id): $($d.TargetHealth.State)" }
        }
      }
      if ($healthy -gt 0 -and $unhealthy.Count -eq 0) { Add-Result '12. ALB 타겟 헬스' 'PASS' "healthy $healthy" }
      elseif ($healthy -gt 0) { Add-Result '12. ALB 타겟 헬스' 'WARN' "healthy $healthy / 문제: $($unhealthy -join ', ')" }
      else { Add-Result '12. ALB 타겟 헬스' 'FAIL' "healthy 타겟 0개 — 503의 직접 원인. $($unhealthy -join ', ')" }
    }
    else { Add-Result '12. ALB 타겟 헬스' 'SKIP' 'ALB를 찾지 못함' }
  }
  else { Add-Result '12. ALB 타겟 헬스' 'SKIP' 'aws elbv2 호출 실패(권한/프로파일)' }
}
else { Add-Result '12. ALB 타겟 헬스' 'SKIP' 'aws CLI 또는 ALB 주소 없음' }

# ---------------------------------------------------------------------------
# 13. Pod Identity 자격증명 주입  (2026-08-06)
#
# 왜 — Pod Identity의 env(AWS_CONTAINER_CREDENTIALS_FULL_URI)와 토큰 볼륨 주입은
#   파드가 "생성되는 순간" EKS admission이 딱 한 번 한다. association이 아직 전파되기
#   전에 파드가 뜨면 주입이 통째로 빠지고, AWS SDK는 자격증명 체인 끝의 IMDS로 폴백해
#   "no EC2 IMDS role found"로 죽는다.
#   이게 특히 안 잡히는 이유 — 파드는 Running/Ready라서 #5는 PASS로 지나간다. 증상은
#   한참 뒤에 "그 파드의 AWS 호출만 전부 실패"로 나타난다. 8/6 Grafana 대시보드가
#   전 패널 No data였던 게 정확히 이 경우였고, depends_on이 걸려 있었는데도 발생했다.
#   module/grafana의 time_sleep으로 확률은 낮췄지만 노드 교체·수동 재배포로 언제든
#   다시 날 수 있어서, 원인이 아니라 결과를 여기서 직접 확인한다.
#
# 고치는 법이 재시작뿐인 이유 — 주입 기회는 파드 생성 시 1회뿐이다. association을
#   나중에 고쳐도 이미 뜬 파드는 끝까지 자격증명이 없다.
#
# 대상 추가 — Pod Identity association을 새로 만들면 아래에 한 줄 추가할 것
#   (eks-pod-identity.tf, module/grafana/main.tf의 aws_eks_pod_identity_association).
# ---------------------------------------------------------------------------
$script:PodIdentityTargets = @(
  @{ ns = 'monitoring'; sa = 'grafana' }
  @{ ns = $ns; sa = 'gochuchamchi-app' }
  @{ ns = 'kube-system'; sa = 'aws-load-balancer-controller' }
  @{ ns = 'kube-system'; sa = 'cluster-autoscaler' }
  @{ ns = 'kube-system'; sa = 'efs-csi-controller-sa' }
  @{ ns = 'external-dns'; sa = 'external-dns' }
  @{ ns = 'argocd'; sa = 'argocd-image-updater' }
)

# admission이 넣은 env는 파드 spec에 그대로 남으므로 exec 없이 확인할 수 있다.
# (exec는 컨테이너에 셸이 없으면 실패해서 도구 부재와 진짜 누락이 섞인다 — #9 교훈)
function Get-PodIdentityState {
  param([string]$Namespace, [string]$ServiceAccount)
  $pods = Invoke-Cli 'kubectl' @('-n', $Namespace, 'get', 'pods', '-o', 'json')
  if (-not $pods.Ok) { return $null }   # 네임스페이스 자체가 없음/조회 실패
  $items = @(($pods.Out | ConvertFrom-Json).items | Where-Object {
      $_.spec.serviceAccountName -eq $ServiceAccount -and -not $_.metadata.deletionTimestamp
    })
  $missing = New-Object System.Collections.ArrayList
  foreach ($p in $items) {
    $has = $false
    foreach ($c in @($p.spec.containers)) {
      if (@($c.env | Where-Object { $_.name -eq 'AWS_CONTAINER_CREDENTIALS_FULL_URI' }).Count -gt 0) { $has = $true; break }
    }
    if (-not $has) { [void]$missing.Add($p) }
  }
  return [pscustomobject]@{ Total = $items.Count; Missing = @($missing) }
}

# 재시작 대상은 파드가 아니라 그 파드를 만든 워크로드다. 파드를 직접 지우면 Deployment는
# 어차피 같은 ReplicaSet으로 다시 만들지만, rollout restart 쪽이 상태 추적(rollout status)이
# 되고 DaemonSet/StatefulSet까지 같은 방식으로 다룰 수 있다.
function Get-OwnerWorkload {
  param([string]$Namespace, $Pod)
  $owner = @($Pod.metadata.ownerReferences) | Select-Object -First 1
  if (-not $owner) { return $null }
  if ($owner.kind -eq 'ReplicaSet') {
    $rs = Invoke-Cli 'kubectl' @('-n', $Namespace, 'get', 'rs', $owner.name, '-o', 'json')
    if (-not $rs.Ok) { return $null }
    $rsOwner = @(($rs.Out | ConvertFrom-Json).metadata.ownerReferences) | Select-Object -First 1
    if ($rsOwner) { return "$($rsOwner.kind.ToLower())/$($rsOwner.name)" }
    return $null
  }
  if (@('DaemonSet', 'StatefulSet', 'Deployment') -contains $owner.kind) { return "$($owner.kind.ToLower())/$($owner.name)" }
  return $null   # Job/스탠드얼론 파드 등 — 재시작 개념이 없다
}

if (-not $hasKubectl) {
  Add-Result '13. Pod Identity 주입' 'SKIP' 'kubectl 없음'
}
else {
  $injected = 0
  $absent = @()   # 아직 배포되지 않은 대상 (재구축 직후에는 정상)
  $broken = New-Object System.Collections.ArrayList

  foreach ($t in $script:PodIdentityTargets) {
    $state = Get-PodIdentityState -Namespace $t.ns -ServiceAccount $t.sa
    if (-not $state -or $state.Total -eq 0) { $absent += "$($t.ns)/$($t.sa)"; continue }
    $injected += ($state.Total - $state.Missing.Count)
    foreach ($p in $state.Missing) {
      [void]$broken.Add([pscustomobject]@{ Ns = $t.ns; Sa = $t.sa; Pod = $p })
    }
  }

  if ($broken.Count -eq 0) {
    # "$injected개"로 쓰면 "개"까지 변수명으로 먹혀 숫자가 사라진다 — $()로 끊을 것
    $detail = "$($injected)개 파드 주입 확인"
    if ($absent.Count -gt 0) { $detail += " / 미배포: $($absent -join ', ')" }
    Add-Result '13. Pod Identity 주입' 'PASS' $detail
  }
  elseif (-not $FixPodIdentity) {
    $names = @($broken | ForEach-Object { "$($_.Ns)/$($_.Pod.metadata.name)" })
    Add-Result '13. Pod Identity 주입' 'FAIL' ("자격증명 미주입 $($broken.Count)개: $($names -join ', ') — 해당 워크로드를 rollout restart 하세요 (-FixPodIdentity로 자동 실행)")
  }
  else {
    # 자동 복구: 워크로드 단위로 중복 제거해서 재시작 -> Ready 대기 -> 재확인
    $workloads = New-Object System.Collections.ArrayList
    foreach ($b in $broken) {
      $wl = Get-OwnerWorkload -Namespace $b.Ns -Pod $b.Pod
      if (-not $wl) {
        Write-Host ("        복구 불가(소유 워크로드 없음): {0}/{1}" -f $b.Ns, $b.Pod.metadata.name) -ForegroundColor DarkGray
        continue
      }
      $key = "$($b.Ns)|$wl"
      if (@($workloads | ForEach-Object { "$($_.Ns)|$($_.Wl)" }) -contains $key) { continue }
      [void]$workloads.Add([pscustomobject]@{ Ns = $b.Ns; Wl = $wl; Sa = $b.Sa })
    }

    $failedFix = @()
    foreach ($w in $workloads) {
      Write-Host ("        재시작: {0} -n {1}" -f $w.Wl, $w.Ns) -ForegroundColor Yellow
      $r = Invoke-Cli 'kubectl' @('-n', $w.Ns, 'rollout', 'restart', $w.Wl)
      if (-not $r.Ok) { $failedFix += "$($w.Ns)/$($w.Wl): restart 실패"; continue }
      $null = Invoke-Cli 'kubectl' @('-n', $w.Ns, 'rollout', 'status', $w.Wl, '--timeout=180s')
      $after = Get-PodIdentityState -Namespace $w.Ns -ServiceAccount $w.Sa
      if (-not $after -or $after.Missing.Count -gt 0) {
        $failedFix += "$($w.Ns)/$($w.Wl): 재시작 후에도 미주입"
      }
    }

    if ($failedFix.Count -eq 0) {
      Add-Result '13. Pod Identity 주입' 'WARN' ("미주입 $($broken.Count)개를 발견해 워크로드 $($workloads.Count)개를 재시작했습니다 — 지금은 정상입니다. 반복되면 association 전파 대기(module/grafana의 time_sleep)를 늘리세요.")
    }
    else {
      Add-Result '13. Pod Identity 주입' 'FAIL' ("자동 복구 실패: $($failedFix -join ' | ') — association 자체를 확인하세요 (namespace/service_account가 파드와 정확히 일치해야 합니다)")
    }
  }
}

# ---------------------------------------------------------------------------
# 결과
# ---------------------------------------------------------------------------
$fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' })
$warn = @($script:Results | Where-Object { $_.Status -eq 'WARN' })
$elapsed = [int]((Get-Date) - $started).TotalSeconds

Write-Host ''
Write-Host ("=== 스모크 테스트 결과: 실패 {0} / 경고 {1} / 전체 {2}  ({3}초) ===" -f $fail.Count, $warn.Count, $script:Results.Count, $elapsed) -ForegroundColor Cyan
foreach ($f in $fail) { Write-Host ("  FAIL  {0} — {1}" -f $f.Check, $f.Detail) -ForegroundColor Red }

if ($fail.Count -gt 0) {
  if ($Enforce) {
    Write-Error '스모크 테스트 실패 (enforce 모드) — apply를 실패로 처리합니다.'
    exit 1
  }
  Write-Host '경고 모드이므로 종료코드는 0입니다. 강제하려면 $env:TF_VAR_smoke_test_enforce = "true"' -ForegroundColor Yellow
}
exit 0
