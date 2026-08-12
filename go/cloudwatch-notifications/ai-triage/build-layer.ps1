<#
.SYNOPSIS
    AI 트리아지 Lambda가 쓸 Anthropic SDK 레이어를 빌드한다.

.DESCRIPTION
    terraform apply 중 ai-triage.tf의 terraform_data가 자동 호출하므로 보통
    직접 실행할 일은 없다. 수동 실행은 빌드만 따로 검증하고 싶을 때 쓴다.

    로컬 파이썬 버전과 무관하게 Lambda(python3.12 / x86_64)용 manylinux 휠을
    받는다 — pydantic-core, jiter가 컴파일 확장이라 로컬 휠을 그대로 올리면
    Windows 바이너리가 들어가서 import 시점에 죽는다.

.NOTES
    요구사항: python3 + pip (PATH에 있어야 함). 네트워크 접근 필요(PyPI).
#>

$ErrorActionPreference = "Stop"

$BuildRoot = Join-Path $PSScriptRoot "build"
$LayerRoot = Join-Path $BuildRoot "layer"
$SitePackages = Join-Path $LayerRoot "python"   # Lambda 레이어 규약 경로

Write-Host "[ai-triage] 레이어 빌드 시작 → $SitePackages"

if (Test-Path $BuildRoot) {
    # 부분 설치가 남아 있으면 버전이 섞인다. 매번 깨끗하게 다시 만든다.
    Remove-Item -Recurse -Force $BuildRoot
}
New-Item -ItemType Directory -Force -Path $SitePackages | Out-Null

# --only-binary=:all: 는 소스 배포판 폴백을 막는다. 로컬에서 컴파일되면
# Windows 바이너리가 섞여 들어가므로 조용히 실패하는 것보다 낫다.
python -m pip install `
    --target $SitePackages `
    --requirement (Join-Path $PSScriptRoot "requirements.txt") `
    --platform manylinux2014_x86_64 `
    --implementation cp `
    --python-version 3.12 `
    --only-binary=:all: `
    --upgrade `
    --quiet

if ($LASTEXITCODE -ne 0) {
    throw "pip install 실패 (exit $LASTEXITCODE)"
}

# Lambda python3.12 런타임이 이미 제공하는 것들. 레이어에 중복으로 넣으면
# 압축 후 ~20MB, 압축 해제 후 ~90MB를 그냥 버린다(레이어 한도 250MB).
foreach ($pkg in @("boto3", "botocore", "s3transfer")) {
    # @()로 먼저 전부 열거한 뒤 지운다 — 파이프라인으로 흘리면 Remove-Item이
    # 삭제하는 도중 Get-ChildItem이 같은 트리를 열거해 일부가 남는다.
    @(Get-ChildItem -Path $SitePackages -Filter "$pkg*" -Directory -ErrorAction SilentlyContinue) |
        ForEach-Object { Remove-Item -Recurse -Force $_.FullName }
}

# 휠에 딸려 오는 pyc는 빌드 머신 기준이라 런타임과 매직넘버가 다를 수 있다.
# 어차피 다시 컴파일되므로 용량만 차지한다.
@(Get-ChildItem -Path $SitePackages -Filter "__pycache__" -Directory -Recurse -ErrorAction SilentlyContinue) |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

$sizeMb = [math]::Round(
    ((Get-ChildItem -Path $SitePackages -Recurse -File | Measure-Object -Property Length -Sum).Sum / 1MB), 1
)
$version = (Get-ChildItem -Path $SitePackages -Filter "anthropic-*.dist-info" -Directory |
    Select-Object -First 1).Name

Write-Host "[ai-triage] 빌드 완료 — $version, 압축 전 $sizeMb MB"
