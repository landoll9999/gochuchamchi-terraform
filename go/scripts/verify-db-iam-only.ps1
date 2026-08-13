# =============================================================================
# verify-db-iam-only.ps1 — DB 자격증명이 IAM 토큰 하나로 일원화됐는지 검증
#
#   2026-08-13 에 비밀번호 계정(gochuchamchi_app)과 그 Secret 을 제거했다.
#   이 스크립트는 "제거가 실제로 반영됐는가"와 "토큰 인증이 재발급 구간을
#   넘겨서도 동작하는가"를 함께 본다.
#
#   ── 이 스크립트가 존재하는 이유 (읽고 시작할 것) ──────────────────────────
#   앞선 검증 스크립트는 감사 로그의 QUERY 건수를 세어 통과 판정을 냈다.
#   그런데 MariaDB 는 접속 시점에만 인증하고 세션 중에는 재인증하지 않는다.
#   즉 이미 열린 커넥션 위의 QUERY 는 몇 백 건이든 "첫 토큰"의 결과이고,
#   토큰이 만료된 뒤에도 그 커넥션은 멀쩡히 계속 돈다.
#   그래서 재발급이 한 번도 일어나지 않은 상태에서도 통과가 나왔다.
#
#   재발급의 증거는 CONNECT 뿐이다 — 정확히는 "플러그인 토큰 캐시(10분)가
#   만료된 뒤에 새로 생긴 물리 CONNECT". 이 스크립트는 그것만 본다.
#
#   ── 판정이 3가지인 이유 ──────────────────────────────────────────────────
#   재발급은 시간이 지나야 관찰된다(HikariCP maxLifetime 기본 30분). 아직
#   관찰 구간에 못 들어간 것을 "실패"로 부르면 아침마다 헛경보가 난다.
#   그래서 통과 / 미결 / 실패를 나눈다. 미결은 몇 분 뒤 다시 돌리면 된다.
#
# 사용:
#   go\scripts\verify-db-iam-only.ps1
#   go\scripts\verify-db-iam-only.ps1 -Deep      # 배스천으로 mysql.user 직접 확인
#
# 종료 코드: 0 통과 / 1 실패 / 2 미결(재실행 필요)
# =============================================================================

param(
    # 배스천에 SSM 으로 들어가 mysql.user 를 직접 조회한다. 가장 확실하지만
    # 마스터 비밀번호를 읽고 SSM 왕복을 하므로 1~2분 걸린다.
    [switch]$Deep,
    # 감사 로그를 거슬러 볼 범위(분). 파드 기동 시각을 덮을 만큼은 필요하다.
    [int]$AuditWindowMin = 120
)

# native 명령이 stderr 한 줄만 뱉어도 죽는 것을 막는다. 성패는 $LASTEXITCODE 로
# 판정한다 — stderr 를 리다이렉트하면(2>$null 포함) PS 5.1 이 ErrorRecord 로
# 감싸므로 리다이렉트 자체를 쓰지 않는다 (2026-08-13 실측, pitfalls 참조).
$ErrorActionPreference = "Continue"
$env:AWS_PROFILE = "workload-admin"
$env:PYTHONIOENCODING = "utf-8"

$region       = "ap-northeast-2"
$ns           = "gochuchamchi"
$appLabel     = "app=gochuchamchi-web"
$auditGroup   = "/aws/rds/instance/gochuchamchi-db/audit"
$legacyUser   = "gochuchamchi_app"       # 제거된 비밀번호 계정
$iamUser      = "gochuchamchi_app_iam"   # IAM 토큰 전용 계정
$legacySecret = "gochuchamchi-db-app"    # 제거된 K8s Secret
$legacySmName = "gochuchamchi/app/db-credentials"
$tokenCacheMin = 10                      # Connector/J AWS-IAM 플러그인 TOKEN_TTL

$fail    = @()
$pending = @()

function Write-Section($text) {
    Write-Host ""
    Write-Host "── $text " -ForegroundColor Cyan
}

Write-Host "DB IAM 전용 검증 — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- 1. 비밀번호 잔재가 사라졌는가 -------------------------------------------
Write-Section "[1] 비밀번호 잔재"

