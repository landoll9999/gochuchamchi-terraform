param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("management", "log", "workload")]
    [string]$Account
)

$ErrorActionPreference = "Stop"

$accounts = @{
    management = @{ Id = "307223751140"; Profile = "management-admin" }
    log        = @{ Id = "564186750363"; Profile = "log-admin" }
    workload   = @{ Id = "828885965304"; Profile = "workload-admin" }
}

$selected = $accounts[$Account]
$accountId = $selected.Id
$profile = $selected.Profile
$region = "ap-northeast-2"
$bucket = "gochuchamchi-tfstate-$accountId"

$callerAccount = aws sts get-caller-identity `
    --profile $profile `
    --query Account `
    --output text

if ($LASTEXITCODE -ne 0) {
    throw "AWS 프로파일 '$profile'로 호출자 확인에 실패했습니다."
}

if ($callerAccount -ne $accountId) {
    throw "중단: '$profile'의 실제 계정은 $callerAccount, 예상 계정은 $accountId 입니다."
}

# Windows PowerShell 5.1은 AWS CLI가 stderr를 쓰면 ErrorActionPreference=Stop에서
# NativeCommandError로 중단될 수 있다. 버킷 미존재는 여기서는 정상 분기이므로
# 이 호출에 한해서만 오류를 비종료형으로 처리하고 종료 코드를 보존한다.
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
aws s3api head-bucket --bucket $bucket --profile $profile 2>$null
$headBucketExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference

if ($headBucketExitCode -ne 0) {
    Write-Host "tfstate 버킷 생성: $bucket"
    aws s3api create-bucket `
        --bucket $bucket `
        --region $region `
        --create-bucket-configuration "LocationConstraint=$region" `
        --profile $profile

    if ($LASTEXITCODE -ne 0) {
        throw "tfstate 버킷 생성에 실패했습니다."
    }
}
else {
    Write-Host "기존 tfstate 버킷 사용: $bucket"
}

$tlsOnlyPolicy = @{
    Version = "2012-10-17"
    Statement = @(
        @{
            Sid       = "DenyInsecureTransport"
            Effect    = "Deny"
            Principal = "*"
            Action    = "s3:*"
            Resource  = @("arn:aws:s3:::$bucket", "arn:aws:s3:::$bucket/*")
            Condition = @{ Bool = @{ "aws:SecureTransport" = "false" } }
        }
    )
} | ConvertTo-Json -Depth 6 -Compress

# PowerShell 5.1은 JSON 문자열을 native executable 인자로 넘길 때 큰따옴표를
# 제거할 수 있다. 단순 구조는 AWS CLI shorthand를 쓰고, 버킷 정책만 임시 JSON
# 파일로 전달한다. 임시 파일은 성공/실패와 관계없이 finally에서 제거한다.
$policyFile = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("gochuchamchi-tfstate-policy-{0}.json" -f [guid]::NewGuid().ToString("N"))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($policyFile, $tlsOnlyPolicy, $utf8NoBom)
$policyFileUri = "file://$($policyFile -replace '\\', '/')"

aws s3api put-public-access-block `
    --bucket $bucket `
    --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "퍼블릭 액세스 차단 설정에 실패했습니다." }

aws s3api put-bucket-versioning `
    --bucket $bucket `
    --versioning-configuration Status=Enabled `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "버저닝 설정에 실패했습니다." }

