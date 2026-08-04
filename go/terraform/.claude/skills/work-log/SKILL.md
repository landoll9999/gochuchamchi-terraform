---
name: work-log
description: 오늘 한 작업과 트러블슈팅을 docs/에 기록하고, 인프라 저장소(gochuchamchi-terraform)에 커밋·push해서 최신화한다. 작업이 한 단락 지었을 때 사용한다.
---

# 작업 기록 → 커밋 → push

오늘 세션에서 한 일을 문서로 남기고 git에 반영한다. **문서를 먼저 쓰고, 사용자가 확인한 뒤 push한다.**

## 0. 대상 확인

| 저장소 | 로컬 경로 | 이 스킬에서의 역할 |
|---|---|---|
| `gochuchamchi-terraform` | `C:\terraform` (내용은 `go/` 하위) | **여기에만 커밋한다** |
| `gochuchamchi-gitops` | `C:\terraform\go\gochuchamchi-gitops` | 서비스 직결. 매니페스트(`.yml`)만. 인프라·문서를 절대 넣지 말 것 |
| `gochuchamchi-spring` | (로컬 클론 없음) | 앱 소스 |

문서 원본은 `C:\terraform\go\docs\`, 인프라 코드는 `C:\terraform\go\terraform\`이며 둘 다
`C:\terraform` 저장소가 추적한다. 복사 불필요 — 그 자리에서 바로 커밋된다.

## 1. 무엇이 바뀌었는지 파악

```powershell
cd C:\terraform
git status --short
git diff --stat
git log --oneline -5
```

코드 변경뿐 아니라 **이번 세션 대화에서 진단·해결한 내용**이 기록의 핵심이다.
코드가 안 바뀐 트러블슈팅(예: 수동 절차 누락, 운영 중 발견한 함정)도 반드시 남긴다.

## 2. 날짜 파일 작성 — `C:\terraform\go\docs\YYYY-MM-DD.md`

`docs/README.md`의 "새 날짜 파일 작성 형식"을 따른다.

- 파일이 이미 있으면 **새 번호 섹션을 덧붙인다** (`## 4.`, `## 5.` …). 기존 내용을 고치지 말 것.
- 건별 구조:
  ```markdown
  ## N. <한 줄 제목>

  ### 작업 목적
  ### 문제가 발생한 지점
  ### 문제 원인
  ### 해결 방법
  ### 검증 완료 사항
  ```
- 세부 이슈는 `### N.1`, `### N.2`로 나눈다. 같은 이슈 재발은 `### N.1-1`처럼 이어 붙인다.
- 이 프로젝트 문서의 톤: **왜 그렇게 판단했는지와 왜 진단이 어려웠는지**를 같이 적는다.
  증상만 나열하지 말고 오진했던 경로, 판별 근거(로그·명령 출력)를 남긴다.
- 실패한 시도도 기록한다 — 다음에 같은 길로 다시 들어가지 않게.

## 3. 다른 문서 파급 확인

바뀐 내용이 아래에 해당하면 **같이 갱신한다.** 해당 없으면 건너뛴다.

| 문서 | 갱신 조건 |
|---|---|
| `pitfalls-checklist.md` | 재사용 가치가 있는 교훈이 있으면 한 줄 추가 (누적 파일) |
| `runbook.md` | 명령/절차/에러 판별표가 바뀌었으면. 재구축 시 필요한 수동 절차는 §5 체크리스트에 |
| `SECURITY_BACKLOG.md` | 백로그 항목의 상태가 바뀌었으면 |
| `architecture.md` | 구조가 바뀌었으면. 초기 구축 기록이므로 **본문을 고치지 말고** "현행 구조와의 차이" 주석을 단다 |
| `DB_SECRET_SETUP.md` / `REDIS_SESSION_GUIDE.md` | 해당 영역이 바뀌었으면 |
| `README.md` | **항상** — 날짜별 표에서 그날 행의 요약을 갱신(새 날짜면 맨 위에 추가) |

## 4. 커밋

⚠️ **PowerShell 5.1에서 `git commit -m "..."`에 큰따옴표가 섞이면 인자가 다시 쪼개져
`pathspec ... did not match`로 실패한다.** 한글 여러 줄 메시지는 반드시 UTF-8 파일로 넘긴다:

```powershell
$msg = @'
<타입>: <한 줄 요약>

<무엇을 왜 바꿨는지. 파일별로 나눠서>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
'@
$path = "$env:TEMP\claude-commit-msg.txt"
[System.IO.File]::WriteAllText($path, $msg, (New-Object System.Text.UTF8Encoding($false)))
cd C:\terraform
git config i18n.commitEncoding utf-8
git add <바뀐 파일들>
git commit -F $path
```

- `git add -A`보다 **바뀐 파일을 명시**하는 편이 안전하다.
- 커밋 타입: `fix:` `feat:` `chore:` `docs:` — 기존 이력의 관례를 따른다.
- 메시지는 한국어로 쓴다.

## 5. push 전 안전 점검

```powershell
cd C:\terraform
git diff --cached --name-only | Select-String -Pattern "\.terraform/|tfstate|tfplan|-params\.json|\.pem$|\.key$"
git diff --cached --name-only | ForEach-Object { if (Test-Path $_) { Select-String -Path $_ -Pattern "ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH|PRIVATE)|discord\.com/api/webhooks/" } }
```

둘 다 결과가 비어야 한다. 걸리면 **push하지 말고** 사용자에게 알린다.

## 6. push

```powershell
cd C:\terraform
git push
git log --oneline -2
git status --short --branch
```

## 마무리 보고

무엇을 기록했고 어느 문서가 갱신됐는지, 커밋 해시와 함께 요약한다.
서비스 상태가 바뀐 작업이었다면 사이트 동작 확인 결과도 같이 보고한다.
