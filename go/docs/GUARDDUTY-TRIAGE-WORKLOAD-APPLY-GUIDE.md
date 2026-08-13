# Workload 계정 — GuardDuty AI 트리아지 적용 가이드

대상 계정은 **Workload `828885965304`**, 프로파일은 `workload-admin`이다.
브랜치는 `feat/guardduty-triage`. 다른 계정 담당자의 선행 작업은 없다.

## 무엇이 바뀌나

GuardDuty finding이 SNS로 직행하던 통보 경로 사이에 **판정 Lambda**가 들어간다.

```
전:  GuardDuty finding → EventBridge → SNS 허브 → Discord/이메일
후:  GuardDuty finding → EventBridge → 트리아지 Lambda → SNS 허브 → Discord/이메일
                                        (필터 → Groq 판정 → 정책 표)
```

**EC2 자동 격리 경로는 건드리지 않는다.** 별도 EventBridge 룰이 격리 Lambda를
직접 호출하는 구조 그대로다 — 대응이 모델 지연·장애에 걸리면 안 되기 때문이다.

상세 설계는 [2026-08-13-guardduty-triage.md](2026-08-13-guardduty-triage.md).

---

## 0. 사전 준비 — Groq 계정과 모델 검증

**이 단계를 건너뛰면 안 된다.** 모델 ID가 틀리면 모든 판정이 조용히 "판정 없음"이
되는데 **알림은 계속 오므로 고장난 줄 모른 채 몇 주가 갈 수 있다.**

1. `console.groq.com` 가입 → API Keys에서 키 발급 (`gsk_`로 시작). 무료 티어로 충분하다.
2. apply 전에 키·모델을 검증한다:

```powershell
cd C:\terraform\go\cloudwatch-notifications\triage
$env:GROQ_API_KEY = "gsk_실제키"
python check-groq.py
```

설치할 것은 없다. Groq은 HTTP API이고 판정 코드는 파이썬 표준 라이브러리만 쓴다.

스크립트가 키 유효성 → 사용 가능한 모델 목록 → 대상 모델 존재 여부 → **실제 판정
1건**을 순서대로 확인한다. 표본에 프롬프트 인젝션 문자열을 심어 두었으므로 방어도
같이 검증된다.

- `[통과]`가 나오면 다음 단계로 간다.
- 목록에 `openai/gpt-oss-120b`가 없으면 목록에서 하나 고르고, 아래 apply 때
  `$env:TF_VAR_triage_groq_model`로 지정한다.
- 판정이 `FALSE_POSITIVE`로 나오면 **인젝션 방어에 실패한 것**이니 다른 모델을 쓴다.

---

## 1. 브랜치 가져오기

```powershell
cd C:\terraform
git fetch origin
git switch feat/guardduty-triage
git pull
```

이미 main에 병합됐다면 `git switch main; git pull origin main`으로 대체한다.

---

## 2. 자격증명

```powershell
aws sso login --profile workload-admin
aws sts get-caller-identity --profile workload-admin
```

`Account`가 반드시 `828885965304`인지 확인한다.

> **`workload-admin` 프로파일이 없다면** (`failed to get shared config profile` 오류)
> 아래로 만든 뒤 다시 로그인한다. Identity Center SSO 방식이다.
>
> ```powershell
> aws configure set sso_session gochuchamchi --profile workload-admin
> aws configure set sso_account_id 828885965304 --profile workload-admin
> aws configure set sso_role_name AdministratorAccess --profile workload-admin
> aws configure set region ap-northeast-2 --profile workload-admin
> ```
>
> `sso-session gochuchamchi`가 `~/.aws/config`에 없으면 시작 URL은
> `https://d-9b675b2050.awsapps.com/start`, 리전은 `ap-northeast-2`다.
> 권한 세트 이름이 `AdministratorAccess`가 아니면 SSO 포털에서 실제 이름을 확인한다.

---

## 3. 적용

```powershell
cd go\cloudwatch-notifications
terraform init -reconfigure
terraform fmt -check
terraform validate
terraform plan -out guardduty-triage.tfplan
terraform show guardduty-triage.tfplan
terraform apply guardduty-triage.tfplan
```

`hashicorp/archive` 프로바이더가 새로 필요해 `init`이 필수다.

0단계에서 다른 모델을 골랐다면 `plan` **앞에**:

```powershell
$env:TF_VAR_triage_groq_model = "고른 모델 ID"
```

### 정상 plan의 모양

이번 변경의 핵심은 **약 11개 추가 + 1개 삭제 + 1개 변경**이다.

| | 무엇 |
|---|---|
| 추가 | `aws_lambda_function.triage`, `aws_iam_role.triage`, IAM 정책 2, 역할 연결 1, `aws_dynamodb_table.triage_state`, `aws_secretsmanager_secret.triage_groq_api_key`, `aws_cloudwatch_log_group.triage`, `aws_cloudwatch_event_target.triage`, `aws_lambda_permission.triage_from_events`, `aws_cloudwatch_metric_alarm.triage_errors` |
| **삭제** | `aws_cloudwatch_event_target.guardduty_sns` ← **정상이다.** 통보 경로가 SNS 직결에서 트리아지 경유로 바뀌는 것 |
| 변경 | `aws_lambda_function.cloudwatch_discord` ← Discord 렌더러에 트리아지 표시가 추가돼 코드 해시가 바뀐다 |