# -----------------------------------------------------------------------------
# state 전용 KMS 키 (2026-08-13, SSE-S3 -> SSE-KMS)
#
# 왜 바꾸나 — SSE-S3 는 "버킷을 읽을 수 있으면 곧 복호화"다. 즉 방어선이
# s3:GetObject 하나뿐이다. KMS 로 가면 s3:GetObject 와 kms:Decrypt 두 개를
# 모두 가져야 하고, 무엇보다 **누가 state 를 읽었는지 CloudTrail 에 남는다**
# (KMS Decrypt 는 관리 이벤트라 S3 데이터 이벤트를 따로 켜지 않아도 기록된다).
# tfstate 는 설정 파일이 아니라 시크릿 그 자체다(감사 보고서 원칙).
#
# 왜 terraform 이 아니라 여기인가 — 이 키로 암호화되는 것이 terraform 의 state
# 자체다. terraform 이 키를 관리하면 "키가 사라지면 state 를 못 읽고, state 를
# 못 읽으니 키를 되살릴 수도 없는" 순환이 생긴다. 버킷과 같은 부트스트랩 계층에
# 둬서 그 고리를 끊는다.
#
# ※ 이 키는 절대 삭제하면 안 된다. 지우면 모든 루트의 state 가 복호화 불가가
#   되고, 버전 이력까지 통째로 잠긴다. 삭제 예약이 걸리면 창이 닫히기 전에
#   반드시 취소할 것(cancel-key-deletion).
# -----------------------------------------------------------------------------
$kmsAlias = "alias/gochuchamchi-tfstate"

# 별칭 존재 확인 — 없으면 NotFound 로 실패하는 것이 정상 분기다. head-bucket 과
# 같은 이유로 이 호출에서만 오류를 비종료형으로 낮춘다(리다이렉트는 쓰지 않는다.
# PS 5.1 은 native stderr 를 "리다이렉트하는 것만으로" ErrorRecord 로 감싼다).
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$kmsKeyArn = aws kms describe-key --key-id $kmsAlias --query "KeyMetadata.Arn" --output text --profile $profile
$describeKeyExitCode = $LASTEXITCODE
$ErrorActionPreference = $previousErrorActionPreference

if ($describeKeyExitCode -ne 0) {
    Write-Host "tfstate KMS 키 생성: $kmsAlias"

    # 기본 키 정책(계정 루트에 위임)을 그대로 쓴다. 이렇게 하면 접근 통제가
    # IAM 쪽 한 곳에서 결정되고, 키 정책과 IAM 정책이 서로 어긋나 잠기는
    # 사고를 피할 수 있다.
    $keyPolicy = @{
        Version   = "2012-10-17"
        Statement = @(
            @{
                Sid       = "EnableIAMUserPermissions"
                Effect    = "Allow"
                Principal = @{ AWS = "arn:aws:iam::${accountId}:root" }
                Action    = "kms:*"
                Resource  = "*"
            }
        )
    } | ConvertTo-Json -Depth 6 -Compress

    $keyPolicyFile = Join-Path ([System.IO.Path]::GetTempPath()) `
        ("gochuchamchi-tfstate-kms-{0}.json" -f [guid]::NewGuid().ToString("N"))
    [System.IO.File]::WriteAllText($keyPolicyFile, $keyPolicy, $utf8NoBom)
    $keyPolicyUri = "file://$($keyPolicyFile -replace '\\', '/')"

    try {
        $kmsKeyId = aws kms create-key `
            --description "gochuchamchi tfstate encryption ($Account)" `
            --key-usage ENCRYPT_DECRYPT `
            --key-spec SYMMETRIC_DEFAULT `
            --policy $keyPolicyUri `
            --query "KeyMetadata.KeyId" `
            --output text `
            --profile $profile
        if ($LASTEXITCODE -ne 0) { throw "tfstate KMS 키 생성에 실패했습니다." }

        aws kms create-alias --alias-name $kmsAlias --target-key-id $kmsKeyId --profile $profile
        if ($LASTEXITCODE -ne 0) { throw "KMS 별칭 생성에 실패했습니다." }

        # 연 1회 자동 로테이션. 과거 데이터는 옛 키 자료로 계속 복호화되므로
        # 재암호화 없이 안전하다.
        aws kms enable-key-rotation --key-id $kmsKeyId --profile $profile
        if ($LASTEXITCODE -ne 0) { throw "KMS 키 로테이션 활성화에 실패했습니다." }

        $kmsKeyArn = aws kms describe-key --key-id $kmsAlias --query "KeyMetadata.Arn" --output text --profile $profile
        if ($LASTEXITCODE -ne 0) { throw "생성한 KMS 키 조회에 실패했습니다." }
    }
    finally {
        Remove-Item -LiteralPath $keyPolicyFile -Force -ErrorAction SilentlyContinue
    }
}
else {
    Write-Host "기존 tfstate KMS 키 사용: $kmsAlias"
}

