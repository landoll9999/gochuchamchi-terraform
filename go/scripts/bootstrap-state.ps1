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

# PS 5.1에서는 네이티브 명령의 stderr 리다이렉트가 오류로 승격되므로 cmd를 거쳐 확인한다.
cmd /c "aws s3api head-bucket --bucket $bucket --profile $profile 2>nul"
if ($LASTEXITCODE -ne 0) {
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

$publicAccessBlock = @{
    BlockPublicAcls       = $true
    IgnorePublicAcls      = $true
    BlockPublicPolicy     = $true
    RestrictPublicBuckets = $true
} | ConvertTo-Json -Depth 4 -Compress

$encryption = @{
    Rules = @(
        @{
            ApplyServerSideEncryptionByDefault = @{
                SSEAlgorithm = "AES256"
            }
        }
    )
} | ConvertTo-Json -Depth 5 -Compress

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

# JSON을 인자로 직접 넘기면 PS 버전에 따라 따옴표가 유실되므로 file:// 로 전달한다.
$jsonDir = Join-Path $env:TEMP "gochuchamchi-bootstrap"
New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null

$pabFile = Join-Path $jsonDir "public-access-block.json"
$encFile = Join-Path $jsonDir "encryption.json"
$policyFile = Join-Path $jsonDir "tls-policy.json"

Set-Content -Path $pabFile -Value $publicAccessBlock -Encoding Ascii
Set-Content -Path $encFile -Value $encryption -Encoding Ascii
Set-Content -Path $policyFile -Value $tlsOnlyPolicy -Encoding Ascii

try {
    aws s3api put-public-access-block `
        --bucket $bucket `
        --public-access-block-configuration ("file://" + $pabFile.Replace('\', '/')) `
        --profile $profile
    if ($LASTEXITCODE -ne 0) { throw "퍼블릭 액세스 차단 설정에 실패했습니다." }

    aws s3api put-bucket-versioning `
        --bucket $bucket `
        --versioning-configuration Status=Enabled `
        --profile $profile
    if ($LASTEXITCODE -ne 0) { throw "버저닝 설정에 실패했습니다." }

    aws s3api put-bucket-encryption `
        --bucket $bucket `
        --server-side-encryption-configuration ("file://" + $encFile.Replace('\', '/')) `
        --profile $profile
    if ($LASTEXITCODE -ne 0) { throw "기본 암호화 설정에 실패했습니다." }

    aws s3api put-bucket-policy `
        --bucket $bucket `
        --policy ("file://" + $policyFile.Replace('\', '/')) `
        --profile $profile
    if ($LASTEXITCODE -ne 0) { throw "TLS 전용 버킷 정책 설정에 실패했습니다." }
}
finally {
    Remove-Item -Path $jsonDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "완료: $bucket (버저닝, 퍼블릭 차단, SSE-S3, TLS 강제)" -ForegroundColor Green
