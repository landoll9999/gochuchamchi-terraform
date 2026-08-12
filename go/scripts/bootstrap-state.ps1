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

aws s3api put-bucket-encryption `
    --bucket $bucket `
    --server-side-encryption-configuration "Rules=[{ApplyServerSideEncryptionByDefault={SSEAlgorithm=AES256}}]" `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "기본 암호화 설정에 실패했습니다." }

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

Write-Host "완료: $bucket (버저닝, 퍼블릭 차단, SSE-S3, TLS 강제)" -ForegroundColor Green
