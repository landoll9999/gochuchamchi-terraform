# =============================================================================
# 배포 후 검증 — 트리아지가 실제로 도는지, 정책 표대로 판단하는지 확인한다
#
# 왜 스크립트인가
#   이 파이프라인에서 가장 위험한 상태는 "알림이 안 오는 것"과 "탐지가 멈춘 것"이
#   구분되지 않는 것이다. 실제 GuardDuty finding을 기다리면 그 구분이 안 되므로,
#   정책 표의 각 칸을 직접 쏴 보고 기대한 액션이 나오는지 확인한다.
#
#   aws guardduty create-sample-findings 로는 severity를 고를 수 없어 정책 표를
#   골고루 검증할 수 없다. 그래서 Lambda를 직접 호출한다 — EventBridge가 주는
#   것과 같은 형태의 이벤트를 만들어 넣으므로 실제 경로와 같다.
#
# ⚠️ 이 스크립트는 **진짜 Discord 알림을 보낸다.** 통보 대상 케이스가 4건 있다.
#    그걸 눈으로 확인하는 것이 목적이다.
#
# 사용법
#   cd C:\terraform\go\cloudwatch-notifications\triage
#   .\verify-deployment.ps1
#   .\verify-deployment.ps1 -Profile workload-admin -Region ap-northeast-2
# =============================================================================

param(
    [string]$Profile = "workload-admin",
    [string]$Region = "ap-northeast-2",
    [string]$FunctionName = "gochuchamchi-guardduty-triage",
    [string]$RuleName = "gochuchamchi-guardduty-finding",
    [string]$SecretId = "gochuchamchi/triage/groq-api-key"
)

$ErrorActionPreference = "Stop"
$temp = Join-Path $env:TEMP "triage-verify"
New-Item -ItemType Directory -Force -Path $temp | Out-Null

function Section($text) { Write-Host "`n$text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Warn($text) { Write-Host "  [주의] $text" -ForegroundColor Yellow }
function Bad($text) { Write-Host "  [문제] $text" -ForegroundColor Red }


# =============================================================================
# 1. 배선 — finding 없이도 확인할 수 있는 것부터
# =============================================================================

Section "[1] 배선 확인"

# EventBridge 타겟이 SNS가 아니라 트리아지 Lambda 여야 한다.
# 여기가 틀리면 finding이 트리아지를 아예 안 거치고, 알림은 정상으로 보인다.
$targets = aws events list-targets-by-rule --rule $RuleName `
    --region $Region --profile $Profile --output json | ConvertFrom-Json

$targetArns = $targets.Targets | ForEach-Object { $_.Arn }

if ($targetArns -match "function:$FunctionName") {
    Ok "EventBridge 타겟이 트리아지 Lambda 입니다"
} elseif ($targetArns -match ":sns:") {
    Bad "EventBridge 타겟이 아직 SNS 직결입니다 — enable_triage 가 false 이거나 apply 가 안 됐습니다"
    Write-Host "         현재 타겟: $targetArns"
    exit 1
} else {
    Bad "예상치 못한 타겟: $targetArns"
    exit 1
}

# 시크릿에 값이 들어갔는지. 값 자체는 절대 출력하지 않는다.
try {
    $secret = aws secretsmanager get-secret-value --secret-id $SecretId `
        --region $Region --profile $Profile --query SecretString --output text 2>$null
    if ([string]::IsNullOrWhiteSpace($secret)) {
        Warn "Groq 시크릿이 비어 있습니다 — 판정 없이 통보만 됩니다 (탐지 공백은 아님)"
    } else {
        Ok "Groq 시크릿에 값이 있습니다 (길이 $($secret.Length))"
    }
} catch {
    Warn "Groq 시크릿을 읽지 못했습니다 — 아직 주입하지 않았다면 정상입니다"
    Write-Host "         aws secretsmanager put-secret-value --secret-id $SecretId ..."
}


# =============================================================================
# 2. 정책 표 검증 — 각 칸을 직접 쏴 본다
#
# 같은 finding id 를 두 번 쓰면 중복 억제에 걸리므로 매 실행마다 새 id 를 만든다.
# =============================================================================

Section "[2] 정책 표 검증 — Lambda 직접 호출"

