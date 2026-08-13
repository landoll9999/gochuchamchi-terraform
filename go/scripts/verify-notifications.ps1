# =============================================================================
# verify-notifications.ps1 — 알림 경로가 실제로 살아 있는가
#
#   알람과 탐지는 "발동 조건"만 검증하기 쉽고, 정작 사람에게 도달하는 마지막
#   구간은 확인되지 않은 채로 남는다. 이 스크립트는 그 마지막 구간을 본다.
#
#   ── 이 스크립트가 잡으려는 실패들 ────────────────────────────────────────
#   ① SNS 구독이 PendingConfirmation 인 채로 방치 — 알람은 정상 발동하는데
#      메일이 아무에게도 안 간다. 콘솔에서는 구독이 "있다"고만 보인다.
#   ② 알람에 액션이 안 붙어 있거나 ActionsEnabled=false — 상태는 ALARM 으로
#      바뀌는데 통보가 안 나간다.
#   ③ GuardDuty 통보 배선이 의도와 다른 곳을 가리킴. 2026-08-13 기준 의도는
#      "EventBridge → SNS 직결"이고 트리아지 Lambda 는 꺼져 있는 상태다.
#      apply 하다가 enable_triage 가 켜지면 여기서 드러난다.
#   ④ Discord webhook 시크릿이 그릇만 있고 값이 안 들어간 상태(값은 절대
#      출력하지 않는다 — 존재 여부만 본다).
#
# 사용: go\scripts\verify-notifications.ps1
# 종료 코드: 0 통과 / 1 실패 / 2 미결
# =============================================================================

param(
    # 트리아지를 의도적으로 켠 상태라면 이 스위치를 준다. 그러면 GuardDuty
    # 타겟이 Lambda 여야 통과다(기본은 SNS 직결이 통과).
    [switch]$ExpectTriageEnabled
)

$ErrorActionPreference = "Continue"
$env:AWS_PROFILE = "workload-admin"
# AWS CLI 는 Windows 에서 출력을 로캘(cp949)로 인코딩하려 든다. 이 프로젝트의
# 알람 설명·태그에는 한글과 em-dash(—)가 들어 있어서, 이걸 안 걸면
# "'cp949' codec can't encode character '—'" 로 조회가 통째로 실패한다.
# 실패가 조회 대상의 문제로 보여서(알람 0개) 오진하기 딱 좋다.
$env:PYTHONIOENCODING = "utf-8"

$region     = "ap-northeast-2"
$edgeRegion = "us-east-1"
$topicName  = "gochuchamchi-alerts"
$discordSecrets = @(
    "gochuchamchi/discord/cloudwatch-webhook"
)

$fail    = @()
$pending = @()

function Write-Section($t) { Write-Host ""; Write-Host "── $t " -ForegroundColor Cyan }

Write-Host "알림 경로 검증 — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

# --- 1. SNS 토픽과 구독 -------------------------------------------------------
Write-Section "[1] SNS 구독 상태"

$topicsRaw = aws sns list-topics --region $region --output json
if ($LASTEXITCODE -ne 0) {
    $fail += "SNS 토픽 목록 조회 실패"
    $topicArn = $null
} else {
    $topics = ($topicsRaw | Out-String | ConvertFrom-Json).Topics
    $t = $topics | Where-Object { $_.TopicArn -like "*:$topicName" } | Select-Object -First 1
    $topicArn = $null
    if ($t) { $topicArn = $t.TopicArn }
}

if (-not $topicArn) {
    $fail += "SNS 토픽 '$topicName' 을 찾지 못했다"
    Write-Host "    ✖ 토픽 없음" -ForegroundColor Red
} else {
    Write-Host "    토픽: $topicArn"
    $subRaw = aws sns list-subscriptions-by-topic --topic-arn $topicArn --region $region --output json
    if ($LASTEXITCODE -ne 0) {
        $fail += "SNS 구독 조회 실패"
    } else {
        $subs = ($subRaw | Out-String | ConvertFrom-Json).Subscriptions
        if (-not $subs -or $subs.Count -eq 0) {
            $fail += "SNS 구독이 하나도 없다 — 알람이 아무에게도 안 간다"
            Write-Host "    ✖ 구독 0건" -ForegroundColor Red
        }
        foreach ($s in $subs) {
            $pendingSub = ($s.SubscriptionArn -eq "PendingConfirmation")
            $mark = "✔"
            if ($pendingSub) { $mark = "✖" }
            Write-Host ("    {0} {1,-10} {2}" -f $mark, $s.Protocol, $s.Endpoint)
            if ($pendingSub) {
                $fail += "구독 미확인(PendingConfirmation): $($s.Protocol) $($s.Endpoint) — 확인 메일의 링크를 눌러야 한다"
            }
        }
    }
}

