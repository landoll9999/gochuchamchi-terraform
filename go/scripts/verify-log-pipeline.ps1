# =============================================================================
# verify-log-pipeline.ps1 — 로그가 Log 계정으로 실제로 흘러가는가
#
#   증적(로그)은 "설정이 있다"와 "흐르고 있다"가 다르다. 구독 필터가 만들어져
#   있어도 원본 로그 그룹에 아무것도 안 쌓이면 중앙에도 아무것도 안 간다.
#   그리고 그 상태는 조용하다 — 사고가 난 뒤 조회해 보고서야 안다.
#
#   ── 이 스크립트가 잡으려는 실패들 ────────────────────────────────────────
#   ① 구독 필터가 아예 없음. Log 계정 Destination 이 먼저 apply 되지 않으면
#      워크로드 쪽 생성이 실패하는데, 그 실패를 지나치기 쉽다.
#   ② 구독 필터는 있는데 원본 로그 그룹이 조용함 — 애드온이 안 붙었거나
#      감사 이벤트가 꺼진 것.
#   ③ WAF 구독만 us-east-1 에 있다는 것을 잊고 서울에서 찾다가 "없다"고 오진.
#   ④ 목적지 계정 ID 가 Log 계정이 아닌 곳을 가리킴.
#
#   Log 계정 S3/Athena 에 실제로 적재됐는지는 여기서 확인할 수 없다 —
#   log-admin 자격증명이 필요하다. 그건 Log 담당자에게 넘길 몫이고, 이
#   스크립트는 "워크로드 쪽에서 보낼 것은 다 보내고 있다"까지를 증명한다.
#
# 사용: go\scripts\verify-log-pipeline.ps1
# 종료 코드: 0 통과 / 1 실패 / 2 미결
# =============================================================================

param(
    # 로그가 "최근에" 들어왔는지 판단하는 기준(분).
    [int]$FreshMin = 30,
    # 목적지가 이 계정을 가리켜야 한다. 비우면 계정 검사를 건너뛴다.
    [string]$LogAccountId = "564186750363"
)

$ErrorActionPreference = "Continue"
$env:AWS_PROFILE = "workload-admin"
# 한글·em-dash 가 든 리소스를 조회할 때 AWS CLI 가 cp949 로 인코딩하려다
# 죽는 것을 막는다 (2026-08-13 실측).
$env:PYTHONIOENCODING = "utf-8"

$region     = "ap-northeast-2"
$edgeRegion = "us-east-1"

$fail    = @()
$pending = @()

function Write-Section($t) { Write-Host ""; Write-Host "── $t " -ForegroundColor Cyan }

