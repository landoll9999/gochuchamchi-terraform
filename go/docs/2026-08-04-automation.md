# 2026-08-04 작업 기록 (자동화)

> 같은 날의 다른 작업: 제로트러스트 DB 하드닝은 `2026-08-04.md`,
> 하드코딩·보안 재점검과 full-HA 복원은 `2026-08-04-incident-and-review.md`.
> 이 문서는 그 다음 세션에서 넣은 **자동화 3종**의 기록이다.

## 1. 배포 파이프라인 자동화 3종 (계약 검증 · 스모크 테스트 · 수동 변경 감지)

### 작업 목적

지금까지 겪은 장애를 원인별로 세어보면 결론이 하나로 모인다.

| 날짜 | 장애 | 진짜 원인 |
|---|---|---|
| 8/3 | 회원가입 500 | `schema.sql`이 실행 안 됐는데 프로비저너가 Status를 안 봐서 **terraform이 성공으로 기록** |
| 8/3 | 사이트 503 | ECR이 비어 ImagePullBackOff — **apply는 성공** |
| 8/4 | 사이트 503 | PAT 미주입으로 ArgoCD가 저장소에 못 붙음 — **apply는 성공** |
| 8/4 | 앱 전체 500 | NetworkPolicy DNS 결함 — **apply는 성공** |
| 8/4 | 이중 잠김 | terraform은 Secret 이름을 바꿨는데 gitops는 옛 이름 참조 — **apply는 성공** |

공통점은 **"terraform apply 성공"이 "서비스 정상"을 전혀 보장하지 않는다**는 것이고,
그 간극을 사람이 매번 손으로 메우고 있었다는 것이다. 8/4 회고에 적어둔 교훈
("체크리스트가 문서에 있어도 강제 장치가 없으면 누락된다")을 코드로 옮기는 작업.

CI/CD(GitHub Actions)부터 하지 않은 이유는 §5에.

### 문제가 발생한 지점 (자동화 이전 상태)

1. **두 저장소 사이의 인터페이스가 사람 머릿속에만 있었다.**
   terraform이 만드는 Secret/ConfigMap 이름과 gitops가 참조하는 이름은 계약인데,
   어디에도 명시돼 있지 않아 한쪽만 바꿔도 아무도 못 막았다.
2. **apply 후 검증이 전부 수동이었다.** runbook에 명령어는 있지만 실행은 사람 몫.
3. **Terraform 밖에서 인프라가 바뀌어도 알 방법이 없었다.** 다음 apply 때
   "왜 이게 되돌아갔지"로 만나는 구조.

### 해결 방법 — 파일별 변경 내역

**`terraform/contract.tf` (신규)** — 배포 계약을 코드로 선언

- `output "deployment_contract"` 하나로 terraform↔gitops 인터페이스를 명시:
  네임스페이스, ServiceAccount, ConfigMap 이름·키, Secret 이름·키, Service 이름/포트,
  파드 라벨(NetworkPolicy selector와 동일해야 함), 컨테이너 포트, 엔드포인트.
- **`forbidden_refs`** — 삭제된 이름(`gochuchamchi-db-secret`)을 명시적으로 기록.
  "지웠다"는 사실을 코드에 남기지 않으면 다음 사람이 옛 문서를 보고 되살린다.
- 값(비밀)은 절대 넣지 않는다 — 넣으면 db-zero-trust/eso로 없앤 state 노출이 부활.
  `kubernetes_secret_v1.data`는 provider가 sensitive로 표시하므로 `keys()`로 뽑으면
  output 자체가 거부된다 → secrets의 키는 의도적으로 문자열 리터럴.

**`scripts/verify-contract.ps1` (신규)** — 계약 검증, 두 방향

- *정적*: gitops YAML을 스캔해 `secretRef`/`configMapRef`/`secretKeyRef`/`configMapKeyRef`가
  참조하는 이름을 전부 수집 → 계약에 없으면 FAIL, 금지 이름이면 FAIL,
  계약에 있는데 아무도 안 쓰면 WARN. 블록 스타일과 인라인 플로우(`{name: x}`) 모두 대응.
- *정적*: `kustomization.yaml`의 `resources`에 등재되지 않은 매니페스트 적발
  → **8/4 §4.5 "고친 파일이 kustomize resources에 없어서 반영 안 됨" 재발 방지.**
- *정적*: Service 이름·파드 라벨 — 이건 방향이 반대인 계약(terraform이 gitops를 참조).
  Service 이름이 어긋나면 ALB 타겟 미등록(503), 라벨이 어긋나면 NetworkPolicy가
  아무 파드에도 안 걸려 default-deny만 남는다.
- *라이브*: 클러스터에 Secret/ConfigMap이 실제로 있고 키까지 맞는지, 그리고 배포된
  Deployment가 참조하는 이름이 전부 해석되는지. `gochuchamchi-db-app`은 배스천이
  런타임에 만드는 Secret이라 **"apply 성공"이 존재를 보장하지 않는다** — 실측이 필수.

**`scripts/smoke-test.ps1` (신규)** — 12개 검사