$k8sSecrets = kubectl get secret -n $ns -o jsonpath="{.items[*].metadata.name}"
if ($LASTEXITCODE -ne 0) {
    $fail += "kubectl 로 Secret 목록을 못 읽었다 (클러스터 접속 확인)"
} elseif ($k8sSecrets -match [regex]::Escape($legacySecret)) {
    $fail += "K8s Secret '$legacySecret' 이 아직 있다 — terraform 머지가 반영되지 않았다"
    Write-Host "    ✖ K8s Secret $legacySecret 존재" -ForegroundColor Red
} else {
    Write-Host "    ✔ K8s Secret $legacySecret 없음"
}

$smNames = aws secretsmanager list-secrets --region $region --query "SecretList[].Name" --output text
if ($LASTEXITCODE -ne 0) {
    $fail += "Secrets Manager 목록 조회 실패"
} elseif ($smNames -match [regex]::Escape($legacySmName)) {
    $fail += "Secrets Manager '$legacySmName' 이 아직 있다"
    Write-Host "    ✖ Secrets Manager $legacySmName 존재" -ForegroundColor Red
} else {
    Write-Host "    ✔ Secrets Manager $legacySmName 없음"
}

# --- 2. 파드에 DB_PASS 가 없는가 ---------------------------------------------
Write-Section "[2] 파드 상태와 환경변수"

$podsRaw = kubectl get pods -n $ns -l $appLabel -o json
if ($LASTEXITCODE -ne 0) {
    $fail += "파드 조회 실패"
    $pods = $null
} else {
    $pods = ($podsRaw | Out-String | ConvertFrom-Json).items
}

$podStarts = @()
if ($pods) {
    foreach ($p in $pods) {
        $cs  = $p.status.containerStatuses[0]
        $st  = [datetime]::Parse($p.status.startTime).ToUniversalTime()
        $podStarts += $st
        $age = [math]::Round(((Get-Date).ToUniversalTime() - $st).TotalMinutes)
        Write-Host ("    {0}  ready={1}  restarts={2}  age={3}분" -f $p.metadata.name, $cs.ready, $cs.restartCount, $age)
        if (-not $cs.ready)         { $fail += "파드 $($p.metadata.name) not ready" }
        if ($cs.restartCount -gt 0) { $fail += "파드 $($p.metadata.name) 재시작 $($cs.restartCount)회" }
    }

    # envFrom 에 옛 Secret 참조가 남아 있으면 gitops 가 안 바뀐 것이다.
    $envFrom = kubectl get deploy gochuchamchi-web -n $ns -o jsonpath="{.spec.template.spec.containers[0].envFrom}"
    if ($envFrom -match [regex]::Escape($legacySecret)) {
        $fail += "Deployment 가 아직 '$legacySecret' 을 envFrom 으로 참조한다 (gitops 미반영)"
        Write-Host "    ✖ envFrom 에 $legacySecret 참조 남음" -ForegroundColor Red
    } else {
        Write-Host "    ✔ envFrom 에 $legacySecret 참조 없음"
    }

    # 실제 컨테이너 안에 DB_PASS 가 있는지. 값은 절대 출력하지 않는다.
    $podName = $pods[0].metadata.name
    $hasPass = kubectl exec -n $ns $podName -- sh -c "env | grep -c '^DB_PASS=' || true"
    if ($LASTEXITCODE -eq 0 -and $hasPass) {
        if ($hasPass.Trim() -eq "0") {
            Write-Host "    ✔ 컨테이너 환경변수에 DB_PASS 없음"
        } else {
            $fail += "파드 환경변수에 DB_PASS 가 남아 있다"
            Write-Host "    ✖ DB_PASS 존재" -ForegroundColor Red
        }
    } else {
        Write-Host "    (컨테이너 env 확인 생략 — exec 실패)" -ForegroundColor DarkGray
    }
}

# --- 3. 감사 로그 수집 --------------------------------------------------------
Write-Section "[3] RDS 감사 로그 (최근 $AuditWindowMin 분)"

$since   = [DateTimeOffset]::UtcNow.AddMinutes(-$AuditWindowMin).ToUnixTimeMilliseconds()
$rows    = @()
$auditOk = $false

$auditRaw = aws logs filter-log-events --log-group-name $auditGroup --start-time $since --filter-pattern gochuchamchi_app --region $region --output json
if ($LASTEXITCODE -ne 0) {
    $fail += "감사 로그 조회 실패 — 로그 그룹이 아직 없거나 권한 문제"
} else {
    $events = ($auditRaw | Out-String | ConvertFrom-Json).events
    $auditOk = $true
    foreach ($e in $events) {
        # RDS MariaDB 감사 로그 CSV:
        #   timestamp,serverhost,username,host,connectionid,queryid,operation,...
        $f = $e.message -split ','
        if ($f.Count -ge 7) {
            $rows += [pscustomobject]@{
                T    = [DateTimeOffset]::FromUnixTimeMilliseconds($e.timestamp).UtcDateTime
                User = $f[2]
                Host = $f[3]
                Conn = $f[4]
                Op   = $f[6]
            }
        }
    }
    Write-Host "    이벤트 $($rows.Count)건 파싱"
}