# 로그 그룹 하나를 보고 (구독 필터, 최근 유입)을 함께 판정한다.
function Test-LogGroup {
    param([string]$Name, [string]$Rgn, [string]$Label)

    Write-Host ""
    Write-Host "  $Label"
    Write-Host "    그룹: $Name  ($Rgn)"

    # 그룹 존재 확인
    $lgRaw = aws logs describe-log-groups --log-group-name-prefix $Name --region $Rgn --output json
    if ($LASTEXITCODE -ne 0) {
        $script:fail += "$Label 로그 그룹 조회 실패"
        return
    }
    $lg = ($lgRaw | Out-String | ConvertFrom-Json).logGroups | Where-Object { $_.logGroupName -eq $Name }
    if (-not $lg) {
        $script:fail += "$Label 로그 그룹이 없다: $Name"
        Write-Host "    ✖ 그룹 없음" -ForegroundColor Red
        return
    }

    # 구독 필터
    $subRaw = aws logs describe-subscription-filters --log-group-name $Name --region $Rgn --output json
    if ($LASTEXITCODE -ne 0) {
        $script:fail += "$Label 구독 필터 조회 실패"
    } else {
        $subs = ($subRaw | Out-String | ConvertFrom-Json).subscriptionFilters
        if (-not $subs -or $subs.Count -eq 0) {
            $script:fail += "$Label 에 구독 필터가 없다 — Log 계정으로 안 간다"
            Write-Host "    ✖ 구독 필터 없음" -ForegroundColor Red
        } else {
            foreach ($s in $subs) {
                Write-Host "    ✔ 구독 $($s.filterName)"
                Write-Host "      → $($s.destinationArn)"
                if ($LogAccountId -and $s.destinationArn -notmatch $LogAccountId) {
                    $script:fail += "$Label 구독 목적지가 Log 계정($LogAccountId)이 아니다: $($s.destinationArn)"
                }
            }
        }
    }

    # 스트림 존재 — "한 번도 안 쌓임"(실패)과 "쌓이다 멎음"(미결)을 가른다.
    # --query 로 개수만 받아 스트림 이름이 콘솔에 닿을 일 자체를 없앤다.
    # (not_null 가드가 붙은 이유는 아래 filter-log-events 주석 참고)
    $stCntRaw = aws logs describe-log-streams --log-group-name $Name --max-items 1 --region $Rgn --query 'length(not_null(logStreams,`[]`))' --output text
    if ($LASTEXITCODE -ne 0) {
        $script:pending += "$Label 스트림 조회 실패 — 유입 확인 못 함"
        return
    }
    if ("$stCntRaw".Trim() -eq "0") {
        $script:fail += "$Label 에 로그 스트림이 하나도 없다 — 아무것도 안 쌓이고 있다"
        Write-Host "    ✖ 스트림 없음" -ForegroundColor Red
        return
    }

    # 최근 유입 — 최근 $FreshMin 분 창의 이벤트 개수를 직접 센다.
    #   전에는 describe-log-streams 의 lastEventTimestamp 로 봤는데, 그 필드는
    #   eventually-consistent 라 최대 1시간 낡는다 — 실제로는 25분간 120건이
    #   적재 중인데 57분 전을 가리켜 거짓 미결이 났다(2026-08-18 실측).
    #   filter-log-events 는 창을 좁히고 --max-items 로 상한을 걸면 느리지도
    #   크지도 않다. --query 는 성능만이 아니라 회피용으로도 필수다 — 이벤트
    #   본문(비ASCII)이 콘솔에 닿으면 cp949 로 깨진다(상단 PYTHONIOENCODING 주석).
    $startMs = [DateTimeOffset]::UtcNow.AddMinutes(-$FreshMin).ToUnixTimeMilliseconds()
    $evtCntRaw = aws logs filter-log-events --log-group-name $Name --start-time $startMs --max-items 1000 --region $Rgn --query 'length(not_null(events,`[]`))' --output text
    if ($LASTEXITCODE -ne 0) {
        $script:pending += "$Label 이벤트 조회 실패 — 유입 확인 못 함"
        return
    }
    # 자동 페이지네이션이 돌면 length() 가 페이지당 한 줄씩 여러 개 찍히고
    # (2026-08-18 실측: "100" "0" 두 줄), --max-items 에 잘리면 결과 키가 아예
    # 없는 페이지가 하나 더 나와 length(null) 오류로 죽는다 — 그래서 쿼리에
    # not_null(...,`[]`) 가드를 걸었다. 줄들은 전부 합산해야 창 전체 개수다.
    $evtCnt = 0
    foreach ($ln in @($evtCntRaw)) {
        $t = "$ln".Trim()
        if ($t -eq "") { continue }
        if ($t -notmatch '^\d+$') {
            $script:pending += "$Label 이벤트 개수를 못 읽음: $t"
            return
        }
        $evtCnt += [int]$t
    }
    if ($evtCnt -gt 0) {
        # ${} 필수 — "$evtCnt건" 이라 쓰면 한글 '건'까지 변수명으로 붙어 빈 값이 된다.
        $shown = if ($evtCnt -ge 1000) { "1000건 이상" } else { "${evtCnt}건" }
        Write-Host ("    ✔ 최근 {0}분 유입 {1}" -f $FreshMin, $shown) -ForegroundColor Green
    } else {
        $script:pending += "$Label 최근 $FreshMin 분 이벤트 0건 — 유입이 멎었을 수 있다"
        Write-Host ("    … 최근 {0}분 이벤트 없음" -f $FreshMin) -ForegroundColor Yellow
    }
}

Write-Host "로그 파이프라인 검증 — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- 대상 로그 그룹 결정 ------------------------------------------------------
# RDS 감사 로그 그룹 이름에는 인스턴스 식별자가 들어가므로 실물에서 가져온다.
$dbId = aws rds describe-db-instances --region $region --query "DBInstances[0].DBInstanceIdentifier" --output text
if ($LASTEXITCODE -ne 0 -or -not $dbId -or $dbId -eq "None") {
    $pending += "RDS 인스턴스를 찾지 못해 감사 로그 검사를 생략"
    $dbId = $null
}

$clusterName = aws eks list-clusters --region $region --query "clusters[0]" --output text
if ($LASTEXITCODE -ne 0 -or -not $clusterName -or $clusterName -eq "None") {
    $pending += "EKS 클러스터를 찾지 못해 control-plane 검사를 생략"
    $clusterName = $null
}

Write-Section "[1] 서울 리전 로그 그룹"

