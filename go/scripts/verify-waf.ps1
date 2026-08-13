# =============================================================================
# verify-waf.ps1 — WAF 적용 가이드의 잔여 검증 (8·9·10번)
#
#   가이드에 "해 보라"고만 적혀 있고 한 번도 실행되지 않은 항목들이다.
#     8번  ALB 직접 우회가 차단되는가
#     9번  SQLi 페이로드가 차단되는가
#     10번 WAF 로그가 실제로 쌓이는가
#   여기에 알람 4종과 Log 계정 구독필터 확인을 더했다.
#
#   ── 읽기 전에 알아야 할 것 ────────────────────────────────────────────────
#   ① WAF·WAF 로그 그룹은 us-east-1 에 있다. CloudFront 용 Web ACL 은 글로벌
#      스코프라 서울에서 조회하면 "없음"으로 나온다. 리전을 틀리면 멀쩡한 것을
#      고장으로 오진한다.
#   ② ALB 직접 접근은 두 겹으로 막혀 있고 겹마다 증상이 다르다.
#        - SG(CloudFront prefix list) 가 먼저 막으면 → TCP 연결 자체가 안 됨(타임아웃)
#        - 헤더 검증(X-Gochuchamchi-Origin-Verify)이 막으면 → 403
#      둘 다 "통과"다. 200 이 나오면 그때가 진짜 사고다.
#   ③ 차단 시험은 요청을 몇 건만 보낸다. rate 규칙(IP당)이 있어서 몰아치면
#      그 규칙에 걸린 것을 SQLi 차단으로 오독하게 된다.
#
# 사용: go\scripts\verify-waf.ps1
# 종료 코드: 0 통과 / 1 실패 / 2 미결(로그 지연 등으로 재실행 필요)
# =============================================================================

param(
    [string]$Site = "https://kycj.click",
    [int]$LogWaitSec = 90
)

$ErrorActionPreference = "Continue"
$env:AWS_PROFILE = "workload-admin"
# 한글·em-dash 가 든 리소스를 조회할 때 AWS CLI 가 cp949 로 인코딩하려다
# 죽는 것을 막는다 (2026-08-13 실측 — 안 걸면 "알람 0개"로 오진한다).
$env:PYTHONIOENCODING = "utf-8"

$region     = "ap-northeast-2"
$edgeRegion = "us-east-1"          # CloudFront 용 WAF 와 그 로그는 여기에 있다
$wafLogGroup = "aws-waf-logs-gochuchamchi-edge"
$alarmNames = @(
    "gochuchamchi-waf-total-blocked",
    "gochuchamchi-waf-rate-limit-blocked",
    "gochuchamchi-waf-sqli-blocked",
    "gochuchamchi-waf-known-bad-blocked"
)

$fail    = @()
$pending = @()
$UA      = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"

function Write-Section($t) { Write-Host ""; Write-Host "── $t " -ForegroundColor Cyan }

# HTTP 요청 하나를 보내고 상태 코드만 돌려준다. 차단은 예외가 아니라 결과다.
function Invoke-Probe {
    param([string]$Url, [hashtable]$Headers = $null, [int]$TimeoutSec = 15, [switch]$NoUserAgent)

    Add-Type -AssemblyName System.Net.Http
    $h = New-Object System.Net.Http.HttpClient
    $h.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    if (-not $NoUserAgent) { $h.DefaultRequestHeaders.Add("User-Agent", $UA) }
    if ($Headers) { foreach ($k in $Headers.Keys) { $h.DefaultRequestHeaders.Add($k, $Headers[$k]) } }
    try {
        $r = $h.GetAsync($Url).Result
        return [pscustomobject]@{ Code = [int]$r.StatusCode; Error = $null }
    } catch {
        # 타임아웃·연결 거부는 "막혔다"는 정상 결과일 수 있으므로 그대로 돌려준다.
        return [pscustomobject]@{ Code = 0; Error = $_.Exception.GetBaseException().Message }
    } finally {
        $h.Dispose()
    }
}

Write-Host "WAF 검증 — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

# --- 1. Web ACL 과 규칙 ------------------------------------------------------
Write-Section "[1] Web ACL (us-east-1, CLOUDFRONT 스코프)"

$aclRaw = aws wafv2 list-web-acls --scope CLOUDFRONT --region $edgeRegion --output json
if ($LASTEXITCODE -ne 0) {
    $fail += "Web ACL 목록 조회 실패"
} else {
    $acls = ($aclRaw | Out-String | ConvertFrom-Json).WebACLs
    $acl  = $acls | Where-Object { $_.Name -like "*gochuchamchi*" } | Select-Object -First 1
    if (-not $acl) {
        $fail += "gochuchamchi Web ACL 을 찾지 못했다"
        Write-Host "    ✖ Web ACL 없음" -ForegroundColor Red
    } else {
        Write-Host "    ✔ $($acl.Name)"
        $detailRaw = aws wafv2 get-web-acl --name $acl.Name --scope CLOUDFRONT --id $acl.Id --region $edgeRegion --output json
        if ($LASTEXITCODE -eq 0) {
            $rules = ($detailRaw | Out-String | ConvertFrom-Json).WebACL.Rules
            Write-Host "    규칙 $($rules.Count)개:"
            foreach ($r in $rules) { Write-Host "        - $($r.Name)" }
        }
    }
}