if ($auditOk) {
    # 3-1. 옛 계정이 접속한 흔적이 있으면 프로비저닝이 아직 돈다는 뜻이다.
    $legacyConn = @($rows | Where-Object { $_.User -eq $legacyUser -and $_.Op -eq 'CONNECT' })
    if ($legacyConn.Count -gt 0) {
        $fail += "옛 계정 '$legacyUser' 접속 $($legacyConn.Count)건 — 프로비저닝이 아직 돈다"
        Write-Host "    ✖ $legacyUser CONNECT $($legacyConn.Count)건" -ForegroundColor Red
    } else {
        Write-Host "    ✔ $legacyUser CONNECT 0건"
    }

    # 3-2. 토큰 계정이 실제로 붙고 있는가.
    $iamConn = @($rows | Where-Object { $_.User -eq $iamUser -and $_.Op -eq 'CONNECT' } | Sort-Object T)
    $iamFail = @($rows | Where-Object { $_.User -eq $iamUser -and $_.Op -like 'FAILED*' })
    Write-Host "    $iamUser CONNECT $($iamConn.Count)건 / 실패 $($iamFail.Count)건"
    if ($iamConn.Count -eq 0) { $fail += "$iamUser 접속이 0건 — 앱이 DB 에 붙지 못했다" }
    if ($iamFail.Count -gt 0) { $fail += "$iamUser 접속 실패 $($iamFail.Count)건" }
}

# --- 4. 토큰 재발급 구간 ------------------------------------------------------
# 여기가 이 스크립트의 핵심이다. QUERY 는 세지 않는다 — 첫 토큰으로 열린
# 커넥션 위에서 계속 도는 것이라 재발급을 증명하지 못한다.
Write-Section "[4] 토큰 재발급 (캐시 만료 이후의 새 CONNECT)"

if ($auditOk -and $podStarts.Count -gt 0) {
    # 가장 늦게 뜬 파드 기준 + 캐시 TTL. 보수적으로 잡아야 오탐이 없다.
    $threshold = ($podStarts | Sort-Object)[-1].AddMinutes($tokenCacheMin)
    $after = @($iamConn | Where-Object { $_.T -gt $threshold })

    Write-Host ("    기준 시각: {0} (마지막 파드 기동 + {1}분)" -f $threshold.ToLocalTime().ToString('HH:mm:ss'), $tokenCacheMin)

    if ($after.Count -gt 0) {
        Write-Host "    ✔ 기준 이후 CONNECT $($after.Count)건 — 재발급된 토큰으로 접속됐다" -ForegroundColor Green
        $after | Select-Object -First 5 | ForEach-Object {
            Write-Host ("        {0}  host={1}  conn={2}" -f $_.T.ToLocalTime().ToString('HH:mm:ss'), $_.Host, $_.Conn)
        }
    } else {
        # 실패가 아니다. 아직 새 커넥션이 필요할 일이 없었을 뿐이다.
        # HikariCP maxLifetime 기본 30분이 지나면 커넥션이 교체되며 반드시 생긴다.
        $wait = [math]::Ceiling((($podStarts | Sort-Object)[-1].AddMinutes(35) - (Get-Date).ToUniversalTime()).TotalMinutes)
        if ($wait -lt 1) { $wait = 1 }
        $pending += "재발급 미관찰 — 약 $wait 분 뒤 다시 실행할 것"
        Write-Host "    … 기준 이후 CONNECT 0건 — 아직 판정 불가" -ForegroundColor Yellow
        Write-Host "      커넥션 풀이 기존 커넥션으로 버티는 중이다. maxLifetime(30분)이"
        Write-Host "      지나면 교체되면서 새 토큰이 발급된다. 약 $wait 분 뒤 재실행."
    }
} else {
    $pending += "재발급 판정 생략 — 감사 로그 또는 파드 정보 없음"
    Write-Host "    … 판정 생략" -ForegroundColor Yellow
}

