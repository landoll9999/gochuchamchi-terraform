# GuardDuty AI 트리아지 — 구현 및 배포 런북

**작성일** 2026-08-13 · **대상 스택** `go/cloudwatch-notifications` (Workload `828885965304`) · **상태** 코드 완료, `terraform validate` 통과, **apply 전**

---

## 1. 무엇을 만들었나

로그 담당자가 요구한 구조를 그대로 구현했다.

```
GuardDuty finding
   │
   ├─ Rule 1 (타입/severity 필터) ─→ [트리아지 Lambda] ─→ SNS 허브 ─→ Discord/이메일
   │                                   │ 1. 기본 필터링
   │                                   │ 2. Groq 판정
   │                                   │ 3. 정책 표
   │
   └─ Rule 2 (severity >= 7) ──────→ [격리 Lambda]  ← AI를 기다리지 않는다
```

**필터와 판단은 층이 다르다.** Rule 1의 이벤트 패턴이 "무엇을 볼지"를
EventBridge에서 공짜로 정하고(걸리면 Lambda 호출조차 없다), 트리아지는 살아남은
것에 대해서만 "그중 무엇이 진짜인지"를 붙인다. 소음 제거를 모델에 시키면 그게
곧 토큰 낭비다.

**두 경로는 서로를 모른다.** 대응(격리)이 모델 지연·장애·오판에 걸리면 안 되므로
이번 변경은 통보 경로에만 끼어들었다.

### 왜 Bedrock이 아니라 Groq인가

개인 프로젝트 규모라 Bedrock 종량 비용을 감당할 여유가 없다는 판단.
`gpt-oss-120b` 기준 finding 1건 판정이 약 **$0.0006**이고, 캐시·상한까지 걸어 두면
월 $1을 넘기기 어렵다. (파기한 Bedrock Opus 5 구성은 월 $75 추정이었다.)

대가는 둘이고 각각 코드에서 막았다:

| 대가 | 방어 |
|---|---|
| API 키가 생긴다 | Secrets Manager에 **수동 주입** — tfstate에 안 들어간다 |
| 데이터가 AWS 밖으로 나간다 | 화이트리스트 투영 + 계정ID/사설IP/이메일 **가명화** |

---

## 2. 정책 표

`triage_policy_matrix` 변수다. **코드 배포 없이 tfvars만 고쳐 정책을 바꿀 수 있다.**

| 심각도 | TRUE_POSITIVE | UNCERTAIN | FALSE_POSITIVE |
|---|---|---|---|
| **CRITICAL** | 🚨 긴급 | 🚨 긴급 | 🚨 긴급 (AI 무관) |
| **HIGH** | 🚨 긴급 | 🟡 검토 필요 | ⚪ 오탐 의심 (알림은 감) |
| **MEDIUM** | 🔴 알림 | 🟡 검토 | 🔇 **억제** |
| **LOW** | 🔴 알림 | 📦 저장만 | 📦 저장만 |

### 2-1. ⚠️ 티어는 severity만으로 정하지 않는다 — 이게 가장 중요한 설정이다

EventBridge 룰 (A) 갈래는 루트 사용·자격증명 탈취 같은 타입을 **severity와 무관하게**
통과시킨다. 그런데 [2026-08-12-ai-triage.md](2026-08-12-ai-triage.md) §5에 이렇게
적혀 있다:

> 실제로 이 환경의 finding은 전부 severity 2였다.

**티어를 severity로만 정하면 가장 중요한 finding이 전부 LOW로 떨어져 판정도 못 받고
저장만 된다.** 그래서 `guardduty_always_notify_type_prefixes`에 걸리는 타입은
최소 `triage_type_prefix_min_tier`(기본 HIGH)로 올린다.

검증 결과:

| finding | severity | 순수 티어 | 실제 티어 |
|---|---|---|---|
| `Policy:IAMUser/RootCredentialUsage` | 2.0 | LOW | **HIGH** ← 승격 |
| `CredentialAccess:IAMUser/AnomalousBehavior` | 2.0 | LOW | **HIGH** ← 승격 |
| `Recon:EC2/PortProbeUnprotectedPort` | 2.0 | LOW | LOW |
| `Backdoor:EC2/C&CActivity.B` | 8.0 | HIGH | HIGH |