# --- 2. 가이드 8번: ALB 직접 우회 --------------------------------------------
Write-Section "[2] ALB 직접 접근 차단 (가이드 8번)"

$albDns = aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[?Scheme=='internet-facing' && starts_with(LoadBalancerName, 'k8s-gochucha')].DNSName" --output text
if ($LASTEXITCODE -ne 0 -or -not $albDns -or $albDns -eq "None") {
    $pending += "앱 ALB 를 찾지 못해 우회 시험 생략"
    Write-Host "    … ALB 없음 — 생략" -ForegroundColor Yellow
} else {
    $albDns = ($albDns -split "\s+")[0]
    Write-Host "    대상: http://$albDns"
    $p = Invoke-Probe -Url "http://$albDns/" -TimeoutSec 12
    if ($p.Code -eq 0) {
        Write-Host "    ✔ 연결되지 않음 — SG(CloudFront prefix list)에서 차단" -ForegroundColor Green
        Write-Host "      ($($p.Error))" -ForegroundColor DarkGray
    } elseif ($p.Code -eq 403) {
        Write-Host "    ✔ HTTP 403 — Origin 검증 헤더가 없어 ALB 리스너가 차단" -ForegroundColor Green
    } elseif ($p.Code -eq 200) {
        $fail += "ALB 직접 접근이 200 으로 성공했다 — CloudFront 우회가 가능한 상태"
        Write-Host "    ✖ HTTP 200 — 우회 가능! 심각" -ForegroundColor Red
    } else {
        Write-Host "    ? HTTP $($p.Code) — 200 이 아니므로 우회는 아니지만 예상 밖" -ForegroundColor Yellow
    }
}

# --- 3. 가이드 9번: SQLi 차단 -------------------------------------------------
Write-Section "[3] SQLi 차단 시험 (가이드 9번)"

# 대조군을 먼저 본다. 정상 요청이 200 이어야 "차단이 SQLi 때문"이라고 말할 수 있다.
$normal = Invoke-Probe -Url "$Site/"
Write-Host "    대조군(정상 요청): HTTP $($normal.Code)"
if ($normal.Code -ne 200) {
    $fail += "정상 요청이 200 이 아니다 (HTTP $($normal.Code)) — 다른 시험의 근거가 무너진다"
}

$sqli = Invoke-Probe -Url "$Site/?id=1%27%20OR%20%271%27%3D%271"
Write-Host "    SQLi 페이로드: HTTP $($sqli.Code)"
if ($sqli.Code -eq 403) {
    Write-Host "    ✔ 차단됨" -ForegroundColor Green
} else {
    $fail += "SQLi 페이로드가 차단되지 않았다 (HTTP $($sqli.Code))"
    Write-Host "    ✖ 차단되지 않음" -ForegroundColor Red
}

# UA 없는 요청 — AWSManagedRulesCommonRuleSet 의 NoUserAgent_HEADER.
# 2026-08-13 에 부하 시험을 하다 이 규칙에 걸려 rate limit 으로 오진한 적이 있다.
$noUa = Invoke-Probe -Url "$Site/" -NoUserAgent
Write-Host "    UA 없는 요청: HTTP $($noUa.Code)"
if ($noUa.Code -eq 403) {
    Write-Host "    ✔ 차단됨 (NoUserAgent_HEADER)" -ForegroundColor Green
} else {
    $pending += "UA 없는 요청이 차단되지 않았다 (HTTP $($noUa.Code)) — 관리형 규칙 구성 확인"
}

# --- 4. 가이드 10번: WAF 로그 -------------------------------------------------
Write-Section "[4] WAF 로그 유입 (가이드 10번, us-east-1)"

Write-Host "    로그 전달까지 시간이 걸린다. $LogWaitSec 초 대기…"
Start-Sleep -Seconds $LogWaitSec

$logRaw = aws logs filter-log-events --log-group-name $wafLogGroup --start-time $startedAt --region $edgeRegion --output json
if ($LASTEXITCODE -ne 0) {
    $fail += "WAF 로그 그룹 조회 실패 — 이름 또는 리전 확인 ($wafLogGroup @ $edgeRegion)"
    Write-Host "    ✖ 조회 실패" -ForegroundColor Red
} else {
    $events = ($logRaw | Out-String | ConvertFrom-Json).events
    $blocked = @($events | Where-Object { $_.message -match '"action"\s*:\s*"BLOCK"' })
    Write-Host "    시험 시작 이후 이벤트 $($events.Count)건 / BLOCK $($blocked.Count)건"
    if ($blocked.Count -gt 0) {
        Write-Host "    ✔ 방금 만든 차단이 로그에 남았다" -ForegroundColor Green
        # 어떤 규칙이 잡았는지까지 보여 준다. 규칙 이름이 안 보이면 관리형 규칙 그룹이다.
        $blocked | Select-Object -First 3 | ForEach-Object {
            if ($_.message -match '"terminatingRuleId"\s*:\s*"([^"]+)"') {
                Write-Host "        규칙: $($Matches[1])"
            }
        }
    } elseif ($events.Count -gt 0) {
        $pending += "WAF 로그는 오는데 BLOCK 이 안 잡혔다 — 샘플링 또는 지연"
        Write-Host "    … 로그는 오지만 BLOCK 없음" -ForegroundColor Yellow
    } else {
        $pending += "WAF 로그가 아직 안 왔다 — 몇 분 뒤 재실행"
        Write-Host "    … 아직 로그 없음 (전달 지연)" -ForegroundColor Yellow
    }
}