$run = Get-Date -Format "yyyyMMddHHmmss"

# type / severity / 설명 / 기대 결과
$cases = @(
    @{
        Type = "Policy:IAMUser/RootCredentialUsage"
        Severity = 2.0
        Desc = "루트 사용 (severity 2 — 이 환경의 실제 형태)"
        Expect = "tier 가 LOW 가 아니라 HIGH 로 승격되어야 한다. filtered 면 승격이 안 된 것"
    },
    @{
        Type = "CredentialAccess:IAMUser/AnomalousBehavior"
        Severity = 2.0
        Desc = "자격증명 이상 행위 (severity 2)"
        Expect = "위와 같이 HIGH 로 승격"
    },
    @{
        Type = "Recon:EC2/PortProbeUnprotectedPort"
        Severity = 2.0
        Desc = "일반 LOW 소음"
        Expect = "filtered — LOW 는 판정 없이 저장만. 모델 호출이 없어야 한다"
    },
    @{
        Type = "Trojan:EC2/DNSDataExfiltration"
        Severity = 5.0
        Desc = "MEDIUM"
        Expect = "AI 판정에 따라 alert / review / suppress 중 하나"
    },
    @{
        Type = "Backdoor:EC2/C&CActivity.B"
        Severity = 8.0
        Desc = "HIGH — C2 통신"
        Expect = "urgent 또는 review. FALSE_POSITIVE 여도 통보는 나가야 한다"
    },
    @{
        Type = "Impact:EC2/AbusedDomainRequest.Reputation"
        Severity = 9.5
        Desc = "CRITICAL"
        Expect = "AI 판정과 무관하게 urgent"
    }
)