### 2-2. 억제에는 confidence 하한을 걸었다 (스펙 보강)

원래 스펙에는 없었다. **MEDIUM × FALSE_POSITIVE는 이 표에서 알림이 사라지는
유일한 칸**이고, 곧 미탐이 생길 수 있는 유일한 자리다. 하한이 없으면 모델이
확신 0.3으로 FALSE_POSITIVE를 뱉어도 그대로 묻힌다. `confidence`를 스키마에 넣어
놓고 정책에서 안 쓰면 그 필드는 장식이다.

`triage_suppress_min_confidence`(기본 0.7) 미만이면 **UNCERTAIN으로 강등**해
"검토"로 보내고, Discord에 "판정 강등됨"을 명시한다.

### 2-3. LOW의 "저장"은 이미 되고 있다

새로 만든 저장소가 없다. GuardDuty가 finding을 **90일 보관**하고, 현재 EventBridge
룰의 (B) 갈래가 이미 `severity < 4`를 거르고 있어 Lambda까지 오지도 않는다.
여기 도착하는 LOW는 (A) 갈래(중요 타입)로 들어온 것들인데, 그건 §2-1이 HIGH로
올려 준다. 즉 **"저장만"은 알림을 안 보내는 것으로 충분하다.**

---

## 3. 추가/변경된 것

| 파일 | 내용 |
|---|---|
| `cloudwatch-notifications/triage.tf` | Lambda·IAM·DynamoDB·Groq 시크릿·EventBridge 전환·알람·변수 전부 |
| `cloudwatch-notifications/triage/triage_function.py` | 필터 → 판정 → 정책 → 통보 |
| `cloudwatch-notifications/triage/policy.py` | **정책 표** (심각도 × 판정 → 액션) |
| `cloudwatch-notifications/triage/judge.py` | Groq 호출 (화이트리스트 투영·마스킹·스키마 검증) |
| `cloudwatch-notifications/triage/context.md` | **환경 설명 — 판정 정확도의 핵심** |
| `cloudwatch-notifications/triage/check-groq.py` | 배포 전 키·모델 검증 (패키지에는 안 들어감) |
| `cloudwatch-notifications/lambda_function.py` | 트리아지 렌더러 추가 |
| `cloudwatch-notifications/guardduty-response.tf` | 기존 SNS 직결 target에 `count` — 롤백 경로로 보존 |

**외부 SDK가 없다.** Groq은 HTTP API이고 `judge.py`는 표준 라이브러리 `urllib`만
쓴다. Bedrock 때 필요했던 레이어 빌드(`build-layer.ps1`)가 사라져 apply에
python/pip/PyPI 접근이 필요 없다.

### 3-1. 필터 5단 (순서대로 통과해야 모델이 호출된다)

| # | 게이트 | 어디서 | 변수 |
|---|---|---|---|
| 0 | 타입/severity 이벤트 패턴 | **EventBridge** (가장 쌈 — Lambda 호출조차 없음) | `guardduty_notify_*` |
| 1 | 테스트/점검 IP | Lambda | `triage_test_ips` |
| 2 | 중복 finding (같은 id) | Lambda + DynamoDB | `triage_dedup_hours` |
| 3 | 명확한 LOW | Lambda | `triage_skip_judge_tiers` |
| 4 | 판정 캐시 (타입 × 리소스) | Lambda + DynamoDB | `triage_verdict_cache_hours` |
| 5 | 일일 호출 상한 | Lambda + DynamoDB | `triage_daily_call_limit` |

---

## 4. 안전장치

**① AI에게 억제 권한이 없다.** finding 원본은 GuardDuty에 그대로 남고, 바뀌는 건
Discord 알림의 우선순위와 설명뿐이다. 알림이 사라지는 칸은 표에서 하나뿐이고
그것도 confidence 하한을 통과해야 한다.

