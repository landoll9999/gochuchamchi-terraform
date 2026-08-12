# =============================================================================
# verify-schema-sync.ps1 — spring 원본과 terraform 사본의 schema.sql 동기화 검사
#
# 왜 있나 (2026-08-12 실증)
#   go/k8s/gochuchamchi/schema.sql 은 gochuchamchi-spring 의
#   src/main/resources/schema.sql 을 사람이 손으로 맞추는 사본이다. 앱 커밋
#   a288da1 이 audit_logs / user_behavior_logs 를 추가했을 때 사본이 갱신되지
#   않았고, 앱은 홈 화면이 열릴 때마다 존재하지 않는 테이블에 INSERT 하다
#   에러 1146 으로 실패했다(5분에 266건). 예외를 삼키고 200 을 반환해서 화면은
#   정상이라 아무도 몰랐다 — RDS 감사 로그에 DML 을 켠 날 처음 드러났다.
#   "주석으로 같은 내용을 유지하라"는 강제력이 없다. 이 스크립트가 그 강제력이다.
#
# 비교 범위
#   CREATE TABLE 블록만 비교한다. 시드(INSERT IGNORE 관리자 계정)와 마이그레이션
#   (ALTER TABLE ... IF NOT EXISTS)은 사본 고유가 허용된다 — 재구축·운영 보정용이라
#   원본에 없는 것이 정상이다. 주석(--)은 양쪽 모두 비교 전에 제거한다.
#   대소문자는 무시한다(키워드 표기 차이가 오탐을 만들지 않도록).
#
# 사용
#   로컬:  go\scripts\verify-schema-sync.ps1
#          (spring 저장소를 얕은 clone — git credential 이 spring 읽기 권한을
#           가져야 한다. 팀원 계정이면 이미 가진 권한이다.)
#   CI:    verify-schema-sync.ps1 -SpringSchemaPath <checkout 된 원본 경로>
#          (.github/workflows/schema-sync-check.yml 이 이렇게 부른다)
#
# 종료코드: 0 = 동기화됨 / 1 = 불일치 발견 / 2 = 실행 오류(네트워크 등)
#
# PS 5.1 주의사항 준수 (docs/2026-08-11-트러블슈팅-종합, daily-up.ps1 참조):
#   - $ErrorActionPreference = "Stop" 을 쓰지 않는다 (native stderr 가 ErrorRecord 로
#     승격돼 스크립트가 죽는 함정). 종료코드는 $LASTEXITCODE 로 직접 검사한다.
#   - native 명령 출력에 Select-Object -First 를 직결하지 않는다 (조기 종료가
#     프로세스를 죽여 $LASTEXITCODE = -1 이 되는 함정).
#   - 이 파일은 UTF-8 BOM 이어야 한글이 PS 5.1 에서 깨지지 않는다.
# =============================================================================
param(
    [string]$SpringSchemaPath,
    [string]$SpringRepoUrl = 'https://github.com/landoll9999/gochuchamchi-spring.git',
    [string]$CopySchemaPath
)

if (-not $CopySchemaPath) {
    $CopySchemaPath = Join-Path $PSScriptRoot '../k8s/gochuchamchi/schema.sql'
}
if (-not (Test-Path $CopySchemaPath)) {
    Write-Host "✖ 사본을 찾을 수 없습니다: $CopySchemaPath" -ForegroundColor Red
    exit 2
}

# CREATE TABLE 블록을 { 테이블명(소문자) = 정규화된 정의 } 로 추출.
# 정규화 = 주석 제거 -> 공백 연속을 한 칸으로 -> 소문자. 블록 안에 ';' 가 없다는
# 사실을 종결자로 쓴다(주석을 먼저 지우므로 주석 속 ';' 도 문제되지 않는다).
function Get-TableDefs {
    param([string]$Raw)
    $noComment = ($Raw -split "`r?`n" | ForEach-Object { $_ -replace '--.*$', '' }) -join "`n"
    $defs = @{}
    foreach ($m in [regex]::Matches($noComment, 'CREATE TABLE IF NOT EXISTS\s+`?(\w+)`?[^;]*;', 'IgnoreCase')) {
        $name = $m.Groups[1].Value.ToLowerInvariant()
        $defs[$name] = ($m.Value -replace '\s+', ' ').Trim().ToLowerInvariant()
    }
    return $defs
}

$tempDir = $null
try {
    if (-not $SpringSchemaPath) {
        $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('schema-sync-' + [guid]::NewGuid().ToString('N'))
        Write-Host "spring 원본을 가져오는 중 (얕은 clone: $SpringRepoUrl)"
        git clone --quiet --depth 1 --filter=blob:none --sparse $SpringRepoUrl $tempDir
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✖ spring 저장소 clone 실패 — 네트워크 또는 권한(비공개 저장소 읽기) 문제입니다." -ForegroundColor Red
            exit 2
        }
        git -C $tempDir sparse-checkout set src/main/resources
        if ($LASTEXITCODE -ne 0) {
            Write-Host "✖ sparse-checkout 실패" -ForegroundColor Red
            exit 2
        }
        $SpringSchemaPath = Join-Path $tempDir 'src/main/resources/schema.sql'
    }
    if (-not (Test-Path $SpringSchemaPath)) {
        Write-Host "✖ spring 원본을 찾을 수 없습니다: $SpringSchemaPath" -ForegroundColor Red
        exit 2
    }

    $spring = Get-TableDefs (Get-Content $SpringSchemaPath -Raw -Encoding UTF8)
    $copy   = Get-TableDefs (Get-Content $CopySchemaPath  -Raw -Encoding UTF8)

    if ($spring.Count -eq 0) {
        Write-Host "✖ spring 원본에서 CREATE TABLE 을 하나도 찾지 못했습니다 — 파싱 규칙이 원본 형식과 어긋났을 수 있습니다." -ForegroundColor Red
        exit 2
    }

    Write-Host "원본 테이블 $($spring.Count)개 / 사본 테이블 $($copy.Count)개"
    $fail = $false

    foreach ($t in ($spring.Keys | Sort-Object)) {
        if (-not $copy.ContainsKey($t)) {
            Write-Host "✖ 사본에 누락: $t  — 앱이 이 테이블을 쓰는 순간 에러 1146 이 재현됩니다" -ForegroundColor Red
            $fail = $true
        }
    }
    foreach ($t in ($copy.Keys | Sort-Object)) {
        if (-not $spring.ContainsKey($t)) {
            Write-Host "✖ 사본에만 존재: $t  — 원본에서 삭제됐거나 사본에 잘못 추가된 것" -ForegroundColor Red
            $fail = $true
        }
    }
    foreach ($t in ($spring.Keys | Sort-Object)) {
        if ($copy.ContainsKey($t) -and ($copy[$t] -ne $spring[$t])) {
            Write-Host "✖ 정의 불일치: $t" -ForegroundColor Red
            Write-Host "    원본: $($spring[$t])"
            Write-Host "    사본: $($copy[$t])"
            $fail = $true
        }
    }

    if ($fail) {
        Write-Host ""
        Write-Host "✖ schema.sql 동기화가 깨져 있습니다. go/k8s/gochuchamchi/schema.sql 을 원본에 맞추세요." -ForegroundColor Red
        Write-Host "  (시드/마이그레이션 블록은 사본 고유가 허용 — CREATE TABLE 만 맞추면 됩니다)"
        exit 1
    }
    Write-Host "✔ CREATE TABLE $($spring.Count)개 모두 일치 — 동기화 정상" -ForegroundColor Green
    exit 0
}
finally {
    if ($tempDir -and (Test-Path $tempDir)) {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