| # | 검사 | 대응 사고 |
|---|---|---|
| 2 | kubectl 컨텍스트가 지금 클러스터인가 | 8/3 옛 클러스터 kubeconfig(`no such host`) |
| 3 | 노드 Ready 수 | 노드그룹 롤링 실패 |
| 4 | 배포 계약(위 스크립트 위임) | 8/4 CreateContainerConfigError |
| 5 | 파드 상태 + waiting reason | 8/3 ImagePullBackOff(빈 ECR) |
| 6 | ExternalSecret Ready | 8/4 PAT 미주입 → 앱 미배포 |
| 7 | ArgoCD Application Synced/Healthy | GitOps 동기화 실패 |
| 8 | 파드에서 DNS 해석(`getent hosts <RDS>`) | 8/4 NetworkPolicy DNS 전면 차단 |
| 9 | 파드에서 3306/6379 TCP 도달 | SG·netpol 회귀 |
| 10 | Ingress ALB 주소 할당 | LB 컨트롤러 실패 |
| 11 | `/` 200, `/api/health` 302 | 사용자 관점 최종 확인 |
| 12 | ALB 타겟 헬스 | 파드는 Running인데 타겟 unhealthy인 구간 |

실패 항목마다 **다음 행동**을 같이 출력한다(예: DNS 실패 → 서비스 CIDR 확인 +
`kubectl -n gochuchamchi delete netpol --all` 롤백 한 줄).

**`terraform/smoke-test.tf` (신규)** — apply 파이프라인에 편입

- `null_resource.post_apply_smoke_test`가 apply마다 위 스크립트를 실행.
  계약 JSON을 **인자로** 넘긴다 — apply 도중에는 state가 확정 전이라 스크립트가
  `terraform output`을 호출하면 옛 값을 읽거나 실패하기 때문.
- **기본은 경고 모드**(`smoke_test_enforce = false`). 재구축 직후에는 PAT 수동 주입
  전이라 앱이 안 떠 있는 게 정상이고, 여기서 apply를 실패시키면 재구축 자체가 막힌다.
  정상 가동 중 변경 apply에서는 `$env:TF_VAR_smoke_test_enforce = "true"`로 올려서
  "서비스를 깨는 apply는 실패로 기록"되게 하는 것이 목표 상태.

**`cloudwatch-notifications/drift-detection.tf` (신규)** — 수동 변경 감지 3룰

- `gochuchamchi-console-mutation` — CloudTrail의 `sessionCredentialFromConsole=true` +
  `readOnly=false`. **사람이 브라우저에서 클릭한 변경만** 잡힌다. Terraform·CLI·
  클러스터 컨트롤러(ALB controller, ExternalDNS)는 이 필드가 없어 자동으로 걸러지므로
  제외 목록 없이도 노이즈가 거의 없다.
- `gochuchamchi-iam-mutation` — `aws.iam` 비읽기 호출 중 **Terraform 실행 주체를 제외**한
  전부(`anything-but` + `data.aws_caller_identity.current.arn`). 이걸 제외 안 하면
  apply마다 수십 건이 울린다.
- `gochuchamchi-root-activity` — 루트 계정 사용(로그인 포함). MFA 강제 그룹으로도
  통제 못 하는 유일한 주체라, 쓰였다는 사실 자체가 신호.

**`cloudwatch-notifications/sns.tf`** — 토픽 정책의 `ArnEquals`를 룰 4개 목록으로 확장.
등록 안 하면 **룰 지표는 정상인데 알림만 안 오는** 디버깅 어려운 상태가 된다(주석으로 명시).

**`cloudwatch-notifications/lambda_function.py`** — `detail-type`으로 분기.
CloudTrail 이벤트를 알람 포맷으로 그리면 "알 수 없는 Alarm / UNKNOWN"만 찍히므로
전용 임베드(주체·출발지 IP·요청 파라미터 + "의도한 변경이면 코드에 반영하라"는 행동 지침) 추가.
`input_transformer`로 예쁜 문자열을 만들지 않은 이유: 같은 토픽을 구독하는 Lambda가
받는 Message가 JSON이 아니게 되어 `json.loads`에서 터지고 → SNS 재시도 → DLQ로 간다.

### 검증 완료 사항

이 세션(클라우드)에서 실제로 실행한 것:

- **HCL 파싱** — 신규/수정 `.tf` 4개 전부 구문 통과(hcl2).
- **Python 구문** — `lambda_function.py` 통과.
- **PowerShell 파서** — 두 스크립트 모두 `[Parser]::ParseFile` 오류 0건.
  (초기 버전에서 배열 스플래팅 `& $script @배열`이 위치 인자로 해석돼 파라미터
  바인딩이 깨지는 버그를 발견 → 해시테이블 스플래팅으로 수정)
- **기능 테스트** — 가짜 gitops 저장소 2벌(정상/8-4 장애 재현)과 가짜 `kubectl`로
  end-to-end 실행:
  - 장애 재현본 → `gochuchamchi-db-secret` 참조 FAIL, kustomize 미등재 FAIL,
    파드 `CreateContainerConfigError` FAIL(+ "#4 이름 불일치" 힌트),
    ExternalSecret 미동기 FAIL. **enforce 모드 종료코드 1** 확인.
  - 정상본 → 13개 검사 전부 PASS, 종료코드 0.
  - 경고 모드에서는 실패가 있어도 종료코드 0 확인(재구축을 막지 않음).