# BucketKeyEnabled=true — 객체마다 KMS 를 부르지 않고 버킷 수준 데이터 키를
# 재사용한다. state 는 작은 파일을 자주 쓰는 패턴이라 이게 없으면 KMS 요청
# 비용과 지연이 그대로 붙는다.
aws s3api put-bucket-encryption `
    --bucket $bucket `
    --server-side-encryption-configuration "Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=aws:kms,KMSMasterKeyID=$kmsKeyArn},BucketKeyEnabled=true}]" `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "기본 암호화(SSE-KMS) 설정에 실패했습니다." }

# -----------------------------------------------------------------------------
# 수명주기 — 옛 state 버전을 무한정 쌓아 두지 않는다
#
# 버저닝은 실수 복구용이지 영구 보관용이 아니다. 2026-08-13 기준 이 버킷에
# 버전 298개·138MB 가 쌓여 있었고, 그 안에는 그날그날의 random_password 값이
# 평문으로 들어 있다(매일 재생성되므로 곧 무효가 되지만, 쌓아 둘 이유가 없다).
# 30일 + 최근 10개는 남겨서 되돌릴 여지는 유지한다.
# -----------------------------------------------------------------------------
$lifecycle = @{
    Rules = @(
        @{
            ID     = "expire-old-state-versions"
            Status = "Enabled"
            Filter = @{ Prefix = "" }
            NoncurrentVersionExpiration = @{
                NoncurrentDays          = 30
                NewerNoncurrentVersions = 10
            }
            AbortIncompleteMultipartUpload = @{ DaysAfterInitiation = 7 }
            Expiration = @{ ExpiredObjectDeleteMarker = $true }
        }
    )
} | ConvertTo-Json -Depth 6 -Compress

$lifecycleFile = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("gochuchamchi-tfstate-lifecycle-{0}.json" -f [guid]::NewGuid().ToString("N"))
[System.IO.File]::WriteAllText($lifecycleFile, $lifecycle, $utf8NoBom)
$lifecycleUri = "file://$($lifecycleFile -replace '\\', '/')"

try {
    aws s3api put-bucket-lifecycle-configuration `
        --bucket $bucket `
        --lifecycle-configuration $lifecycleUri `
        --profile $profile
    if ($LASTEXITCODE -ne 0) { throw "수명주기 규칙 설정에 실패했습니다." }
}
finally {
    Remove-Item -LiteralPath $lifecycleFile -Force -ErrorAction SilentlyContinue
}

try {
    aws s3api put-bucket-policy `
        --bucket $bucket `
        --policy $policyFileUri `
        --profile $profile
    if ($LASTEXITCODE -ne 0) { throw "TLS 전용 버킷 정책 설정에 실패했습니다." }
}
finally {
    Remove-Item -LiteralPath $policyFile -Force -ErrorAction SilentlyContinue
}

Write-Host "완료: $bucket (버저닝, 퍼블릭 차단, SSE-KMS, TLS 강제, 수명주기 30일)" -ForegroundColor Green
Write-Host "  KMS 키: $kmsKeyArn" -ForegroundColor Green
Write-Host ""
Write-Host "  ※ 각 루트의 backend.tf 에 kms_key_id 가 있어야 실제로 KMS 로 저장된다." -ForegroundColor Yellow
Write-Host "    terraform 은 encrypt=true 이고 kms_key_id 가 없으면 AES256 을 명시적으로" -ForegroundColor Yellow
Write-Host "    보내서 버킷 기본 암호화를 덮어쓴다. 변경 후에는 각 루트에서" -ForegroundColor Yellow
Write-Host "    terraform init -reconfigure 를 한 번 돌려야 한다." -ForegroundColor Yellow