**② 판정 실패는 침묵이 아니다.** Groq 장애·타임아웃·한도 초과·스키마 위반·키
미주입 — 어느 경로로 빠져도 `verdict=None`이 되고 정책 엔진이 UNCERTAIN으로
처리해 알림을 낸다. Discord "판정 출처" 필드에 **없는 이유가 그대로 찍힌다.**
Lambda 자체가 죽는 경우도 `dead_letter_config`로 기존 알림 DLQ에 적재된다.

**③ 프롬프트 인젝션.** finding 필드는 공격자가 값을 정할 수 있다(인스턴스 태그,
User-Agent, 버킷 이름).
(a) 화이트리스트 투영으로 모델이 보는 필드를 제한하고,
(b) `<finding>` 델리미터로 데이터임을 명시하고,
(c) 구조화 출력으로 스키마를 강제하며 계약 위반 출력은 **고쳐 쓰지 않고 폐기**하고,
(d) **인젝션이 감지되면 FALSE_POSITIVE 판정을 자동으로 무효화**한다 —
공격자가 얻으려는 게 정확히 그 판정이기 때문이다.

**④ 대응 경로와 분리.** EC2 격리는 별도 EventBridge 룰이 Lambda를 직접 호출한다.
이 스택이 죽어도 격리는 돈다.

**⑤ 자기 감시.** 트리아지가 죽으면 GuardDuty 통보 경로 전체가 조용해진다(타겟이
이쪽이므로). Lambda `Errors` 알람이 SNS 허브로 발행된다.

---

## 5. 배포 절차

### 5-1. ⚠️ 먼저: Groq 키·모델 검증

Groq은 **설치할 것이 없다.** 계정과 API 키만 있으면 된다.

1. `console.groq.com` 가입 → API Keys에서 키 생성 (`gsk_`로 시작)
2. apply 전에 검증:

```powershell
cd C:\terraform\go\cloudwatch-notifications\triage
$env:GROQ_API_KEY = "gsk_..."
python check-groq.py
```

스크립트가 키 유효성 → 사용 가능한 모델 목록 → 대상 모델 존재 확인 → **실제
`judge.py`를 그대로 태워** 판정 한 건을 받아 본다. 표본에 프롬프트 인젝션
문자열을 심어 두었으므로 방어까지 같이 확인된다.

> `triage_groq_model` 기본값은 `openai/gpt-oss-120b`다. **모델 목록은 수시로
> 바뀐다.** 없는 모델이면 모든 판정이 "판정 없음"이 되는데 **알림은 계속 나오므로
> 고장난 줄 모른 채 몇 주가 갈 수 있다.** 이 스크립트가 막으려는 게 그것이다.

### 5-2. apply

```powershell
cd C:\terraform\go\cloudwatch-notifications
terraform init
terraform plan
terraform apply
```

`hashicorp/archive` 프로바이더가 새로 필요해 `init`이 필수다.

plan에서 **`aws_cloudwatch_event_target.guardduty_sns`가 삭제되고
`aws_cloudwatch_event_target.triage`가 생성되는 것이 정상**이다 — 통보 경로가
SNS 직결에서 트리아지 경유로 바뀌는 것이다.

### 5-3. ⚠️ apply 후: Groq 키 주입

```powershell
aws secretsmanager put-secret-value `
  --secret-id gochuchamchi/triage/groq-api-key `
  --secret-string '{\"api_key\":\"gsk_...\"}' `
  --region ap-northeast-2 --profile workload-admin
```

안 넣어도 **알림은 정상 동작한다** — 전부 "판정 없음"이 될 뿐이다.

### 5-4. 첫 호출 검증

```powershell
# Rule 1의 (A) 갈래에 걸리는 타입을 골라야 필터에서 안 막힌다
aws guardduty create-sample-findings `
  --detector-id (terraform -chdir=..\account-baseline output -raw guardduty_detector_id) `
  --finding-types "CryptoCurrency:EC2/BitcoinTool.B!DNS" `
  --region ap-northeast-2 --profile workload-admin

aws logs tail /aws/lambda/gochuchamchi-guardduty-triage --follow `
  --region ap-northeast-2 --profile workload-admin