**그 외의 삭제·교체가 보이면 중단하고 공유한다.** 특히 `guardduty_isolation`
(격리 Lambda)이나 `aws_sns_topic.alerts`에 변경이 잡히면 이번 변경 범위가 아니다.

> state가 main보다 뒤처져 있으면 위 목록 외에 **이전 커밋의 미적용 변경도 같이
> 들어간다.** plan 내용을 그대로 받아들이지 말고 한 번 훑을 것.

---

## 4. ⚠️ apply 후 필수 — Groq 키 주입

Terraform은 시크릿 **그릇만** 만든다. 값을 variable로 받으면 tfstate에 평문으로
남기 때문이다.

```powershell
aws secretsmanager put-secret-value `
  --secret-id gochuchamchi/triage/groq-api-key `
  --secret-string '{\"api_key\":\"gsk_실제키\"}' `
  --region ap-northeast-2 --profile workload-admin
```

주입하지 않아도 **알림은 정상 동작한다** — 모든 finding이 "판정 없음"으로 통보될
뿐이고 탐지 공백은 생기지 않는다.

---

## 5. 확인

```powershell
cd C:\terraform\go\cloudwatch-notifications\triage
.\verify-deployment.ps1
```

스크립트가 순서대로 확인한다:

1. EventBridge 타겟이 SNS 직결이 아니라 트리아지 Lambda인가
2. Groq 시크릿에 값이 들어갔는가 (값 자체는 출력하지 않는다)
3. 정책 표 6개 조합이 기대한 액션을 내는가
4. 중복 억제가 걸리는가

**진짜 Discord 알림이 4건 간다.** 그걸 눈으로 확인하는 것이 목적이다.

### Discord에서 볼 것

| 확인 | 정상 |
|---|---|
| **루트 사용 건의 등급** | `HIGH` — severity는 2인데 HIGH로 떠야 한다. `LOW`로 뜨거나 알림이 아예 없으면 티어 승격이 안 된 것이다 |
| 판정 출처 | `모델 판정 (모델명)`. `판정 없음`이면 그 사유가 같이 찍힌다 |
| 색/아이콘 | 🚨 긴급=빨강, 🟡 검토=노랑, ⚪ 오탐 의심=회색 |

### 실제 finding으로 한 번 더

검증 스크립트는 Lambda를 직접 부르므로 EventBridge 필터를 안 거친다. 배선 전체를
보려면 실제 샘플 finding을 쏜다.

```powershell
$detectorId = terraform -chdir=..\..\account-baseline output -raw guardduty_detector_id
aws guardduty create-sample-findings `
  --detector-id $detectorId `
  --finding-types "CryptoCurrency:EC2/BitcoinTool.B!DNS" `
  --region ap-northeast-2 --profile workload-admin
```

### 로그 / 지표

```powershell
aws logs tail /aws/lambda/gochuchamchi-guardduty-triage --since 15m `
  --region ap-northeast-2 --profile workload-admin
```

`triage_result`로 시작하는 JSON 한 줄에 **통보 여부와 무관하게** 판정 전체가
남는다(판정·확신·위험도·근거·모델명·토큰수). Discord 메시지가 지워져도 여기서
되짚을 수 있다.

지표는 CloudWatch > Metrics > `Gochuchamchi/Triage`.
특히 **`Suppressed`가 크면 AI가 알림을 너무 많이 없애고 있다는 뜻**이므로
정책 표나 `triage_suppress_min_confidence`를 조인다.

---

## 6. 롤백

```powershell
$env:TF_VAR_enable_triage = "false"
terraform apply
```

EventBridge 타겟이 SNS 직결로 되돌아간다. **알림이 끊기는 구간은 없다** — 판정만
없어진다.

판정만 떼고 배선은 두려면 `$env:TF_VAR_triage_judge_enabled = "false"`.
이 경우 모든 finding이 UNCERTAIN으로 처리돼 정책 표대로 통보된다(소음은 늘지만
탐지 공백은 없다).

> **EventBridge 룰을 콘솔에서 disable하지 말 것.** 룰을 끄면 통보 경로 전체가
> 죽고, 다음 apply 때 되살아난다.

---

## 7. 첫 주 튜닝

1. **`triage/context.md`의 빈 항목 5개를 채운다** — 관리자 IP 대역,
   daily-up/down UTC 시각, 정상 외부 엔드포인트, 사람 IAM 사용자 목록, NAT 공인 IP.
   판정 정확도의 대부분이 여기서 나온다. 비어 있으면 모델이 "모르겠으니
   UNCERTAIN"으로 올려 알림이 시끄러워진다.
2. 같은 타입이 계속 UNCERTAIN이면 **조건문을 늘리지 말고** `context.md`에 그
   패턴을 정상/비정상으로 명시한다.
3. 완전한 소음 타입은 `guardduty_notify_noise_types`로 올린다 — EventBridge에서
   걸리면 Lambda 호출조차 없다.