로컬에서 해야 할 검증(이 환경에선 불가 — hashicorp 배포 서버 차단):

```powershell
cd go\terraform
terraform init          # 신규 리소스 없음(null_resource/output만) — 그래도 1회 권장
terraform validate
terraform plan          # post_apply_smoke_test가 매번 1개 변경으로 뜨는 게 정상

cd ..\cloudwatch-notifications
terraform init
terraform plan          # EventBridge 룰 3개 + 타겟 3개 create, 토픽 정책/Lambda update
```

apply 후:

```powershell
# 계약만 단독 검증 (gitops 클론 경로 지정)
go\scripts\verify-contract.ps1 -GitopsPath <gochuchamchi-gitops 경로>

# 전체 스모크 테스트 수동 실행
go\scripts\smoke-test.ps1

# 드리프트 감지 실전 테스트: 콘솔에서 아무 SG에 태그 하나 추가 -> Discord 알림 확인 -> 태그 삭제
```

### 트레이드오프 / 알려진 한계

| 항목 | 한계 | 판단 |
|---|---|---|
| 스모크 테스트가 매 apply마다 실행 | plan에 항상 1개 변경으로 뜬다 | 스모크 테스트는 "코드가 바뀔 때"가 아니라 "인프라를 건드릴 때마다" 돌아야 의미가 있음 → 감수 |
| 경고 모드가 기본 | 실패해도 apply가 통과 | 재구축 시나리오를 막지 않기 위함. 정상 가동 중에는 enforce로 올리는 게 목표 |
| 수동 변경 감지가 콘솔 한정 | CLI/SDK로 낸 수동 변경은 못 잡음 | 완전 커버는 `terraform plan` 기반이 필요하고 그건 러너 결정이 선행(§5) |
| 계약 정적 검증이 정규식 기반 | 아주 특이한 YAML 형식은 놓칠 수 있음 | 라이브 검증이 2차 방어. Helm 템플릿 gitops로 가면 재설계 필요 |
| 이메일 구독자는 원본 JSON 수신 | 읽기 불편 | Discord가 사람이 읽는 채널, 이메일은 "파이프라인 고장" 백업 경로라는 원래 역할대로 |

### 면접 설명 (한 줄)

> "장애 5건을 사후 분석해보니 전부 'apply는 성공했는데 서비스는 죽어 있는' 유형이었고,
> 공통 원인은 절차가 문서에만 있고 강제 장치가 없다는 것이었습니다. 그래서 두 저장소
> 사이의 인터페이스를 Terraform output으로 선언해 계약으로 만들고(삭제된 이름까지
> 금지 목록으로 명시), apply 파이프라인 안에서 계약 일치·DNS·TCP·ALB 타겟·HTTP까지
> 12개를 자동 검증하게 했습니다. 재구축을 막지 않으려고 기본은 경고 모드로 두고
> 운영 상태에서는 강제 모드로 올리는 구조입니다. 드리프트는 CloudTrail의
> 콘솔 세션 플래그로 '사람이 콘솔에서 만진 변경'만 골라 알림을 붙였는데, 이건
> EKS 엔드포인트를 /32로 잠가둔 탓에 CI 러너에서 terraform plan을 못 돌리는 제약을
> 우회한 선택이고, self-hosted runner를 붙이면 plan 기반 감지를 추가할 계획입니다."

### 남은 작업 (러너 결정 대기)

- [ ] **러너 방식 결정** — EKS 퍼블릭 엔드포인트가 `/32` 허용목록이라 GitHub 호스티드
      러너는 `kubernetes`/`helm` 프로바이더 refresh에서 타임아웃. 선택지는
      (a) CI는 lint/보안스캔/계약 정적검증까지만 + apply는 로컬,
      (b) 배스천에 self-hosted runner. **이 결정 전에는 아래 3개가 진행 불가.**
- [ ] Terraform CI — PR에 `fmt/validate/tflint/checkov` + `plan` 코멘트, main 머지 시 승인 후 apply.
      OIDC provider는 `ecr.tf`에 이미 있으므로 plan용(ReadOnly)·apply용 역할 2개만 추가
- [ ] `plan -detailed-exitcode` 기반 드리프트(하루 1회) → 지금의 이벤트 감지와 보완 관계
- [ ] gitops PR에서 계약 검증 실행(현재는 수동/apply 시점) — 진짜 "머지 차단"은 여기서 완성
- [ ] 이미지 태그 자동화 — gitops kustomize화 + CI가 태그 커밋 → ArgoCD PAT를 read-only로
      강등 + ECR IMMUTABLE 전환 가능 (백로그 2건 동시 해소)
- [ ] 야간·주말 노드그룹 스케일다운(EventBridge Scheduler) — 비용 절감, ArgoCD/ESO 기동 순서 설계 필요