```

확인 순서:

1. **Groq 호출이 성공하는가** — 403이면 Cloudflare(User-Agent), 401이면 키,
   400이면 로그에 원인별 힌트가 찍힌다.
2. **Discord에 판정이 붙어 오는가** — 제목이 `아이콘 [액션] 제목`이고,
   "판정 출처"에 `모델 판정 (모델명)`이 찍혀야 한다.
3. **같은 finding을 한 번 더 쏴 본다** — 중복 억제로 통보가 없어야 한다.
4. **`Policy:IAMUser/RootCredentialUsage`(severity 2)를 쏴 본다** —
   `gate-severity`가 아니라 **tier=HIGH로 승격돼 판정이 붙어야 한다.**
   여기서 걸러지면 `triage_type_prefix_min_tier`가 안 먹은 것이다(§2-1).
5. **토큰/비용이 보이는가** — CloudWatch > Metrics > `Gochuchamchi/Triage`

### 5-5. 지표

| 지표 | 본다면 |
|---|---|
| `Received` (Tier) | 등급별 유입량 |
| `Filtered` (Tier) | 필터에서 걸린 수. 이게 너무 크면 필터가 과하다 |
| `Verdict` (Verdict) | TRUE_POSITIVE/UNCERTAIN/FALSE_POSITIVE 분포 |
| `Action` (Action) | urgent/alert/review/likely_fp/suppress/store 분포 |
| `Suppressed` (Tier) | AI가 없앤 알림 수. **크면 정책이 위험하다** |
| `RiskScore` (Tier) | 위험도 분포 |
| `JudgeCalls` / `JudgeCacheHit` | 캐시가 실제로 호출을 아끼는지 |
| `JudgeUnavailable` / `JudgeQuotaExceeded` | 판정이 안 붙는 이유 |
| `InjectionSuspected` (Type) | **0이 아니면 즉시 확인** |

---

## 6. 운영 튜닝 순서

1. **`context.md`의 "아직 채워지지 않은 부분"을 먼저 채운다.** 판정 정확도의
   대부분이 여기서 나온다. 비어 있으면 모델이 "모르겠으니 UNCERTAIN"으로 올려
   알림이 시끄러워진다.
2. **`Suppressed`가 크면** 정책 표를 좁히거나 `triage_suppress_min_confidence`를
   올린다 — AI가 알림을 너무 많이 없애고 있다는 뜻이다.
3. **같은 타입이 계속 UNCERTAIN이면** `context.md`에 그 패턴을 정상/비정상으로
   명시한다. 조건문을 늘리지 않는다.
4. **완전한 소음 타입은** `guardduty_notify_noise_types`(게이트 0)로 올린다 —
   EventBridge에서 걸리면 Lambda 호출조차 없다.

---

## 7. 롤백

```hcl
# terraform.tfvars
enable_triage = false        # 통보 경로를 SNS 직결로 되돌림 (알림은 안 끊김)
triage_judge_enabled = false # 판정만 떼어냄 (전부 UNCERTAIN 처리, 통보는 계속)
```

즉시 멈춰야 해도 **EventBridge 룰을 disable하지 말 것** — 룰을 끄면 통보 경로
전체가 죽는다. 위 스위치를 쓰면 알림이 끊기는 구간이 없다.

---

## 8. 남은 것

- [ ] `context.md` 빈 항목 5개 (관리자 IP 대역, daily-up/down UTC 시각, 정상 외부
      엔드포인트, 사람 IAM 사용자 목록, NAT 공인 IP)
- [ ] 며칠 운영 후 `Suppressed` / `Verdict` 분포를 보고 정책 표 조정
- [ ] Log 계정 위임(2026-08-11 handoff §4)이 끝나면 이 스택을 조직 단위로 이관
- [ ] Security Hub finding도 같은 파이프라인에 태울지 검토 (이벤트 패턴만 추가)

---

## 참고

- [2026-08-12-ai-triage.md](2026-08-12-ai-triage.md) — 파기된 Bedrock 판(§5의 함정이 여기 §2-1의 근거)
- [2026-08-11-log-account-handoff.md](2026-08-11-log-account-handoff.md) §5 — 원래 설계 의도
- `cloudwatch-notifications/triage/context.md` — **인프라가 바뀌면 코드가 아니라 이 문서를 고친다**