# --- 5. 알람 4종 --------------------------------------------------------------
Write-Section "[5] WAF 차단 알람"

# --query 로 필요한 필드만 뽑는다 — alarm_description 에 em-dash 가 있어서
# 통째로 받으면 AWS CLI 가 cp949 인코딩에서 죽는다(PYTHONIOENCODING 무효).
#
# 이 알람들에도 alarm_actions 는 붙어 있지 않다. us-east-1 알람의 상태 변화를
# EventBridge(gochuchamchi-waf-alarm-state-change)가 잡아 서울 알림 허브로
# 넘기는 구조다 — 그러니 "액션 없음"을 실패로 보면 안 된다. 대신 그 중계 룰이
# 살아 있는지를 본다.
$alarmRaw = aws cloudwatch describe-alarms --alarm-names $alarmNames --region $edgeRegion --query "MetricAlarms[].{Name:AlarmName,State:StateValue}" --output json
if ($LASTEXITCODE -ne 0) {
    $fail += "WAF 알람 조회 실패"
} else {
    $found = @(($alarmRaw | Out-String | ConvertFrom-Json))
    foreach ($n in $alarmNames) {
        $a = $found | Where-Object { $_.Name -eq $n }
        if ($a) {
            Write-Host ("    ✔ {0,-38} {1}" -f $a.Name, $a.State)
        } else {
            $fail += "알람 $n 이 없다"
            Write-Host "    ✖ $n 없음" -ForegroundColor Red
        }
    }
}

# us-east-1 → 서울 중계 룰
$relayRaw = aws events list-rules --name-prefix "gochuchamchi-waf-alarm" --region $edgeRegion --output json
if ($LASTEXITCODE -ne 0) {
    $pending += "WAF 알람 중계 룰 조회 실패"
} else {
    $relay = ($relayRaw | Out-String | ConvertFrom-Json).Rules
    if (-not $relay) {
        $fail += "us-east-1 알람을 서울로 넘기는 EventBridge 룰이 없다 — WAF 알람이 통보되지 않는다"
        Write-Host "    ✖ 중계 룰 없음" -ForegroundColor Red
    } else {
        foreach ($r in $relay) {
            Write-Host "    ✔ 중계 룰 $($r.Name)  (State=$($r.State))"
            if ($r.State -ne "ENABLED") { $fail += "중계 룰 $($r.Name) 이 비활성이다" }
        }
    }
}

# --- 6. Log 계정 구독필터 (가이드 11번의 워크로드 쪽) -------------------------
Write-Section "[6] WAF 로그 → Log 계정 구독필터"

$subRaw = aws logs describe-subscription-filters --log-group-name $wafLogGroup --region $edgeRegion --output json
if ($LASTEXITCODE -ne 0) {
    $pending += "WAF 로그 구독필터 조회 실패"
} else {
    $subs = ($subRaw | Out-String | ConvertFrom-Json).subscriptionFilters
    if ($subs -and $subs.Count -gt 0) {
        foreach ($s in $subs) {
            Write-Host "    ✔ $($s.filterName)"
            Write-Host "      → $($s.destinationArn)"
        }
        Write-Host ""
        Write-Host "    Log 계정 S3/Athena 실제 유입 확인은 Log 담당자 몫이다 (가이드 11번)." -ForegroundColor DarkGray
    } else {
        $fail += "WAF 로그 구독필터가 없다 — Log 계정으로 전달되지 않는다"
        Write-Host "    ✖ 구독필터 없음" -ForegroundColor Red
    }
}

# --- 판정 --------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 66)
if ($fail.Count -gt 0) {
    Write-Host "판정: 실패 $($fail.Count)건" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  - $_" }
    if ($pending.Count -gt 0) {
        Write-Host "  (미결 $($pending.Count)건도 있다)" -ForegroundColor Yellow
        $pending | ForEach-Object { Write-Host "  ~ $_" -ForegroundColor Yellow }
    }
    exit 1
}
if ($pending.Count -gt 0) {
    Write-Host "판정: 미결 — 실패는 없으나 확인 못 한 것이 있다" -ForegroundColor Yellow
    $pending | ForEach-Object { Write-Host "  - $_" }
    exit 2
}
Write-Host "판정: 통과 — 우회 차단·SQLi 차단·로그·알람·구독 전부 정상" -ForegroundColor Green
exit 0
