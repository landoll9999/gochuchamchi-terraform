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

aws s3api head-bucket --bucket $bucket --profile $profile 2>$null
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
    PublicAccessBlockConfiguration = @{
        BlockPublicAcls       = $true
        IgnorePublicAcls      = $true
        BlockPublicPolicy     = $true
        RestrictPublicBuckets = $true
    }
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

aws s3api put-public-access-block `
    --bucket $bucket `
    --public-access-block-configuration $publicAccessBlock `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "퍼블릭 액세스 차단 설정에 실패했습니다." }

aws s3api put-bucket-versioning `
    --bucket $bucket `
    --versioning-configuration Status=Enabled `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "버저닝 설정에 실패했습니다." }

aws s3api put-bucket-encryption `
    --bucket $bucket `
    --server-side-encryption-configuration $encryption `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "기본 암호화 설정에 실패했습니다." }

aws s3api put-bucket-policy `
    --bucket $bucket `
    --policy $tlsOnlyPolicy `
    --profile $profile
if ($LASTEXITCODE -ne 0) { throw "TLS 전용 버킷 정책 설정에 실패했습니다." }

Write-Host "완료: $bucket (버저닝, 퍼블릭 차단, SSE-S3, TLS 강제)" -ForegroundColor Green