$index = 0
foreach ($case in $cases) {
    $index++
    $findingId = "verify-$run-$index"

    # EventBridge 가 Lambda 에 주는 것과 같은 형태의 이벤트.
    # JSON 은 파일로 넘긴다 — PowerShell 에서 인라인 JSON 은 따옴표가 깨진다.
    $event = @{
        source = "aws.guardduty"
        "detail-type" = "GuardDuty Finding"
        detail = @{
            id = $findingId
            type = $case.Type
            severity = $case.Severity
            accountId = "000000000000"
            region = $Region
            title = "[검증] $($case.Type)"
            description = "verify-deployment.ps1 이 생성한 검증용 이벤트입니다."
            service = @{
                count = 1
                resourceRole = "TARGET"
                eventFirstSeen = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                eventLastSeen = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
                action = @{
                    actionType = "AWS_API_CALL"
                    awsApiCallAction = @{
                        api = "GetCallerIdentity"
                        serviceName = "sts.amazonaws.com"
                        remoteIpDetails = @{
                            ipAddressV4 = "198.51.100.23"
                            country = @{ countryName = "Netherlands" }
                        }
                    }
                }
            }
            resource = @{
                resourceType = "Instance"
                instanceDetails = @{ instanceId = "i-verify$run" }
            }
        }
    }

    $payloadPath = Join-Path $temp "event-$index.json"
    $outPath = Join-Path $temp "out-$index.json"
    # payload 는 순수 ASCII 로 쓴다. 이유가 두 가지 겹쳐 있다.
    #   1) PS 5.1 의 `Out-File -Encoding utf8` 은 BOM 을 붙인다(pwsh 7 은 안 붙임).
    #   2) AWS CLI 는 Windows 에서 file:// 파라미터를 로캘 인코딩(한국어 Windows
    #      기준 cp949)으로 읽는다. 한글을 UTF-8 바이트 그대로 넣으면 디코드에
    #      실패한다 — "text contents could not be decoded".
    # 비 ASCII 문자를 JSON \uXXXX 이스케이프로 바꾸면 JSON 규격상 동등하면서
    # 어떤 로캘에서도 안전하다.
    $json = $event | ConvertTo-Json -Depth 10
    $ascii = New-Object System.Text.StringBuilder
    foreach ($ch in $json.ToCharArray()) {
        if ([int]$ch -gt 127) { [void]$ascii.AppendFormat('\u{0:x4}', [int]$ch) }
        else { [void]$ascii.Append($ch) }
    }
    [System.IO.File]::WriteAllText($payloadPath, $ascii.ToString(), (New-Object System.Text.ASCIIEncoding))

    Write-Host "`n  ── $($case.Desc)"

    aws lambda invoke --function-name $FunctionName `
        --payload "file://$payloadPath" `
        --cli-binary-format raw-in-base64-out `
        --region $Region --profile $Profile `
        $outPath | Out-Null

    # Lambda 응답은 UTF-8 이다. PS 5.1 의 Get-Content 기본값은 시스템 ANSI(cp949)라
    # 한글 reason 이 깨진다 — 화면 출력뿐 아니라 아래 [3] 의 문자열 매칭도 틀어진다.
    $result = Get-Content $outPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($result.errorMessage) {
        Bad "Lambda 실행 오류: $($result.errorMessage)"
        continue
    }

    if ($result.status -eq "filtered") {
        Write-Host "     결과: filtered — $($result.reason)"
    } else {
        $notified = if ($result.notified) { "통보 O" } else { "통보 X" }
        Write-Host ("     결과: tier={0}  판정={1}  확신={2}  위험도={3}  액션={4}  {5}" -f `
            $result.tier, $result.verdict, $result.confidence, $result.risk_score, $result.action, $notified)
        Write-Host "           판정 출처: $($result.judged_from)$(if ($result.verdict_demoted) { '  (강등됨)' })"
    }
    Write-Host "     기대: $($case.Expect)" -ForegroundColor DarkGray
}


# =============================================================================
# 3. 필터 검증 — 중복 억제와 판정 캐시
# =============================================================================

Section "[3] 필터 검증"

# 방금 쏜 1번을 그대로 다시 쏜다. 중복 억제에 걸려야 정상.
$payloadPath = Join-Path $temp "event-1.json"
$outPath = Join-Path $temp "out-dup.json"

aws lambda invoke --function-name $FunctionName `
    --payload "file://$payloadPath" `
    --cli-binary-format raw-in-base64-out `
    --region $Region --profile $Profile `
    $outPath | Out-Null

$dup = Get-Content $outPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($dup.status -eq "filtered" -and $dup.reason -match "중복") {
    Ok "같은 finding id 재수신 → 중복 억제 동작"
} else {
    Warn "중복 억제가 안 걸렸습니다: $($dup | ConvertTo-Json -Compress)"
}


# =============================================================================
# 4. 다음에 볼 것
# =============================================================================

Section "[4] 다음에 확인할 것"

Write-Host @"
  Discord
    위에서 '통보 O' 로 나온 건수만큼 메시지가 도착해야 합니다.
    각 메시지에서 볼 것:
      - '판정 출처' 필드가 '모델 판정 (모델명)' 인가
        → '판정 없음' 이면 그 사유가 같이 찍힙니다 (키 미주입/모델ID 오류/한도)
      - 색과 아이콘이 액션과 맞는가 (긴급=빨강, 검토=노랑, 오탐의심=회색)
      - 루트 사용 건의 등급이 HIGH 로 찍혔는가  ← 가장 중요

  로그
    aws logs tail /aws/lambda/$FunctionName --since 10m --region $Region --profile $Profile

  지표 (CloudWatch > Metrics > Gochuchamchi/Triage)
    Received / Filtered      유입과 필터링 비율
    Verdict, Action          판정·액션 분포
    Suppressed               AI 가 없앤 알림 수 — 크면 정책이 위험합니다
    JudgeCalls / CacheHit    캐시가 실제로 호출을 아끼는지
    JudgeUnavailable         판정이 안 붙은 횟수
    InjectionSuspected       0 이 아니면 즉시 확인

  실제 GuardDuty finding 으로도 한 번
    aws guardduty create-sample-findings ``
      --detector-id <detector-id> ``
      --finding-types "CryptoCurrency:EC2/BitcoinTool.B!DNS" ``
      --region $Region --profile $Profile

    검증 이벤트는 Lambda 직접 호출이라 EventBridge 필터를 안 거칩니다.
    실제 finding 은 EventBridge 패턴까지 통과해야 하므로 배선 전체가 검증됩니다.
"@ -ForegroundColor Gray

Write-Host "`n  검증용 이벤트/응답 파일: $temp`n" -ForegroundColor DarkGray