# --- 5. 사이트 ----------------------------------------------------------------
Write-Section "[5] 사이트 응답"
try {
    $r = Invoke-WebRequest -Uri "https://kycj.click" -Method Head -TimeoutSec 20 -UseBasicParsing
    Write-Host "    HTTP $($r.StatusCode)"
    if ($r.StatusCode -ne 200) { $fail += "사이트 HTTP $($r.StatusCode)" }
} catch {
    $fail += "사이트 응답 실패: $($_.Exception.Message)"
    Write-Host "    ✖ $($_.Exception.Message)" -ForegroundColor Red
}

# --- 6. (선택) 배스천으로 DB 계정 직접 확인 ----------------------------------
if ($Deep) {
    Write-Section "[6] mysql.user 직접 확인 (배스천 SSM)"

    $bastion = aws ec2 describe-instances --region $region --filters "Name=tag:Name,Values=*bastion*" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text
    $dbHost  = aws rds describe-db-instances --region $region --query "DBInstances[0].Endpoint.Address" --output text
    $secret  = aws rds describe-db-instances --region $region --query "DBInstances[0].MasterUserSecret.SecretArn" --output text

    if ($LASTEXITCODE -ne 0 -or -not $bastion -or $bastion -eq "None") {
        Write-Host "    배스천을 찾지 못해 생략" -ForegroundColor DarkGray
    } else {
        # 비밀번호는 배스천 런타임에서만 조회하고 env 로만 넘긴다 (argv 는 ps 노출).
        $cmds = @(
            'set -e',
            'which mysql || sudo dnf install -y mariadb105 > /dev/null',
            "SECRET_JSON=`$(aws secretsmanager get-secret-value --secret-id '$secret' --region $region --query SecretString --output text)",
            'DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)[''password''])")',
            "MYSQL_PWD=`"`$DB_PASS`" mysql --ssl -h $dbHost -u admin -N -e `"SELECT user, plugin FROM mysql.user WHERE user LIKE 'gochuchamchi%';`""
        )
        # 한글이 없으므로 ASCII 로 써도 안전하다. AWS CLI 가 file:// 를 로캘로 읽는
        # 문제를 피하려면 어차피 순수 ASCII 여야 한다.
        $paramsPath = Join-Path $env:TEMP "verify-db-iam-params.json"
        $json = @{ commands = $cmds } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($paramsPath, $json, (New-Object System.Text.ASCIIEncoding))

        $cmdId = aws ssm send-command --instance-ids $bastion --document-name "AWS-RunShellScript" --parameters "file://$paramsPath" --region $region --query "Command.CommandId" --output text
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    SSM 전송 실패 — 생략" -ForegroundColor DarkGray
        } else {
            $status = "Pending"; $tries = 0
            while ($tries -lt 20 -and ($status -eq "Pending" -or $status -eq "InProgress")) {
                Start-Sleep -Seconds 5
                $status = aws ssm get-command-invocation --command-id $cmdId --instance-id $bastion --region $region --query "Status" --output text
                $tries++
            }
            $out = aws ssm get-command-invocation --command-id $cmdId --instance-id $bastion --region $region --query "StandardOutputContent" --output text
            Write-Host "    조회 결과 (user / plugin):"
            ($out -split "`n") | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "        $($_.Trim())" }

            if ($out -match "$legacyUser\s") {
                $fail += "DB 에 옛 계정 '$legacyUser' 이 아직 존재한다"
            }
            if ($out -notmatch "$iamUser\s") {
                $fail += "DB 에 '$iamUser' 계정이 없다"
            }
        }
        Remove-Item $paramsPath -ErrorAction SilentlyContinue
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
    Write-Host ""
    Write-Host "되돌리려면 terraform 의 dbae59c 를 revert 해야 한다."
    Write-Host "ConfigMap 을 되돌리는 옛 방법은 이제 통하지 않는다 — 비밀번호 계정"
    Write-Host "자체가 만들어지지 않기 때문이다."
    exit 1
}

if ($pending.Count -gt 0) {
    Write-Host "판정: 미결 — 실패는 없으나 재발급을 아직 관찰하지 못했다" -ForegroundColor Yellow
    $pending | ForEach-Object { Write-Host "  - $_" }
    Write-Host ""
    Write-Host "제거는 확인됐다. 재발급만 시간이 지나면 관찰된다."
    exit 2
}

Write-Host "판정: 통과 — 비밀번호 잔재 없음, 토큰 재발급 구간까지 정상" -ForegroundColor Green
exit 0