# --- 2. 알람이 실제로 사람에게 도달하는가 ------------------------------------
# 이 프로젝트는 알람에 alarm_actions 를 붙이지 않는다. 대신 EventBridge 가
# "CloudWatch Alarm State Change" 이벤트를 알람 이름 접두사 gochuchamchi- 로
# 잡아 SNS 로 넘긴다 (cloudwatch-notifications/eventbridge.tf, sns.tf:146 주석).
#
#   그래서 AlarmActions 가 비어 있는 것은 정상이다 — 그걸 실패로 보면 매일
#   아침 헛경보가 난다. 이 설계에서 진짜 위험한 것은 따로 있다:
#   접두사를 안 지킨 알람은 룰에 안 걸려서 조용히 통보에서 빠진다.
#   알람은 멀쩡히 ALARM 으로 바뀌는데 아무도 모른다.
Write-Section "[2] 알람 → EventBridge 접두사 룰 → SNS"

foreach ($rg in @($region, $edgeRegion)) {
    # --query 로 필요한 필드만 뽑는다. AlarmDescription 에 em-dash 가 들어 있어서
    # 통째로 받으면 AWS CLI 가 cp949 로 인코딩하려다 죽는다(2026-08-13 실측).
    # PYTHONIOENCODING 으로는 안 잡힌다 — CLI v2 는 frozen 바이너리다.
    $alarmRaw = aws cloudwatch describe-alarms --region $rg --query "MetricAlarms[].{Name:AlarmName,State:StateValue}" --output json
    if ($LASTEXITCODE -ne 0) {
        $pending += "$rg 알람 조회 실패"
        continue
    }
    $alarms = @(($alarmRaw | Out-String | ConvertFrom-Json))
    $inAlarm  = @($alarms | Where-Object { $_.State -eq "ALARM" })
    # 이 계정의 알람은 전부 이 프로젝트 것이다. 접두사가 없으면 통보 경로 밖이다.
    $offPrefix = @($alarms | Where-Object { $_.Name -notlike "gochuchamchi-*" })

    Write-Host ("    [{0}] 알람 {1}개 / 접두사 불일치 {2} / 현재 ALARM {3}" -f `
        $rg, $alarms.Count, $offPrefix.Count, $inAlarm.Count)

    if ($offPrefix.Count -gt 0) {
        $fail += "$rg 에 'gochuchamchi-' 접두사가 없는 알람 $($offPrefix.Count)개 — EventBridge 룰에 안 걸려 통보되지 않는다"
        $offPrefix | Select-Object -First 5 | ForEach-Object { Write-Host "        ✖ $($_.Name)" -ForegroundColor Red }
    }
    # ALARM 상태 자체는 검증 실패가 아니다 — 지금 문제가 있다는 뜻이니 알려만 준다.
    if ($inAlarm.Count -gt 0) {
        $inAlarm | Select-Object -First 5 | ForEach-Object { Write-Host "        ⚠ ALARM 상태: $($_.Name)" -ForegroundColor Yellow }
    }
}

# 접두사 룰 자체가 살아 있는지. 이게 죽으면 알람 전체가 한꺼번에 조용해진다.
$almRuleRaw = aws events list-rules --region $region --output json
if ($LASTEXITCODE -ne 0) {
    $pending += "알람 상태변화 룰 조회 실패"
} else {
    $almRules = ($almRuleRaw | Out-String | ConvertFrom-Json).Rules |
        Where-Object { $_.Name -like "*alarm*" -or $_.Name -like "*cloudwatch*" }
    if (-not $almRules) {
        $fail += "CloudWatch 알람 상태변화를 SNS 로 넘기는 EventBridge 룰을 찾지 못했다"
        Write-Host "    ✖ 알람 상태변화 룰 없음" -ForegroundColor Red
    } else {
        foreach ($r in $almRules) {
            Write-Host "    ✔ 룰 $($r.Name)  (State=$($r.State))"
            if ($r.State -ne "ENABLED") { $fail += "알람 상태변화 룰 $($r.Name) 이 비활성이다" }
        }
    }
}

# --- 3. GuardDuty 통보 배선 ---------------------------------------------------
Write-Section "[3] GuardDuty 통보 배선"

$rulesRaw = aws events list-rules --region $region --output json
if ($LASTEXITCODE -ne 0) {
    $fail += "EventBridge 규칙 조회 실패"
} else {
    $rules = ($rulesRaw | Out-String | ConvertFrom-Json).Rules | Where-Object { $_.Name -like "*guardduty*" }
    if (-not $rules) {
        $fail += "GuardDuty EventBridge 규칙이 없다"
    }
    foreach ($r in $rules) {
        $tRaw = aws events list-targets-by-rule --rule $r.Name --region $region --output json
        if ($LASTEXITCODE -ne 0) { continue }
        $targets = ($tRaw | Out-String | ConvertFrom-Json).Targets
        Write-Host "    규칙 $($r.Name)  (State=$($r.State))"
        foreach ($tg in $targets) { Write-Host "        → $($tg.Arn)" }

        # finding 규칙(격리용 critical 규칙 말고)의 타겟이 의도와 맞는지 본다.
        if ($r.Name -notlike "*critical*") {
            $toLambda = @($targets | Where-Object { $_.Arn -like "*:function:*triage*" }).Count -gt 0
            $toSns    = @($targets | Where-Object { $_.Arn -like "arn:aws:sns:*" }).Count -gt 0
            if ($ExpectTriageEnabled) {
                if (-not $toLambda) { $fail += "트리아지가 켜져 있어야 하는데 $($r.Name) 타겟이 Lambda 가 아니다" }
            } else {
                if ($toLambda) { $fail += "트리아지가 꺼져 있어야 하는데 $($r.Name) 이 Lambda 로 간다 — enable_triage 가 켜진 채 apply 됐다" }
                if (-not $toSns) { $fail += "$($r.Name) 이 SNS 로 가지 않는다 — 통보가 끊긴다" }
            }
        }
        if ($r.State -ne "ENABLED") { $fail += "규칙 $($r.Name) 이 비활성 상태다" }
    }
}

# --- 4. IAM 활동 감시 (us-east-1 → 서울 relay) --------------------------------
Write-Section "[4] IAM 활동 감시 배선 (us-east-1)"

$iamRulesRaw = aws events list-rules --region $edgeRegion --output json
if ($LASTEXITCODE -ne 0) {
    $pending += "us-east-1 EventBridge 규칙 조회 실패"
} else {
    $iamRules = ($iamRulesRaw | Out-String | ConvertFrom-Json).Rules |
        Where-Object { $_.Name -like "*gochuchamchi*" }
    if (-not $iamRules) {
        # 이 규칙은 go/terraform(일일 계층)에 있다. 저녁 daily-down 뒤에는 없는 게
        # 정상이고, 아침 daily-up 뒤에 없으면 그때가 진짜 문제다.
        $pending += "us-east-1 에 gochuchamchi 규칙이 없다 — daily-up 이후라면 문제다(일일 계층 리소스)"
        Write-Host "    … 규칙 없음 (인프라가 내려간 상태면 정상)" -ForegroundColor Yellow
    } else {
        foreach ($r in $iamRules) {
            Write-Host "    ✔ $($r.Name)  (State=$($r.State))"
            if ($r.State -ne "ENABLED") { $fail += "us-east-1 규칙 $($r.Name) 이 비활성이다" }
        }
    }
}

# --- 5. Discord webhook 시크릿 (값은 출력하지 않는다) -------------------------
Write-Section "[5] Discord webhook 시크릿"

foreach ($s in $discordSecrets) {
    $stages = aws secretsmanager describe-secret --secret-id $s --region $region --query "VersionIdsToStages" --output json
    if ($LASTEXITCODE -ne 0) {
        $fail += "시크릿 $s 이 없다"
        Write-Host "    ✖ $s 없음" -ForegroundColor Red
    } elseif (-not $stages -or ($stages | Out-String).Trim() -eq "null") {
        # 그릇만 만들어지고 값이 한 번도 안 들어간 상태. 알림이 조용히 죽는다.
        $fail += "시크릿 $s 에 값이 없다 (그릇만 존재)"
        Write-Host "    ✖ $s 값 없음" -ForegroundColor Red
    } else {
        Write-Host "    ✔ $s 값 있음"
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
    Write-Host "판정: 미결" -ForegroundColor Yellow
    $pending | ForEach-Object { Write-Host "  - $_" }
    exit 2
}
Write-Host "판정: 통과 — 구독·알람 액션·GuardDuty 배선·시크릿 전부 정상" -ForegroundColor Green
exit 0