if ($clusterName) {
    Test-LogGroup -Name "/aws/eks/$clusterName/cluster" -Rgn $region -Label "EKS control-plane"
    Test-LogGroup -Name "/aws/containerinsights/$clusterName/application" -Rgn $region -Label "앱 컨테이너 로그"
}
if ($dbId) {
    Test-LogGroup -Name "/aws/rds/instance/$dbId/audit" -Rgn $region -Label "RDS 감사 로그"
}

Write-Section "[2] us-east-1 (CloudFront WAF)"
Test-LogGroup -Name "aws-waf-logs-gochuchamchi-edge" -Rgn $edgeRegion -Label "WAF 로그"

# --- 3. ALB 액세스 로그 --------------------------------------------------------
Write-Section "[3] ALB 액세스 로그"

# ALB 로그는 CloudWatch 를 거치지 않고 S3 로 바로 간다. 그리고 그 버킷은
# 워크로드 계정이 아니라 Log 계정에 있다(gochuchamchi-alb-access-logs-<log계정>).
#   그래서 여기서 S3 를 뒤져 봐야 영원히 못 찾는다 — 남의 계정 버킷이다.
#   워크로드 쪽에서 확인할 수 있는 것은 "ALB 가 그리로 쓰도록 설정돼 있는가"
#   까지이고, 실제 객체 적재 확인은 Log 담당자 몫이다.
$albArn = aws elbv2 describe-load-balancers --region $region --query "LoadBalancers[?Scheme=='internet-facing' && starts_with(LoadBalancerName, 'k8s-gochucha')].LoadBalancerArn" --output text
if ($LASTEXITCODE -ne 0 -or -not $albArn -or $albArn -eq "None") {
    $pending += "앱 ALB 를 찾지 못해 액세스 로그 설정을 확인 못 함"
    Write-Host "    … ALB 없음" -ForegroundColor Yellow
} else {
    $albArn = ($albArn -split "\s+")[0]
    $attrRaw = aws elbv2 describe-load-balancer-attributes --load-balancer-arn $albArn --region $region --query "Attributes[?starts_with(Key,'access_logs')]" --output json
    if ($LASTEXITCODE -ne 0) {
        $pending += "ALB 속성 조회 실패"
    } else {
        $attrs = @(($attrRaw | Out-String | ConvertFrom-Json))
        $enabled = ($attrs | Where-Object { $_.Key -eq "access_logs.s3.enabled" }).Value
        $bucket  = ($attrs | Where-Object { $_.Key -eq "access_logs.s3.bucket" }).Value
        $prefix  = ($attrs | Where-Object { $_.Key -eq "access_logs.s3.prefix" }).Value
        Write-Host "    enabled=$enabled  bucket=$bucket  prefix=$prefix"
        if ($enabled -ne "true") {
            $fail += "ALB 액세스 로그가 꺼져 있다 — 엣지 요청 증적이 안 남는다"
            Write-Host "    ✖ 꺼짐" -ForegroundColor Red
        } elseif ($LogAccountId -and $bucket -notmatch $LogAccountId) {
            $fail += "ALB 로그 버킷이 Log 계정($LogAccountId)이 아니다: $bucket"
        } else {
            Write-Host "    ✔ Log 계정 버킷으로 전송 설정됨" -ForegroundColor Green
        }
    }
}

# --- 판정 --------------------------------------------------------------------
Write-Host ""
Write-Host ("=" * 66)
Write-Host "Log 계정 S3/Athena 실제 적재는 log-admin 자격증명이 필요해 여기서 못 본다." -ForegroundColor DarkGray
Write-Host "이 스크립트는 '워크로드에서 내보내는 것은 다 내보내고 있다'까지를 본다." -ForegroundColor DarkGray

if ($fail.Count -gt 0) {
    Write-Host ""
    Write-Host "판정: 실패 $($fail.Count)건" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  - $_" }
    # 실패가 있어도 미결을 같이 보여 준다 — 하나 고치고 나면 다음에 볼 것이 뭔지
    # 알아야 하는데, 숨기면 매번 다시 돌려서야 알게 된다.
    if ($pending.Count -gt 0) {
        Write-Host "  (미결 $($pending.Count)건도 있다)" -ForegroundColor Yellow
        $pending | ForEach-Object { Write-Host "  ~ $_" -ForegroundColor Yellow }
    }
    exit 1
}
if ($pending.Count -gt 0) {
    Write-Host ""
    Write-Host "판정: 미결" -ForegroundColor Yellow
    $pending | ForEach-Object { Write-Host "  - $_" }
    exit 2
}
Write-Host ""
Write-Host "판정: 통과 — 구독 필터·목적지 계정·로그 유입 전부 정상" -ForegroundColor Green
exit 0
