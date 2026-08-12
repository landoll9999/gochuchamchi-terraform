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
    요구사항: Python 3 + pip, 네트워크 접근(PyPI).

    PATH의 python을 그대로 쓰지 않고 Resolve-Python으로 검증해서 고른다.
    이유는 그 함수 주석 참고.
#>

$ErrorActionPreference = "Stop"

function Resolve-Python {
    <#
    .SYNOPSIS
        실제로 동작하는 Python 3 + pip 조합을 찾아 돌려준다.

    .DESCRIPTION
        PATH의 python을 믿지 않는다. Windows는
        %LOCALAPPDATA%\Microsoft\WindowsApps 에 Microsoft Store로 유도하는
        python.exe 스텁을 두는데, 이게 실제 설치본보다 PATH 앞에 오는 일이 흔하다.
        스텁을 부르면 "Python was not found..."만 찍히고 pip install이 실패하는데,
        메시지가 파이썬이 없다고만 말해서 실제로는 설치돼 있는 상황과 구분이 안 된다.

        스텁은 경로로 걸러낸다. 실행해서 판별하려면 네이티브 stderr 리다이렉션이
        필요한데, PS 5.1에서 그건 $ErrorActionPreference="Stop"과 만나
        NativeCommandError를 일으켜 정상 종료까지 실패로 뒤집는다.

        설치 직후처럼 PATH가 아직 갱신되지 않은 셸에서도 동작하도록 표준 설치
        경로까지 훑는다 — 그 덕에 앱을 재시작하지 않고도 빌드가 된다.
    #>
    $candidates = New-Object System.Collections.ArrayList

    # py 런처가 가장 신뢰할 만하다. 스텁과 무관하게 실제 설치본을 가리킨다.
    $launcher = Get-Command py -ErrorAction SilentlyContinue
    if ($launcher) { [void]$candidates.Add(@($launcher.Source, "-3")) }

    foreach ($name in @("python3", "python")) {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { [void]$candidates.Add(@($cmd.Source)) }
    }

    $roots = @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python"),
        (Join-Path $env:ProgramFiles "Python312"),
        (Join-Path $env:ProgramFiles "Python311")
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        @(Get-ChildItem -Path $root -Filter "python.exe" -Recurse -Depth 1 -ErrorAction SilentlyContinue) |
            ForEach-Object { [void]$candidates.Add(@($_.FullName)) }
    }

    foreach ($candidate in $candidates) {
        $exe = $candidate[0]
        if ($exe -like "*\Microsoft\WindowsApps\*") { continue }   # 스토어 스텁
        if (-not (Test-Path $exe)) { continue }

        $prefix = @()
        if ($candidate.Count -gt 1) { $prefix = $candidate[1..($candidate.Count - 1)] }

        $probe = & $exe @prefix -c "import sys; sys.stdout.write(sys.version.split()[0])"
        if ($LASTEXITCODE -ne 0 -or -not $probe) { continue }

        & $exe @prefix -m pip --version | Out-Null
        if ($LASTEXITCODE -ne 0) { continue }

        Write-Host "[ai-triage] Python $probe 사용 → $exe $($prefix -join ' ')"
        return @{ Exe = $exe; Prefix = $prefix }
    }

    throw @"
동작하는 Python 3 + pip 을 찾지 못했다.

    winget install Python.Python.3.12

설치했는데도 이 오류가 나면 PATH가 갱신되지 않은 셸일 수 있다. 이 스크립트는
표준 설치 경로까지 훑으므로 보통은 그래도 찾아내지만, 비표준 위치에 설치했다면
셸(또는 이 스크립트를 호출한 앱)을 다시 띄울 것.
"@
}

$BuildRoot = Join-Path $PSScriptRoot "build"
$LayerRoot = Join-Path $BuildRoot "layer"
$SitePackages = Join-Path $LayerRoot "python"   # Lambda 레이어 규약 경로

Write-Host "[ai-triage] 레이어 빌드 시작 → $SitePackages"

if (Test-Path $BuildRoot) {
    # 부분 설치가 남아 있으면 버전이 섞인다. 매번 깨끗하게 다시 만든다.
    Remove-Item -Recurse -Force $BuildRoot
}
New-Item -ItemType Directory -Force -Path $SitePackages | Out-Null

$python = Resolve-Python

# --only-binary=:all: 는 소스 배포판 폴백을 막는다. 로컬에서 컴파일되면
# Windows 바이너리가 섞여 들어가므로 조용히 실패하는 것보다 낫다.
& $python.Exe @($python.Prefix) -m pip install `
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
