# gochuchamchi 테라폼 전체 해설서

> 기준: `gochuchamchi-terraform-git` 저장소, 브랜치 `feat/detection-and-auto-response`, HEAD `9a967bb` (2026-08-14).
> 범위: 저장소의 **모든 `.tf` 파일 135개, 약 20,800줄**(외부 registry 모듈 캐시 `.terraform/`은 제외). 파일마다 블록 단위로 실제 라인 범위를 달아 설명한다. 닫는 괄호 같은 문법 줄은 블록에 묶어 다루며, 의미를 갖는 인자는 하나도 건너뛰지 않는 것을 원칙으로 했다.

---

## 1. 이 프로젝트가 무엇인가

gochuchamchi는 상품 이미지를 다루는 Spring 웹 애플리케이션을 **AWS 3계정 분리 구조** 위에 올린 팀 프로젝트다. 코드는 크게 세 저장소로 나뉜다.

| 저장소 | 역할 |
|---|---|
| `gochuchamchi-terraform` (이 문서의 대상) | AWS 인프라 전체 — 계정·네트워크·EKS·RDS·CloudFront·보안·관측 |
| `gochuchamchi-spring` | 애플리케이션 코드. GitHub Actions CI가 이미지를 빌드·서명해 ECR로 push |
| `gochuchamchi-gitops` | K8s 매니페스트. ArgoCD가 이걸 보고 클러스터를 동기화 |

서비스 도메인은 `kycj.click`이고, 요청 경로는 다음과 같다:

```
사용자 → Route53 → CloudFront(+WAF, us-east-1) → ALB(Origin 검증 헤더 검사) → EKS 파드(Spring) → RDS MariaDB(IAM 토큰 인증) / ElastiCache Redis / S3(이미지)
```

## 2. 3계정 구조 — 왜 계정을 쪼갰나

AWS Organizations로 계정을 셋으로 나눴다. 한 계정이 뚫려도 다른 계정의 로그·조직 설정은 건드릴 수 없게 하는 **폭발 반경(blast radius) 제한**이 목적이다.

| 계정 | 담당 루트 | 역할 |
|---|---|---|
| **Management** | `management/organization`, `management/audit` | Organizations 루트. Identity Center(SSO)로 사람 접근 관리, SCP로 전 계정 가드레일, org trail(CloudTrail) 운영 |
| **Log** | `log-archive` | 로그 전용 계정. Workload의 로그를 크로스계정 Firehose로 받아 S3에 아카이브, Athena로 분석, 자체 SIEM 탐지까지 |
| **Workload** (828885965304) | 나머지 전부 | 실제 서비스가 도는 계정. 이 문서 독자(사용자)의 담당 |

로그를 별도 계정에 두는 이유: 공격자가 Workload를 장악해도 **자기 흔적(로그)을 지울 수 없다**. 로그 버킷·KMS 키가 다른 계정 소유이기 때문이다.

## 3. 테라폼 루트 8개 — 상시 계층과 일일 계층

이 저장소의 가장 중요한 설계는 **"매일 사라지는 것"과 "남는 것"의 분리**다. 학생 프로젝트라 EKS·RDS·NAT를 24시간 켜 둘 수 없어, 런타임 인프라는 매일 아침 만들고 저녁에 부순다. 그래서 상태(state)를 가진 것들은 전부 상시 계층으로 빼야 했고, 이 경계선이 저장소 구조 그 자체다.

| 루트 | 계정 | 계층 | 리소스 규모 | 내용 |
|---|---|---|---|---|
| `management/organization` | Management | 상시 | — | Organizations·SSO·SCP |
| `management/audit` | Management | 상시 | — | org CloudTrail |
| `log-archive` | Log | 상시 | — | 로그 수집·Athena·SIEM |
| `account-baseline` | Workload | 상시 | 34개 | Config·GuardDuty·Security Hub·비용 알림 등 계정 베이스라인 |
| `persistent` | Workload | 상시 | 13개+ | ECR·KMS·시크릿 그릇·CloudFront 로그 버킷 — **매일 부숴선 안 되는 데이터** |
| `cloudwatch-notifications` | Workload | 상시 | 30개+ | SNS 알림 허브·GuardDuty 자동대응 Lambda·IAM 활동 감시·(꺼진) LLM 트리아지 |
| `discord-notifications` | Workload | 상시 | 3개 | ArgoCD → Discord 알림 배선 |
| `terraform` | Workload | **일일** | 약 250개 | VPC·EKS·RDS·ALB·CloudFront·WAF·ArgoCD·관측 — **매일 생성·파괴** |

상시 계층과 일일 계층의 연결은 항상 한 방향이다: 일일 계층(`terraform`)이 `data` 소스로 상시 계층의 산출물(ECR 저장소, KMS 키, 시크릿, 로그 버킷)을 **읽기만** 한다. 반대 방향 참조는 없다. 그래서 daily-down이 일일 계층을 통째로 destroy해도 상시 계층은 아무 영향이 없다.

이 경계가 실전에서 검증된 사례가 CloudFront 액세스 로그 버킷이다. 원래 일일 계층에 있었는데 로그가 쌓이면 `BucketNotEmpty`로 destroy가 계속 실패했다 — "보존 장치인 줄 알았던 `force_destroy=false`가 사실은 teardown 실패 장치였다". 버킷을 `persistent`로 옮기고(`5832f65`) 일일 계층은 `data`로 읽게 바꿔 해결했다.

## 4. 하루의 사이클 — daily-up / daily-down

운영은 `scripts/`의 PowerShell 스크립트 두 개가 담당한다(테라폼은 아니지만 이 저장소의 실질적 진입점이다).

**아침 `daily-up.ps1`** — 런타임 루트를 2단계로 apply한다:
1. **1차 apply** (`enable_edge=false`): VPC → EKS → RDS → ALB까지 약 235개. 이 시점엔 Route53이 ALB를 직접 가리킨다.
2. **2차 apply** (`enable_edge=true`): CloudFront·us-east-1 WAF·ACM을 얹고 Route53을 CloudFront로 전환(+15개 수준).

2단계로 나눈 이유: CloudFront가 오리진(ALB)을 요구하므로 ALB가 먼저 살아 있어야 하고, ACM 검증·배포 전파 대기가 길어서 실패 지점을 분리하는 편이 안전하다.

apply가 끝나면 그 안의 `null_resource`들이 스스로 검증한다 — ECR에 서명 이미지가 있는지, 앱 파드가 뜨는지, `https://kycj.click`이 200을 주는지(smoke test). 이 3개는 `always_run = timestamp()` 트리거라 **plan마다 항상 3 add/3 destroy가 뜨는 것이 정상**이며, 이 루트에서 `No changes`는 구조적으로 불가능하다.

**저녁 `daily-down.ps1`** — 런타임 루트만 destroy(약 278개). 상시 계층 4개 루트는 손대지 않는다. RDS·S3 이미지 버킷까지 지워지므로 **업로드된 상품 이미지는 매일 사라진다**(코드 주석에 명시된 의도적 트레이드오프).

매일 재탄생하는 구조가 코드 곳곳의 설계를 결정한다:
- RDS가 매일 새로 생기므로 앱용 DB 계정(`gochuchamchi_app_iam`)을 **매일 아침 배스천에서 재프로비저닝**한다.
- GuardDuty 격리 Lambda는 검역 SG를 미리 만들어 둘 수 없어(VPC가 매일 바뀜) **즉석 생성**한다.
- ACM·Route53처럼 이름이 고정된 것은 재생성 충돌을 겪었고, import 등으로 해결한 이력이 있다.

## 5. 배포 파이프라인 — 코드가 서비스가 되기까지

```
spring 저장소 push
  → GitHub Actions CI: 빌드 → 이미지 서명(cosign) → ECR push (persistent 계층의 저장소)
  → ArgoCD Image Updater: 새 이미지 감지 → gitops 저장소에 태그 write-back (쓰기 PAT 사용)
  → ArgoCD: gitops 저장소와 클러스터를 sync (읽기 전용 PAT 사용)
  → Kyverno: 서명 검증 정책 — 서명 안 된 이미지는 아예 뜨지 못함
```

여기 얽힌 시크릿 배선: GitHub PAT 2개(읽기 전용/쓰기)는 `persistent`의 Secrets Manager 그릇에 수동 주입되고, 일일 계층의 **ESO**(External Secrets Operator)가 이를 K8s Secret으로 동기화해 ArgoCD와 Image Updater에게 준다. 최소 권한 분리 — ArgoCD는 읽기만, Image Updater만 쓰기.

## 6. 보안 아키텍처 한눈에

- **경계**: CloudFront 앞 WAF(managed rules + IP 평판 BLOCK + 로그인 rate limit), ALB는 CloudFront가 붙여 주는 `X-Gochuchamchi-Origin-Verify` 헤더(48자 random_password)를 검사해 CloudFront 우회 직접 접근을 차단.
- **DB 제로트러스트**: 앱 DB 계정은 비밀번호가 아예 없다 — RDS IAM 토큰 인증(수명 15분) 전용 계정 `gochuchamchi_app_iam`, DML만 허용, TLS 강제(`verify-full` + 이미지에 구운 RDS CA). 비밀번호 계정과 K8s Secret은 2026-08-13에 완전 제거됐다.
- **파드 권한 최소화**: EKS Pod Identity로 앱 파드에 S3 CRUD + `rds-db:connect`(특정 유저명)만 부여 — 앱이 뚫려도 계정 장악으로 이어지지 않는다.
- **탐지·대응**: GuardDuty finding → EventBridge 필터(중요 타입은 severity 무관 통보) → SNS 허브 → 이메일/Discord. severity 높은 EC2 finding은 Lambda가 **자동 격리**(ENI SG 교체 + 포렌식 태깅), IAM 자격증명 finding은 액세스키 자동 비활성화. 복구는 사람이 수동 invoke(오탐 판단은 사람 몫).
- **알람 통보 규약(중요)**: 이 프로젝트 알람에는 `alarm_actions`가 없다. 대신 상시 계층 EventBridge가 **알람 이름 접두사 `gochuchamchi-`**로 상태 변화를 잡아 SNS로 넘긴다. 알람을 새로 만들 때 접두사를 안 지키면 조용히 통보에서 빠진다.
- **로그 불변성**: 주요 로그는 구독필터로 Log 계정에 실시간 복제 — Workload가 장악돼도 흔적은 남는다.

## 7. 이 문서를 읽는 법

문서는 루트 단위 9개 섹션으로 이어진다. 각 섹션은 파일별 헤딩(`## 루트/파일.tf (N줄)`) 아래 블록별 해설(`### L시작–끝 · 블록 시그니처`)로 구성된다. 특정 파일이 궁금하면 목차에서 파일명으로 바로 찾으면 된다.

1. **management** — 조직·SSO·SCP·org trail (Management 계정)
2. **log-archive (1)** — 로그 수집·아카이브·Athena 분석 (Log 계정)
3. **log-archive (2)** — SIEM 탐지 룰·알림·대시보드 (Log 계정)
4. **account-baseline** — Workload 상시 보안 베이스라인
5. **persistent · discord-notifications** — 상시 자원 계층
6. **cloudwatch-notifications** — 알림 허브·자동 대응
7. **terraform (1)** — 런타임: 네트워크·데이터·컴퓨트 기반
8. **terraform (2)** — 런타임: 엣지·배포 파이프라인·K8s 정책
9. **terraform (3)** — 런타임: 관측·모니터링

### 테라폼 외 부속 파일(참고 — 이 문서의 줄 단위 해설 범위 밖)

| 위치 | 내용 |
|---|---|
| `scripts/` (14개 .ps1) | `daily-up`/`daily-down`(일일 사이클), `bootstrap-state`(tfstate 버킷 초기화), `preflight-check`, `verify-all` 및 검증 7종(smoke/contract/db-iam/notifications/log-pipeline/waf/schema-sync), `verify-auto-response`, `generate-baseline-imports` |
| `cloudwatch-notifications/*.py` | `lambda_function.py`(알람→Discord 포매터), `isolation_function.py`(GuardDuty 격리·키 비활성화·복구·감사) |
| `cloudwatch-notifications/triage/` | `judge.py`(LLM 판정, provider 추상화), `policy.py`, `triage_function.py`, 비교·검증 도구 |
| `k8s/gochuchamchi/schema.sql` | spring 저장소 `schema.sql`의 사본(RDS 초기 스키마 주입용). CI·로컬 스크립트로 동기화 검사 |
| `docs/` | 일자별 작업 기록·트러블슈팅 모음 |
| `SETUP-NEW-WORKER.txt` | 새 팀원 온보딩 절차 |


---

# management — 조직·SSO·감사 (Management 계정)

`management/`는 gochuchamchi 프로젝트의 3계정 구조(Management 307223751140 / Security-Log 564186750363 / Workload 828885965304)에서 **가장 위에 있는 루트**다. AWS Organizations의 관리 계정(Management 계정)에서만 실행할 수 있는 작업들 — 조직 자체의 정의, OU 구성, IAM Identity Center(SSO)의 Permission Set, SCP 가드레일, 조직 전체 CloudTrail(organization trail), GuardDuty·Security Hub의 위임 관리자 지정 — 을 코드로 관리한다. 독자가 담당하는 Workload 계정(828885965304)의 입장에서 보면, "내 계정에 로그인할 때 쓰는 SSO 권한은 어디서 정의되는가", "내 계정에서 CloudTrail을 왜 못 끄는가", "내 계정의 모든 API 호출 기록이 어디로 흘러가는가"에 대한 답이 전부 이 루트에 있다. 팀원 담당 영역이지만, 발표·면접에서 "멀티 어카운트 거버넌스"를 설명하려면 이 루트를 이해하는 것이 출발점이 된다.

루트는 두 개의 독립된 Terraform 구성(각각 별도 tfstate)으로 나뉜다. `organization/`은 조직·OU·SSO·SCP·위임 관리자 지정을 담당하고, `audit/`은 organization trail(CloudTrail) 하나만 담당한다. 둘을 분리한 이유는 **적용 순서 의존성** 때문이다. org trail은 로그를 Security/Log 계정의 중앙 버킷(`gochuchamchi-log-archive-564186750363`)에 쓰는데, 그 버킷은 log-archive 루트가 만든다. 즉 실행 순서가 `organization`(조직 뼈대) → log-archive(버킷·KMS, Log 계정에서 apply) → `audit`(org trail)로 강제되므로, 한 구성에 합쳐두면 최초 부트스트랩이 불가능하다. 분리해 두면 각 단계의 blast radius도 작아진다.

또 하나의 설계 특징은 **단계적 활성화 플래그**다. `enable_identity_center_configuration`, `enable_log_archive_protection_scp`, `enable_security_services_delegation` 세 개의 bool 변수가 전부 `default = false`로 시작하고, 선행 조건(콘솔에서 Identity Center 활성화, 로그 버킷 생성 완료, Log 계정의 수신 준비 완료)이 충족된 뒤에 하나씩 true로 올리는 구조다. "인프라를 코드에 전부 선언해 두되, 켜는 시점은 운영 순서에 맞춘다"는 패턴으로, 조직 부트스트랩처럼 닭-달걀 의존이 많은 영역에서 유용하다. 마지막으로, 이 루트의 핵심 리소스에는 전부 `prevent_destroy`가 걸려 있다 — 매일 생성·파괴되는 런타임 루트(`terraform/`)와 달리, 조직·감사 계층은 daily-down의 대상이 아니며 실수로도 파괴되면 안 되는 상시 계층이기 때문이다.

---

## management/organization/backend.tf (10줄)

organization 구성의 tfstate를 어디에 어떻게 저장할지 정의하는 파일이다. 프로젝트의 모든 루트가 같은 패턴(S3 backend + 계정별 프로파일 + 네이티브 잠금)을 쓰며, 이 파일은 그중 Management 계정용 인스턴스다.

### L1–10 · terraform { backend "s3" { … } }

Terraform 상태 파일을 S3에 원격 저장하는 backend 블록이다. 인자별로 보면 다음과 같다.

- `bucket = "gochuchamchi-tfstate-307223751140"` — tfstate 전용 버킷. 버킷 이름 끝에 Management 계정 ID를 붙여 어느 계정 소유인지 이름만 보고 알 수 있게 했고, S3 버킷 이름의 전역 유일성 충돌도 피한다. 이 버킷 자체는 Terraform으로 만들 수 없는 부트스트랩 자원이라(상태를 저장할 곳이 먼저 있어야 하므로) 별도로 미리 만들어져 있다.
- `key = "management/organization/terraform.tfstate"` — 버킷 안 경로. `<루트 디렉터리 경로>/terraform.tfstate` 규칙으로 네임스페이스를 나눠, 한 버킷에 여러 루트의 상태를 충돌 없이 담는다. `audit/backend.tf`는 같은 버킷에 `management/audit/...` 키를 쓴다.
- `region = "ap-northeast-2"` — tfstate 버킷이 있는 리전. 프로젝트 전체 기본 리전(서울)과 일치한다.
- `profile = "management-admin"` — 상태를 읽고 쓸 때 사용할 AWS CLI 프로파일. 이 프로젝트는 3계정을 SSO 프로파일(`management-admin`, `log-admin`, `workload-admin` 류)로 구분하는데, backend에도 프로파일을 박아 "Workload 프로파일로 실수로 management 상태를 건드리는" 사고를 원천 차단한다. backend 블록은 변수를 쓸 수 없으므로(하드코딩만 허용) 문자열 리터럴이다.
- `encrypt = true` — tfstate 객체를 서버 측 암호화(SSE)로 저장한다. 상태 파일에는 리소스 ID·ARN 등 민감할 수 있는 값이 들어가므로 항상 켠다.
- `use_lockfile = true` — DynamoDB 테이블 없이 **S3 조건부 쓰기 기반 네이티브 잠금**(`.tflock` 객체)을 쓴다. Terraform 1.10에서 도입된 기능이라 `providers.tf`의 `required_version = ">= 1.10"`과 짝을 이룬다. 잠금 전용 DynamoDB 테이블을 만들고 관리할 필요가 없어져 부트스트랩이 한층 단순해진다.

함정: backend 설정 변경은 `terraform init -reconfigure`(또는 `-migrate-state`)를 다시 해야 반영된다. 또 `profile` 하드코딩 때문에 팀원 로컬에 같은 이름의 SSO 프로파일이 구성되어 있어야 init이 된다.

## management/organization/providers.tf (17줄)

Terraform 코어·AWS provider의 버전 제약과 자격증명 방식을 선언하고, 이후 파일들이 쓸 호출자 신원 data source를 정의한다.

### L1–10 · terraform { required_version, required_providers }

- `required_version = ">= 1.10"` — backend의 `use_lockfile`(S3 네이티브 잠금)이 1.10부터 지원되기 때문에 하한을 1.10으로 잡았다. 팀원 간 Terraform 버전이 달라 생기는 상태 포맷·기능 차이를 예방하는 최소한의 가드다.
- `required_providers.aws` — `source = "hashicorp/aws"`, `version = "~> 6.0"`. `~>`(pessimistic constraint)는 "6.x는 허용하되 7.0은 불허"라는 뜻이다. 메이저 버전 업그레이드는 리소스 스키마가 깨질 수 있으므로 자동으로 넘어가지 않게 막고, 마이너·패치 업데이트는 받아들인다.

### L12–15 · provider "aws"

기본 AWS provider 구성이다. `region = var.region`(기본 ap-northeast-2), `profile = var.aws_profile`(기본 management-admin)로, 변수 기본값 덕분에 아무 옵션 없이 `terraform plan`을 쳐도 Management 계정·서울 리전으로 붙는다. backend와 달리 provider 블록은 변수를 쓸 수 있어서 여기서는 var 참조다. Organizations·Identity Center는 사실상 글로벌 서비스지만 API 엔드포인트 호출 리전과 GuardDuty·Security Hub 같은 리전별 서비스의 적용 리전이 이 값으로 정해진다는 점이 중요하다(→ `security-services.tf` 상단 주석의 리전 주의와 연결).

### L17 · data "aws_caller_identity" "current"

현재 자격증명이 속한 계정 ID·ARN을 조회하는 data source다. 그 자체로는 아무것도 만들지 않지만, `organization.tf`의 precondition에서 "지금 이 apply가 정말 Management 계정 자격증명으로 실행 중인가"를 검증하는 데 쓰인다. 프로파일을 잘못 잡고 실행하는 사고에 대한 런타임 방어선이다.

## management/organization/variables.tf (62줄)

이 구성의 입력 변수 8개를 정의한다. 앞의 5개는 "이 조직의 고정 사실"(리전·프로파일·계정 ID 3개)이고, 뒤의 3개는 앞서 말한 단계적 활성화 플래그다. 특징은 계정 ID 변수에 **validation으로 기본값과 동일한 리터럴을 다시 강제**한다는 점 — 변수이지만 사실상 상수로 취급하고, `-var`로 다른 값을 넘기는 실수를 아예 에러로 만든다.

### L1–5 · variable "region"

Organizations와 Identity Center를 관리할 기본 리전. `type = string`, `default = "ap-northeast-2"`(서울). 프로젝트의 모든 루트가 서울 단일 리전 기준이므로 기본값만으로 동작한다. 이 값은 provider 리전이자, `outputs.tf`의 `security_services_delegated_admin` 출력에 "위임이 적용된 리전"으로 그대로 실려 Log 계정 담당자에게 전달된다.

### L7–11 · variable "aws_profile"

Management 계정 전용 AWS CLI(SSO) 프로파일 이름. `default = "management-admin"`. provider 블록에 주입된다. 계정마다 프로파일을 분리하는 것이 이 프로젝트의 멀티 어카운트 운영 규약이며, backend의 하드코딩된 프로파일과 값이 일치해야 혼란이 없다.

### L13–22 · variable "management_account_id"

Management 계정 ID. `default = "307223751140"`에 더해 `validation` 블록이 `var.management_account_id == "307223751140"`을 강제한다. 기본값과 검증값이 같으니 실질적으로 바꿀 수 없는 값인데, 굳이 변수로 둔 이유는 (1) 여러 파일에서 매직 넘버 대신 이름으로 참조하기 위해서, (2) 검증 에러 메시지로 의도를 문서화하기 위해서다. 계정 ID를 string으로 두는 것도 포인트다 — number로 두면 선행 0이 잘리는 위험이 있어 AWS 계정 ID는 항상 문자열로 다룬다. 이 값은 `organization.tf`의 precondition("정말 Management 자격증명인가")에서 비교 기준으로 쓰인다.

### L24–33 · variable "log_archive_account_id"

Security/Log 멤버 계정 ID(564186750363). 구조는 위와 동일한 리터럴 고정 + validation이다. `scp.tf`의 ProtectLogArchive 정책에서 보호 대상 버킷·KMS ARN을 조립할 때, `security-services.tf`에서 위임 관리자 대상 계정으로, `outputs.tf`의 account_map에서 참조된다.

### L35–44 · variable "workload_account_id"

Workload 멤버 계정 ID(828885965304) — 독자가 담당하는 계정이다. 같은 고정 패턴. 이 구성 안에서는 `outputs.tf`의 account_map에만 직접 등장하지만, "조직이 아는 세 계정"을 한 곳에 명시해 두는 레지스트리 역할을 한다.

### L46–50 · variable "enable_identity_center_configuration"

`type = bool`, `default = false`. IAM Identity Center **인스턴스는 Terraform으로 만들 수 없고 Management 콘솔에서 먼저 활성화**해야 하는데(조직 인스턴스는 콘솔 활성화가 전제), 활성화 전에 `identity-center.tf`의 data source가 실행되면 인스턴스가 없어 실패한다. 그래서 콘솔 활성화라는 수동 선행 작업이 끝난 뒤 true로 바꾸는 게이트로 설계됐다. `identity-center.tf`의 모든 블록이 이 변수로 `count` 게이트된다.

### L52–56 · variable "enable_log_archive_protection_scp"

`default = false`. ProtectLogArchive SCP의 **부착**(attachment)만 게이트한다. 이유는 닭-달걀 문제다: 로그 버킷·KMS를 만들고 버킷 정책을 조정하는 작업이 끝나기 전에 이 SCP를 붙이면, `s3:PutBucketPolicy`·`kms:PutKeyPolicy` 거부 때문에 Log 계정 담당자가 자기 인프라를 구축·수정하는 것 자체가 막힌다. 그래서 "생성·검증 완료 후 잠금"이라는 순서를 변수로 표현했다.

### L58–62 · variable "enable_security_services_delegation"

`default = false`. GuardDuty·Security Hub의 위임 관리자 지정(`security-services.tf` 전체)을 게이트한다. 위임을 지정하는 순간 Log 계정 쪽에 조직 관리 권한과 책임이 생기므로, Log 계정이 조직 설정(멤버 자동 등록 등)을 받을 준비가 된 뒤에 켠다는 운영 합의를 코드화한 것이다.

## management/organization/organization.tf (43줄)

조직의 뼈대를 만드는 파일이다. AWS Organizations 조직 리소스 하나와 OU 두 개(Security, Workloads)를 정의한다. 주의할 점: **멤버 계정 생성(aws_organizations_account)은 이 코드에 없다.** 세 계정은 콘솔에서 미리 만들어져 있고, OU로의 이동도 수동으로 한다(→ `outputs.tf`의 OU ID 출력 설명 참조). 계정 생성·초대까지 코드화하지 않은 것은 학생 팀 규모에서 이미 존재하는 계정을 import하는 복잡도를 피한 실용적 선택이다.

### L1–25 · resource "aws_organizations_organization" "this"

AWS Organizations 조직 자체를 선언한다. 조직이 이미 콘솔에서 만들어져 있었다면 이 리소스는 import로 상태에 편입시켜 관리한다(같은 계정에서 재생성 시도는 에러가 난다).

- `feature_set = "ALL"` (L2) — Organizations의 두 모드(CONSOLIDATED_BILLING / ALL) 중 전체 기능 모드다. SCP, 신뢰 액세스(trusted access), 위임 관리자 같은 거버넌스 기능은 전부 ALL에서만 동작하므로 이 프로젝트에서는 선택의 여지가 없다.
- `aws_service_access_principals` (L4–11) — 조직과 통합(신뢰 액세스)을 허용할 AWS 서비스 목록이다. 여기에 등록된 서비스만 조직 차원 기능(서비스 연결 역할 자동 생성, 멤버 계정 접근)을 쓸 수 있다. 항목별로:
  - `backup.amazonaws.com` — AWS Backup의 조직 통합(조직 백업 정책 등)을 열어 둔다.
  - `cloudtrail.amazonaws.com` — **`audit/cloudtrail.tf`의 organization trail이 동작하기 위한 필수 전제**다. 이게 없으면 `is_organization_trail = true` 트레일 생성이 실패한다.
  - `config-multiaccountsetup.amazonaws.com` — AWS Config의 멀티 계정 설정(조직 단위 Config 규칙·컨포먼스 팩)용 principal이다.
  - `guardduty.amazonaws.com` / `securityhub.amazonaws.com` — `security-services.tf`의 위임 관리자 지정과 조직 단위 보안 서비스 관리의 전제다.
  - `sso.amazonaws.com` — IAM Identity Center가 조직의 계정 목록을 읽고 멤버 계정에 역할을 프로비저닝하기 위한 전제로, `identity-center.tf` 전체가 이것에 의존한다.
- `enabled_policy_types = ["SERVICE_CONTROL_POLICY"]` (L13–15) — 루트에서 활성화할 정책 타입. SCP만 켠다(태그 정책·백업 정책 등은 사용하지 않음). `scp.tf`의 정책 생성·부착이 전부 이 활성화에 의존한다.
- `lifecycle` (L17–24) — 두 가지 방어가 들어 있다. `prevent_destroy = true`는 이 리소스가 destroy 계획에 포함되는 순간 plan 단계에서 에러를 내 조직 해체를 막는다. `precondition`은 `data.aws_caller_identity.current.account_id == var.management_account_id`를 검사해, **다른 계정 프로파일로 실행하면 plan부터 실패**시킨다. 멀티 프로파일 환경에서 가장 흔한 사고(프로파일 잘못 잡기)를 코드 레벨에서 잡는 장치로, `audit/cloudtrail.tf`에도 같은 패턴이 반복된다.

### L27–34 · resource "aws_organizations_organizational_unit" "security"

Security OU. `name = "Security"`, `parent_id = aws_organizations_organization.this.roots[0].id` — 조직 리소스의 `roots` 속성(조직 루트 컨테이너 목록, 사실상 1개)에서 루트 ID를 얻어 그 바로 아래에 만든다. Security/Log 계정(564186750363)이 이 OU에 들어가며, `scp.tf`의 DenyLeaveOrganization과 ProtectLogArchive가 이 OU를 target으로 부착된다. `prevent_destroy = true`로 OU 삭제(=부착된 SCP 이탈)를 막는다.

### L36–43 · resource "aws_organizations_organizational_unit" "workloads"

Workloads OU. 구조는 Security OU와 동일하고, Workload 계정(828885965304)이 들어간다. 독자 입장에서 중요한 것은 **이 OU에 부착된 SCP 두 개(DenyLeaveOrganization, DenyWorkloadAuditTampering)가 곧 내 계정의 행동 제약**이라는 점이다. OU를 계정 성격(보안·로그 vs 워크로드)으로 나눈 이유가 바로 이것 — SCP를 계정이 아닌 OU에 붙여, 계정이 늘어나도 OU 이동만으로 같은 가드레일이 적용되게 하기 위해서다.

## management/organization/identity-center.tf (60줄)

IAM Identity Center(구 AWS SSO)의 Permission Set 3종과 각 세트에 붙는 AWS 관리형 정책을 정의한다. 파일 상단 주석(L1–2)이 밝히듯 **인스턴스 자체는 콘솔에서 먼저 활성화**해야 하고, 그 후 `enable_identity_center_configuration = true`로 바꾸면 이 파일이 활성화된다. 모든 블록에 같은 `count` 게이트가 반복되는 이유다. 또 하나 짚을 점: 이 파일에는 **계정 할당(aws_ssoadmin_account_assignment)이 없다.** "어느 그룹이 어느 계정에 어느 Permission Set으로 들어가는가"는 콘솔에서 수동 관리한다. 즉 `WorkloadAdministrator`가 "Workload 계정 전용"인 것은 정책 내용이 아니라 **할당을 Workload 계정에만 해주는 운영 규약**으로 보장된다 — 면접에서 물어보기 좋은 미묘한 지점이다.

### L1–5 · data "aws_ssoadmin_instances" "this"

현재 계정·리전의 Identity Center 인스턴스 목록을 조회하는 data source다. `count = var.enable_identity_center_configuration ? 1 : 0` — 플래그가 꺼져 있으면 조회 자체를 하지 않는다. 인스턴스가 없는 상태에서 이 data source를 평가하면 에러가 나므로, "콘솔 활성화 전에는 아예 읽지 않는다"를 count로 구현한 것이다. data source에 count를 거는 다소 특이한 패턴이지만, 외부 수동 선행 조건을 다루는 실전적인 방법이다.

### L7–9 · locals { identity_center_instance_arn }

`var.enable_identity_center_configuration ? tolist(data.aws_ssoadmin_instances.this[0].arns)[0] : null`. 조회 결과에서 인스턴스 ARN 하나를 뽑아 로컬 값으로 만든다. `arns` 속성이 **set 타입**이라 인덱스 접근이 불가능하므로 `tolist()`로 변환한 뒤 `[0]`을 취한다(계정당 인스턴스는 사실상 1개). 플래그가 꺼져 있으면 `null` — 어차피 이 값을 쓰는 리소스들도 전부 count 0이라 평가되지 않지만, 조건식을 넣어 두면 plan 단계 에러를 안전하게 피한다. 이후 6개 리소스가 전부 이 local을 참조하므로, 반복되는 긴 표현식을 한 번만 쓰게 하는 가독성 장치이기도 하다.

### L11–18 · resource "aws_ssoadmin_permission_set" "workload_administrator"

Workload 계정용 관리자 Permission Set이다. Permission Set은 "SSO 사용자가 계정에 들어갈 때 쓸 역할의 틀"로, 할당 시 대상 계정에 IAM 역할로 프로비저닝된다.

- `name = "WorkloadAdministrator"` — 콘솔 로그인 화면과 프로비저닝된 역할 이름에 노출되는 식별자. 용도가 이름에 드러나게 지었다.
- `description = "Workload 계정 전용 관리자"` — 위에서 설명했듯 "전용"의 강제는 할당 운영으로 이뤄진다.
- `instance_arn = local.identity_center_instance_arn` — 소속 인스턴스.
- `session_duration = "PT4H"` — ISO 8601 duration 표기로 4시간. 기본값(1시간)보다 길게 잡아 하루 작업 중 재로그인 빈도를 줄이되, 8~12시간처럼 과도하게 늘리지 않아 세션 탈취 리스크와 편의성 사이 균형을 잡았다. 세 Permission Set이 모두 같은 값이라 정책적 일관성이 있다.

독자가 Workload 계정에서 작업할 때 실제로 assume하는 것이 바로 이 세트가 만들어낸 역할(`AWSReservedSSO_WorkloadAdministrator_...`)이다.

### L20–26 · resource "aws_ssoadmin_managed_policy_attachment" "workload_administrator"

위 Permission Set에 AWS 관리형 정책을 붙인다. `permission_set_arn = aws_ssoadmin_permission_set.workload_administrator[0].arn` — count 리소스라 `[0]` 인덱스 참조가 필요하다. `managed_policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"` — 계정 안에서는 전권을 준다. 학생 팀 규모에서 세밀한 최소 권한 정책을 유지하는 비용 대신, **계정 경계(할당) + SCP(가드레일)로 통제**하는 전략이다: Workload 관리자여도 SCP의 DenyWorkloadAuditTampering·DenyLeaveOrganization은 절대 못 넘는다. Permission Set의 정책을 바꾸면 할당된 모든 계정에 재프로비저닝이 일어난다는 점도 알아둘 것.

### L28–35 · resource "aws_ssoadmin_permission_set" "security_log_administrator"

Security/Log 계정용 관리자 Permission Set(`name = "SecurityLogAdministrator"`). 인자 구성은 WorkloadAdministrator와 완전히 동일하다(PT4H 포함). 정책 내용이 같은데 세트를 둘로 나눈 이유는 **할당 대상을 계정별로 분리해 접근을 계정 경계로 격리**하기 위해서다 — Workload 담당자는 Log 계정에 들어갈 수 없고, 그 역도 마찬가지. 하나의 "Administrator" 세트를 양쪽에 할당했다면 이 격리가 사라진다.

### L37–43 · resource "aws_ssoadmin_managed_policy_attachment" "security_log_administrator"

SecurityLogAdministrator에 AdministratorAccess를 붙인다. 구조는 L20–26과 동일하며, 참조만 `aws_ssoadmin_permission_set.security_log_administrator[0].arn`으로 바뀐다. Log 계정 관리자 역시 SCP(ProtectLogArchive)의 통제를 받으므로 "관리자여도 중앙 로그는 못 지운다"가 성립한다.

### L45–52 · resource "aws_ssoadmin_permission_set" "organization_read_only"

조회 전용 Permission Set(`name = "OrganizationReadOnly"`, `description = "조직 전체 조회 전용"`). 세션 4시간 동일. 팀원이 자기 담당이 아닌 계정을 구경(장애 조사, 리뷰, 발표 준비)할 때 쓰라고 만든 세트로, 여러 계정에 폭넓게 할당해도 위험이 낮다. "쓰기 권한은 담당 계정에만, 읽기 권한은 넓게"라는 접근 모델의 후반부를 담당한다.

### L54–60 · resource "aws_ssoadmin_managed_policy_attachment" "organization_read_only"

OrganizationReadOnly에 `arn:aws:iam::aws:policy/ReadOnlyAccess`를 붙인다. ReadOnlyAccess는 거의 모든 서비스의 Describe/List/Get을 허용하는 AWS 관리형 정책이다. 주의: 읽기 전용이라도 S3 객체 내용·Secrets Manager 값 조회까지 포함될 수 있어 "무해한" 권한은 아니다 — 그래서 이 세트조차 SSO 세션 만료와 SCP의 통제 아래에 있다.

## management/organization/scp.tf (102줄)

이 프로젝트 가드레일의 핵심인 SCP(Service Control Policy) 3종과 부착 4건을 정의한다. SCP의 본질을 먼저 잡고 가자: SCP는 권한을 "주는" 정책이 아니라 **최대 허용 경계**다. IAM에서 아무리 AdministratorAccess를 가져도 SCP가 Deny하면 불가능하고, 결정적으로 **멤버 계정의 root 사용자에게도 적용**된다(일반 IAM 정책으로는 불가능한 통제). 단, Management 계정 자신에게는 SCP가 적용되지 않는다 — 그래서 부착 대상이 조직 루트가 아닌 OU들이다.

### L1–15 · resource "aws_organizations_policy" "deny_leave_organization"

조직 이탈을 막는 SCP다. `name = "DenyLeaveOrganization"`, `type = "SERVICE_CONTROL_POLICY"`(이 리소스는 태그 정책 등도 만들 수 있어 타입 명시가 필수다). `content`는 `jsonencode()`로 HCL 맵을 JSON으로 변환한다 — heredoc 문자열보다 문법 오류를 plan 단계에서 잡을 수 있어 안전하다. 정책 내용은 단 하나의 Statement: `Effect = "Deny"`, `Action = ["organizations:LeaveOrganization"]`, `Resource = "*"`. 멤버 계정이 스스로 조직을 떠나면 SCP·org trail·위임 구조가 전부 무력화되므로, root 사용자를 포함한 어떤 주체도 이탈할 수 없게 못 박는다(주석의 의도 그대로다). 계정 탈취 시나리오에서 공격자가 가장 먼저 시도할 "거버넌스 이탈"을 봉쇄하는 1번 가드레일이다.

### L17–20 · resource "aws_organizations_policy_attachment" "deny_leave_security"

DenyLeaveOrganization을 Security OU에 부착한다. `policy_id`는 정책 리소스의 id, `target_id`는 `aws_organizations_organizational_unit.security.id` — OU에 붙이면 그 안의 모든 계정(현재 Log 계정)에 상속 적용된다.

### L22–25 · resource "aws_organizations_policy_attachment" "deny_leave_workloads"

같은 정책을 Workloads OU에도 부착한다. 두 OU에 각각 붙이는 대신 조직 루트에 한 번 붙이는 방법도 있지만, OU 단위 부착은 "이 OU에는 어떤 가드레일이 있는가"를 명시적으로 보여주고, 나중에 특정 OU만 정책을 달리할 여지를 남긴다. 결과적으로 관리 대상 멤버 계정 전부가 커버된다.

### L27–52 · resource "aws_organizations_policy" "deny_workload_audit_tampering"

Workload 계정에서 감사·보안 서비스를 무력화하는 행위를 차단하는 SCP다. 독자 계정에 직접 걸리는 정책이니 액션 목록을 하나씩 이해해 둘 가치가 있다.

- `cloudtrail:DeleteTrail` / `StopLogging` / `UpdateTrail` — org trail의 삭제·중지·변조 차단. UpdateTrail까지 막는 이유는 삭제하지 않고 대상 버킷만 바꿔치기해 로그를 빼돌리는 우회를 봉쇄하기 위해서다.
- `config:DeleteConfigurationRecorder` / `DeleteDeliveryChannel` / `StopConfigurationRecorder` — AWS Config 기록(account-baseline 루트가 Workload 계정에 구성하는 리소스 구성 추적)의 중단·해체 차단.
- `guardduty:DeleteDetector` / `DisassociateFromAdministratorAccount` — 위협 탐지기 삭제와, Log 계정(위임 관리자)의 관리에서 이탈하는 것을 차단. `security-services.tf`의 위임 구조를 멤버 쪽에서 깨지 못하게 하는 짝이다.
- `securityhub:DisableSecurityHub` / `DisassociateFromAdministratorAccount` — Security Hub 비활성화·관리 이탈 차단, 논리는 GuardDuty와 동일하다.

`Resource = "*"`인 이유: CloudTrail 등 일부 액션은 리소스 수준 제한이 의미 없거나 지원되지 않고, 어차피 "이 계정에서 이 행위 자체가 불가"가 의도이기 때문이다. 요컨대 "Workload 관리자는 자기 계정에서 뭐든 할 수 있지만, **감사받는 상태에서 벗어나는 것만은 못 한다**"를 코드화한 정책이다.

### L54–57 · resource "aws_organizations_policy_attachment" "deny_workload_audit_tampering"

위 정책을 Workloads OU에만 부착한다. Security OU에는 붙이지 않는데, Log 계정은 보안 서비스의 위임 관리자라서 같은 제약을 걸면 정당한 조직 관리 작업까지 막힐 수 있기 때문이다 — 대신 Log 계정은 다음 정책(ProtectLogArchive)으로 다른 방향의 통제를 받는다.

### L59–95 · resource "aws_organizations_policy" "protect_log_archive"

중앙 로그 저장소의 파괴를 막는 SCP로, Statement가 두 개다.

- **DenyCentralLogBucketDestruction** (L67–82): 대상은 `format("arn:aws:s3:::gochuchamchi-log-archive-%s", var.log_archive_account_id)`와 그 하위 객체(`/*`) — 즉 `gochuchamchi-log-archive-564186750363` 버킷이다. S3 ARN에는 계정 ID가 들어가지 않으므로, 버킷 **이름 규칙에 계정 ID를 포함**시키고 변수로 조립해 대상을 특정한다(log-archive 루트의 버킷 명명 규칙과 반드시 일치해야 하는 암묵적 계약이다). 차단 액션은 `s3:DeleteBucket`(버킷 삭제), `DeleteBucketPolicy`·`PutBucketPolicy`(접근 정책 무력화·변조), `PutBucketObjectLockConfiguration`(Object Lock 보존 설정 변조), `DeleteObject`·`DeleteObjectVersion`(로그 객체 삭제 — 버저닝 우회 삭제까지 차단). 버킷의 Object Lock(WORM)과 이 SCP가 이중 방어를 이룬다.
- **DenyLogKmsDestruction** (L83–92): 대상은 `arn:aws:kms:*:564186750363:key/*` — Log 계정의 **모든 리전, 모든 KMS 키**다. 로그 암호화 키가 지워지면 버킷이 멀쩡해도 로그를 못 읽게 되므로, `kms:DisableKey`(비활성화), `PutKeyPolicy`(키 정책 변조로 접근 차단), `ScheduleKeyDeletion`(삭제 예약)을 막는다. 키를 특정하지 않고 계정 전체 와일드카드로 잡은 것은 키 ARN을 이 루트가 알 수 없는 시점(부트스트랩 순서상 키가 아직 없음)에도 정책을 선언해 두기 위한 선택이다.

이 정책이 방어하는 시나리오는 외부 공격자만이 아니라 **Log 계정 관리자 자신의 실수·내부자 위협**까지 포함한다. SSO로 AdministratorAccess를 가진 사람도, 심지어 root도 이 버킷과 키는 못 부순다.

### L97–102 · resource "aws_organizations_policy_attachment" "protect_log_archive"

ProtectLogArchive를 Security OU에 부착하되, `count = var.enable_log_archive_protection_scp ? 1 : 0`로 게이트한다. 주목할 설계: **정책 리소스(L59–95)는 항상 만들어지고, 부착만 조건부**다. 정책 문서는 미리 조직에 등록해 리뷰·검증할 수 있게 하고, 실제 효력(부착)은 로그 버킷·KMS 구축이 끝난 뒤에 발생시킨다. 부착 전에 효력이 생기면 Log 계정 담당자가 `PutBucketPolicy`가 막혀 버킷 정책(org trail 쓰기 허용 등)을 구성할 수 없게 되는 순서 문제를 변수 하나로 해결했다.

## management/organization/security-services.tf (46줄)

GuardDuty(위협 탐지)와 Security Hub(보안 상태 집계)의 **위임 관리자(delegated administrator) 지정**을 담당한다. 파일 헤더 주석(L1–9)이 책임 경계를 명확히 긋는다: 위임 지정은 Management 계정에서만 가능한 작업이고, 지정 이후의 실제 조직 단위 설정(멤버 자동 등록, 탐지기 기능 구성, finding 트리아지)은 전부 Log 계정 쪽 코드의 몫이다. 즉 이 파일은 "누가 조직 보안을 관리하는가"라는 권한 위임 한 줄기만 다룬다. 또 하나의 주의(L7–9 주석): GuardDuty·Security Hub는 **리전별 서비스**라 이 지정은 `var.region`(ap-northeast-2) 한 곳에만 적용된다 — 다른 리전의 finding은 중앙에 모이지 않으므로 리전 확장 시 provider alias로 리전별 지정을 반복해야 한다는 한계를 스스로 문서화해 뒀다. 네 블록 모두 `enable_security_services_delegation`으로 count 게이트된다.

### L11–20 · resource "aws_guardduty_detector" "management"

Management 계정 자신의 GuardDuty 탐지기다. L11–14 주석이 존재 이유를 설명한다: 위임 관리자는 **멤버 계정**을 자동 등록할 수 있지만 Organizations 관리 계정은 자동 등록 대상이 아니다. 따라서 Management 계정을 탐지 사각지대로 남기지 않으려면 여기서 직접 켜야 하고, 이것이 위임 관리자 지정 API의 선행 조건이기도 하다. 인자는 `enable = true`(탐지 활성)와 `finding_publishing_frequency = "FIFTEEN_MINUTES"` — finding을 EventBridge 등으로 내보내는 주기로, 선택지(15분/1시간/6시간) 중 가장 빠른 값을 골라 알림 파이프라인(cloudwatch-notifications → discord-notifications)의 지연을 최소화했다. 이 주기는 "탐지 속도"가 아니라 "내보내기 속도"라는 점을 구분해 두자.

### L22–31 · resource "aws_guardduty_organization_admin_account" "log_archive"

GuardDuty의 조직 위임 관리자를 지정한다. `admin_account_id = var.log_archive_account_id` — Log 계정(564186750363)이 조직 전체 GuardDuty를 관리하게 된다. 이후 Log 계정은 멤버 계정(Workload 포함)의 탐지기를 자동 등록·구성하고 finding을 한곳에서 본다. `depends_on = [aws_organizations_organization.this, aws_guardduty_detector.management]` — 이 리소스는 둘을 **속성으로 참조하지 않기 때문에** 암묵적 의존이 생기지 않아 명시적 depends_on이 필요하다: 조직(과 guardduty.amazonaws.com 신뢰 액세스)이 먼저 있어야 하고, 관리 계정 탐지기가 먼저 켜져 있어야 지정 API가 성공한다. 병렬 apply에서 발생할 수 있는 순서 경합을 막는 전형적 사례다.

### L33–36 · resource "aws_securityhub_account" "management"

Management 계정에서 Security Hub를 활성화한다(L33 주석: GuardDuty와 동일한 이유 — 관리 계정은 자동 등록 대상이 아니고, 위임 지정의 선행 조건). 이 리소스는 "이 계정에서 Security Hub를 켠다"는 스위치라 count 외의 인자가 없다 — 기본 보안 표준 구독 등 세부 구성은 여기선 다루지 않고, 조직 표준 구성은 위임받은 Log 계정 쪽 책임으로 넘긴다.

### L38–47 · resource "aws_securityhub_organization_admin_account" "log_archive"

Security Hub의 조직 위임 관리자를 Log 계정으로 지정한다. 구조는 GuardDuty 쪽(L22–31)과 대칭이다: `admin_account_id = var.log_archive_account_id`, `depends_on = [aws_organizations_organization.this, aws_securityhub_account.management]`(속성 참조가 없어 명시적 의존 필요). 이로써 GuardDuty finding과 Security Hub 종합 상태가 모두 Log 계정으로 모이는 "보안 관제는 Log 계정" 구도가 완성되고, 그 결과가 `outputs.tf`의 `security_services_delegated_admin`으로 인계된다.

## management/organization/outputs.tf (44줄)

이 구성이 다른 루트·다른 담당자에게 넘기는 값들이다. gochuchamchi는 루트 간 remote state 참조 대신 **출력을 사람이 읽고 다음 루트의 변수·수동 작업에 반영하는 인계 방식**을 쓰므로, outputs가 곧 팀 간 인터페이스 문서다.

### L1–4 · output "organization_id"

`aws_organizations_organization.this.id`(예: `o-xxxx`). description이 용도를 못 박는다: Security/Log 계정의 중앙 로그 버킷 정책에 전달할 값이다. org trail이 버킷에 쓸 때 경로에 Organization ID가 들어가고, 버킷 정책의 `aws:PrincipalOrgID` 조건이나 CloudTrail 쓰기 허용 경로(`AWSLogs/<org-id>/...`) 구성에 이 값이 필요하다. `audit/outputs.tf`의 `<ORG_ID>` 자리표시자를 채우는 값이기도 하다.

### L6–9 · output "organization_root_id"

조직 루트 컨테이너 ID(`r-xxxx`). OU가 아닌 루트 직속에 뭔가를 붙이거나 계정 이동 CLI(`aws organizations move-account`)의 source로 쓸 때 필요하다.

### L11–14 · output "security_ou_id"

Security OU ID. description이 운영 절차를 드러낸다: **Security/Log 계정을 이 OU로 수동 이동**하라는 것 — 계정 생성·이동이 코드 밖 수동 작업임을 outputs가 문서화하는 셈이다. 이동하는 순간 DenyLeaveOrganization(+나중에 ProtectLogArchive)이 그 계정에 적용된다.

### L16–19 · output "workloads_ou_id"

Workloads OU ID. 같은 논리로 Workload 계정(828885965304)을 이 OU로 수동 이동할 때 쓴다. 이동 시점부터 독자 계정에 SCP 가드레일이 걸린다.

### L21–27 · output "account_map"

세 계정 ID를 `{ management, log_archive, workload }` 맵으로 묶어 내보낸다. 다른 루트의 변수 기본값을 채우거나 문서·스크립트에서 계정 ID를 참조할 때 한 번에 복사할 수 있는 편의 출력이다. description이 없는 것은 값 자체가 자명하기 때문이다.

### L29–39 · output "security_services_delegated_admin"

L29–30 주석이 성격을 정의한다: **Security/Log 계정 담당자에게 넘기는 인계 지점** — 이 값이 채워지면 Log 계정에서 조직 단위 GuardDuty·Security Hub 설정을 시작해도 된다는 신호다. 값은 `var.enable_security_services_delegation ? { … } : null` 조건식으로, 위임 전에는 `null`을 내보내 "아직 준비 안 됨"을 표현한다. 맵 내부의 `guardduty = one(aws_guardduty_organization_admin_account.log_archive[*].admin_account_id)` 패턴을 눈여겨보자: count 리소스는 인스턴스가 0개일 수 있으므로 splat(`[*]`)으로 리스트를 만들고 `one()`으로 "1개면 그 값, 0개면 null"을 얻는다 — count 게이트 리소스를 출력에서 안전하게 다루는 관용구다. `region`을 함께 실어 보내는 이유는 위임이 리전별이라는 한계(security-services.tf 주석) 때문에 "어느 리전에서 유효한 위임인지"까지 인계해야 해서다.

### L41–44 · output "management_guardduty_detector_id"

`one(aws_guardduty_detector.management[*].id)` — Management 계정 자체 탐지기의 ID. Log 계정이 위임 관리자로서 Management 계정을 GuardDuty 멤버로 편입·관리할 때 이 detector ID를 참조해야 하므로 내보낸다. 역시 `one()+splat` 패턴으로 플래그 off일 때 null이 된다.

---

## management/audit/backend.tf (10줄)

audit 구성의 tfstate 저장 설정으로, organization의 backend와 같은 버킷·같은 패턴을 쓰되 key만 다르다.

### L1–10 · terraform { backend "s3" { … } }

`bucket = "gochuchamchi-tfstate-307223751140"`(Management 소유 tfstate 버킷 공유), `key = "management/audit/terraform.tfstate"`(**organization과 다른 키 = 다른 상태 파일**), `region = "ap-northeast-2"`, `profile = "management-admin"`, `encrypt = true`, `use_lockfile = true`. 각 인자의 의미는 organization/backend.tf 해설과 동일하다. 핵심은 key 분리다: 상태가 분리되어 있으므로 audit을 plan/apply/destroy해도 organization의 조직·SCP 상태에는 아무 영향이 없고, 잠금도 서로 독립이다. "org trail만 손보는 작업"의 blast radius를 트레일 하나로 좁히는 구조적 장치다.

## management/audit/providers.tf (17줄)

organization/providers.tf와 동일한 내용의 반복이다. 루트 구성이 분리되면 provider 선언도 각자 가져야 하므로 중복이 불가피하다.

### L1–10 · terraform { required_version, required_providers }

`required_version = ">= 1.10"`(use_lockfile 요구), `aws ~> 6.0`(6.x 고정). organization 쪽과 버전 제약을 똑같이 맞춰 두 구성이 같은 도구 체인에서 돌게 한다 — 한쪽만 provider 메이저를 올리면 같은 계정을 두 스키마로 다루게 되므로 함께 올려야 한다.

### L12–15 · provider "aws"

`region = var.region`, `profile = var.aws_profile`. org trail은 Management 계정 소유 리소스이므로 여기서도 management-admin 프로파일이다. 트레일 자체는 multi-region으로 동작하지만 리소스 생성·관리는 이 리전(홈 리전 ap-northeast-2)에서 이뤄진다.

### L17 · data "aws_caller_identity" "current"

`cloudtrail.tf`의 precondition(Management 계정 검증)에 쓰일 호출자 신원 조회. 역할은 organization 쪽과 같다.

## management/audit/variables.tf (48줄)

audit 구성의 변수 9개다. organization/variables.tf와 달리 계정 ID에 validation이 없고 description도 최소한이다 — 같은 값의 이중 관리 부담을 줄인 실용적 선택이지만, 엄밀히는 두 파일 간 가드 수준의 비대칭이 존재한다(잘못된 계정 실행은 cloudtrail.tf의 precondition이 최종 방어한다).

### L1–4 · variable "region"

기본 ap-northeast-2. 트레일의 홈 리전이 된다.

### L6–10 · variable "aws_profile"

기본 "management-admin". Organization trail은 Management 계정(또는 CloudTrail 위임 관리자)만 만들 수 있으므로 이 프로파일이어야 한다.

### L12–15 · variable "management_account_id"

기본 "307223751140". `cloudtrail.tf` precondition의 비교 기준이자 `outputs.tf` 경로 조립 재료다.

### L17–20 · variable "log_archive_account_id"

기본 "564186750363". outputs의 계정별 로그 경로 조립에 쓰인다.

### L22–25 · variable "workload_account_id"

기본 "828885965304". 마찬가지로 outputs 경로 조립용 — 독자 계정의 CloudTrail 로그가 어디 쌓이는지 가리키는 데 쓰인다.

### L27–30 · variable "cloudtrail_name"

기본 "gochuchamchi-org-trail". 트레일 이름이자 Name 태그 값. 프로젝트 접두사 + 용도(org-trail)로 콘솔에서 식별이 쉽다.

### L32–35 · variable "cloudtrail_s3_key_prefix"

기본 "cloudtrail". 중앙 로그 버킷 안에서 CloudTrail 로그를 담는 최상위 접두사다. 한 버킷에 여러 로그 소스(VPC Flow Logs, Config 등)를 받을 때 소스별로 경로를 구획하는 규칙이며, log-archive 쪽 버킷 정책의 허용 경로(`arn:aws:s3:::버킷/cloudtrail/AWSLogs/...`)와 반드시 일치해야 한다 — 어긋나면 트레일 생성이 `InsufficientS3BucketPolicyException`으로 실패한다.

### L37–41 · variable "log_archive_bucket_name"

기본 "gochuchamchi-log-archive-564186750363". description대로 Security/Log 계정의 **Object Lock 중앙 로그 버킷**이다. 이 기본값은 log-archive 루트의 버킷 명명 규칙, 그리고 `scp.tf` ProtectLogArchive가 보호하는 ARN과 삼자 일치해야 하는 암묵적 계약이다 — 셋 중 하나만 바뀌어도 로그 유실 또는 보호 공백이 생긴다.

### L43–48 · variable "log_archive_kms_key_arn"

기본 `null`, `nullable = true`. description이 사용법을 알려준다: log-archive apply의 출력 `kms_logs_key_arn`을 받아 넣는 자리이며, null이면 트레일 자체 KMS 지정 없이 버킷 기본 SSE-KMS에 맡긴다. null 허용으로 만든 이유는 부트스트랩 순서 유연성이다 — 키 ARN을 아직 인계받지 못한 시점에도 트레일을 먼저 세울 수 있고, 이후 값을 채워 재적용하면 된다. `type = string` + `default = null` 조합에서 `nullable = true`를 명시해 "null이 정상 상태"임을 선언한 점이 꼼꼼한 부분이다.

## management/audit/cloudtrail.tf (34줄)

이 구성의 유일한 리소스, 조직 전체를 커버하는 organization trail을 정의한다. 세 계정 모두의 API 호출 기록이 이 트레일 하나를 통해 Log 계정 중앙 버킷으로 흘러들어 간다 — 독자가 Workload 계정에서 수행하는 모든 관리 작업의 감사 증적이 여기서 만들어진다.

### L1–34 · resource "aws_cloudtrail" "org"

- `name = var.cloudtrail_name` (L2) — "gochuchamchi-org-trail".
- `s3_bucket_name = var.log_archive_bucket_name` (L3) — 로그 목적지가 **다른 계정(Log 계정)의 버킷**이라는 점이 이 트레일의 핵심이다. 교차 계정 전달이 성립하려면 버킷 쪽 정책이 `cloudtrail.amazonaws.com` 서비스 주체의 `s3:PutObject`를 이 트레일 경로에 대해 허용해야 한다(그 정책은 log-archive 루트 소관 — 여기서도 루트 간 계약이 존재한다).
- `s3_key_prefix = var.cloudtrail_s3_key_prefix` (L4) — 버킷 내 "cloudtrail/" 접두사 아래로 로그를 몬다.
- `kms_key_id = var.log_archive_kms_key_arn` (L5) — 로그 파일 암호화용 KMS 키(Log 계정 소유). null이면 버킷 기본 암호화에 위임한다. 값을 지정할 경우 키 정책이 CloudTrail의 암호화 사용을 허용해야 하며, 이 키가 바로 `scp.tf` DenyLogKmsDestruction이 지키는 대상이다.
- `enable_logging = true` (L7) — 기록 활성 상태로 생성. false면 트레일은 있되 기록이 멈춘 상태가 된다.
- `enable_log_file_validation = true` (L8) — 로그 파일 무결성 검증(다이제스트 파일 체인) 활성화. 로그가 사후 변조되지 않았음을 암호학적으로 증명할 수 있게 해, Object Lock·SCP와 함께 "로그를 믿을 수 있다"는 주장의 세 번째 축을 이룬다.
- `include_global_service_events = true` (L9) — IAM·STS 같은 글로벌 서비스 이벤트 포함. 권한 변경 추적이 감사의 핵심이므로 필수다.
- `is_multi_region_trail = true` (L10) — 모든 리전의 이벤트를 수집한다. 주력 리전 밖에서 벌어지는 활동(전형적인 침해 징후: 안 쓰는 리전에서 리소스 생성)을 놓치지 않기 위한 설정이자, 조직 트레일의 표준 구성이다.
- `is_organization_trail = true` (L11) — 이 한 줄이 트레일을 조직 전체로 확장한다. 멤버 계정(Log·Workload)에 트레일이 자동 적용되고, 멤버 쪽에서는 읽기 전용으로만 보인다. 전제 조건이 둘이다: Management 계정에서 실행할 것(아래 precondition), 그리고 `organization.tf`의 `aws_service_access_principals`에 cloudtrail.amazonaws.com이 등록돼 있을 것.
- `event_selector` (L13–16) — `include_management_events = true`, `read_write_type = "All"`: 관리 이벤트(컨트롤 플레인 API 호출)를 읽기·쓰기 모두 기록한다. S3 객체 수준 같은 **데이터 이벤트는 넣지 않았다** — 데이터 이벤트는 볼륨·비용이 급증하므로, 학생 프로젝트의 비용 제약에서 관리 이벤트만으로 감사 목적을 달성하는 합리적 절충이다.
- `tags` (L18–24) — Name/Project/Environment("organization")/ManagedBy("Terraform")/Component("organization-cloudtrail"). 프로젝트 공통 태깅 규약으로, 비용 배분과 "이 리소스 누가 관리하나" 추적에 쓰인다.
- `lifecycle` (L26–33) — `prevent_destroy = true`로 감사 증적의 중단을 코드 레벨에서 차단하고, precondition으로 `data.aws_caller_identity.current.account_id == var.management_account_id`를 검사해 잘못된 프로파일 실행을 plan에서 끊는다. organization.tf와 동일한 이중 방어 패턴이다. 참고로 SCP(DenyWorkloadAuditTampering)는 멤버 계정 쪽 삭제 시도를 막고, 이 prevent_destroy는 Management 쪽 실수를 막는다 — 방향이 다른 두 방어가 짝을 이룬다.

## management/audit/outputs.tf (28줄)

트레일의 식별자와, 수집된 로그가 실제로 쌓이는 S3 경로를 인계하는 출력 2개다.

### L1–4 · output "org_trail_arn"

`aws_cloudtrail.org.arn`. Management 소유 organization trail의 ARN으로, log-archive 쪽 버킷 정책에서 `aws:SourceArn` 조건으로 이 트레일만 쓰기를 허용하게 하거나(혼동된 대리인 방지), 알림·문서에서 트레일을 특정할 때 쓴다.

### L6–28 · output "cloudtrail_s3_locations"

계정별 로그 경로 3개(management/log_archive/workload)를 맵으로 내보낸다. 각 항목은 `format("s3://%s/%s/AWSLogs/<ORG_ID>/%s/CloudTrail/", 버킷, 접두사, 계정ID)`로 조립되는데, organization trail의 실제 저장 구조가 `접두사/AWSLogs/<조직ID>/<계정ID>/CloudTrail/<리전>/...`이기 때문이다. `<ORG_ID>`가 리터럴 자리표시자로 남아 있는 점이 특징이다: audit 루트는 organization 루트의 상태를 읽지 않으므로(remote state 미사용 설계) 조직 ID를 알 수 없고, 사용자가 organization 출력의 `organization_id`로 치환해 완성하는 반쪽짜리 템플릿으로 의도됐다. 이 경로는 Log 계정에서 Athena 테이블·SIEM 수집기를 계정별로 붙일 때, 또 독자가 "내 Workload 계정 로그가 정확히 어디 쌓이나"를 확인할 때의 출발점이 된다.

---

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| management/organization/backend.tf | 10 | 1 | 전 블록 해설 (100%) |
| management/organization/providers.tf | 17 | 3 | 전 블록 해설 (100%) |
| management/organization/variables.tf | 62 | 8 | 전 블록 해설 (100%) |
| management/organization/organization.tf | 43 | 3 | 전 블록 해설 (100%) |
| management/organization/identity-center.tf | 60 | 8 | 전 블록 해설 (100%) |
| management/organization/scp.tf | 102 | 7 | 전 블록 해설 (100%) |
| management/organization/security-services.tf | 46 | 4 | 전 블록 해설 (100%) |
| management/organization/outputs.tf | 44 | 7 | 전 블록 해설 (100%) |
| management/audit/backend.tf | 10 | 1 | 전 블록 해설 (100%) |
| management/audit/providers.tf | 17 | 3 | 전 블록 해설 (100%) |
| management/audit/variables.tf | 48 | 9 | 전 블록 해설 (100%) |
| management/audit/cloudtrail.tf | 34 | 1 | 전 블록 해설 (100%) |
| management/audit/outputs.tf | 28 | 2 | 전 블록 해설 (100%) |
| **합계** | **521** | **57** | **13/13 파일** |


---

# log-archive (1) — 로그 중앙 수집·아카이브·Athena 분석 (Log 계정)

이 루트(`go/log-archive/`)는 3계정 구조에서 **Security/Log 계정(564186750363)** 에 배포되는 계층이다. 역할은 단 하나로 요약된다 — "Workload 계정에서 무슨 일이 일어나든, 그 증거(로그)는 Workload 자격증명이 손댈 수 없는 별도 계정에 불변(immutable)으로 보관하고, 조사할 수 있게 만든다." 공격자가 Workload 계정을 완전히 장악해도 CloudTrail·VPC Flow Logs·WAF·애플리케이션·EKS control-plane·RDS 감사 로그를 지우거나 조작할 수 없게 하는 것이 이 계정을 분리한 목적 그 자체다. 그래서 이 루트의 거의 모든 리소스는 (1) 쓰기 주체가 전부 "다른 계정"인 S3 버킷과 그 버킷을 지키는 정책/KMS/Object Lock, (2) 크로스 계정으로 로그를 받아내는 수신 파이프(CloudWatch Logs Destination → Firehose → S3), (3) 그렇게 쌓인 로그를 SQL로 조사하는 Athena 계층(Glue 테이블·Workgroup·저장 쿼리)의 세 덩어리로 나뉜다.

수집 경로의 핵심 패턴은 **`cloudwatch_log_archive_sources` 변수(정확히는 locals의 set) 한 줄 추가 → Firehose·S3 배송 경로·Logs Destination·Destination 정책·전달 상태 알람까지 자동 생성**이다. `log-archive.tf`의 for_each 체인이 이 자동화를 담당하고, 최근 "rds-audit"이 바로 이 패턴으로 추가되었다. 짝이 되는 발신 측 코드는 Workload 런타임 루트의 `go/terraform/log-archive-subscriptions.tf`(구독 필터)이며, **Log 계정이 Destination을 먼저 apply해야 Workload 구독 필터가 생성될 수 있다**는 순서 제약이 있다. 반대로 Workload가 매일 daily-up/down으로 생성·파괴되는 동안에도 이 루트는 상시 유지된다 — 로그 보존은 하루짜리 인프라가 아니기 때문이다.

이 문서는 log-archive 루트의 16개 파일(수집·아카이브·분석 코어)을 다룬다. 같은 루트에 있는 SIEM 5개 파일(`siem-detector.tf`, `siem-detection-rules.tf`, `siem-alerts.tf`, `security-events-view.tf`, `security-dashboard.tf`)은 이 코어가 쌓아둔 테이블 위에서 탐지를 돌리는 소비자 계층으로, 별도 섹션에서 다룬다.

---

## log-archive/providers.tf (49줄)

루트 전체의 실행 환경을 정의한다. Terraform/프로바이더 버전 고정, Log 계정 프로파일로 인증하는 기본(서울) 프로바이더와 WAF 전용 us-east-1 프로바이더, 그리고 전 파일이 공유하는 계정/조직 식별자 data 소스·locals가 여기 있다. 파일 상단 주석(L1–14)이 3계정의 역할과 "Workload/Management에서 이 계정 관리자 역할을 AssumeRole하는 신뢰 경로를 만들지 않는다"는 원칙을 못박는다 — 로그 계정으로 들어오는 사람 경로 자체를 없애 로그 무결성을 지키는 설계다.

### L16–25 · terraform { required_version, required_providers }

- `required_version = ">= 1.10"` — 1.10 미만이면 init 단계에서 실패시킨다. 1.10을 하한으로 잡은 실질적 이유는 `backend.tf`의 `use_lockfile = true`(S3 네이티브 잠금)가 Terraform 1.10에서 도입된 기능이기 때문이다. 버전을 안 박으면 팀원이 구버전으로 init해서 잠금 없이 state를 만지는 사고가 날 수 있다.
- `required_providers.aws = { source = "hashicorp/aws", version = "~> 6.0" }` — AWS 프로바이더 6.x 대로 고정한다. `~>`(pessimistic constraint)는 6.x 안에서의 마이너 업그레이드만 허용하고 7.0 같은 breaking major는 차단한다.

### L27–30 · provider "aws" (기본, 서울)

- `region = var.region` — 기본 `ap-northeast-2`. 버킷·Firehose·Athena 등 이 루트의 실체 대부분이 서울에 산다.
- `profile = var.log_profile` — 기본 `log-admin`. SSO 역할이 아니라 Log 계정의 IAM user 직접 프로파일을 쓴다. 이 선택은 뒤의 `log-archive.tf` L38(불변성 Deny 예외 ARN 기본값)과 맞물린다 — assume-role 세션 ARN은 매번 바뀌지만 IAM user ARN은 고정이라 Deny 예외 목록에 안전하게 들어갈 수 있다.

### L35–39 · provider "aws" (alias = "us_east_1")

CloudFront 범위(scope=CLOUDFRONT) WAF의 CloudWatch Logs 로그 그룹은 **us-east-1에만 존재**한다. CloudWatch Logs의 구독 Destination은 발신 로그 그룹과 같은 리전이어야 하므로, WAF용 Destination 하나만 버지니아에 만들기 위한 별칭 프로바이더다. `profile`은 같은 `log_profile` — 같은 계정의 다른 리전일 뿐이다. 이 alias는 `log-archive.tf`의 `aws_cloudwatch_log_destination.waf`와 `cloudwatch-monitoring-account.tf`의 us-east-1 OAM sink에서만 쓰인다. 핵심 절약 포인트: Destination만 버지니아에 두고 그것이 가리키는 Firehose/S3/Athena는 전부 서울에 유지한다(Destination의 target은 리전이 달라도 된다).

### L41 · data "aws_caller_identity" "current"

현재 자격증명의 계정 ID(564186750363)·ARN을 읽는다. 버킷 이름 접미사(`gochuchamchi-log-archive-${account_id}`), KMS 정책의 계정 루트 ARN, account-guard의 계정 검증, 불변성 Deny 예외 기본값(`.arn`) 등 루트 전역에서 참조된다. 계정 ID를 하드코딩하지 않고 실행 주체에서 읽되, account-guard가 "그 주체가 정말 Log 계정인가"를 별도로 강제한다.

### L44 · data "aws_organizations_organization" "current"

멤버 계정에서도 조회 가능한 Organization 정보를 읽어 org ID(`o-…`)를 얻는다. 주석대로 "Log 계정이 Organization에 가입한 뒤"에만 성립한다. org ID는 두 곳에서 결정적이다 — (1) org trail이 멤버 계정 로그를 쓰는 S3 경로 `AWSLogs/<org-ID>/<계정ID>/…`, (2) ALB 로그 버킷 정책의 `aws:SourceOrgId` 조건. 하드코딩 대신 data 소스로 읽으므로 조직을 재구성해도 코드는 그대로다.

### L46–49 · locals { org_id, workload_account_id }

`org_id`와 `workload_account_id`를 짧은 이름으로 재노출한다. `local.workload_account_id = var.workload_account_id`처럼 단순 별칭이지만, 전 파일에서 `var.` 대신 `local.`로 일관되게 참조하게 해 소스(변수든 data든)를 나중에 바꿔도 참조부가 흔들리지 않게 한다.

---

## log-archive/backend.tf (13줄)

state 저장 위치를 정의한다. 상단 주석(L1–3)이 격리 원칙을 명시한다 — 이 계층의 state는 Log 계정 전용 tfstate 버킷에 있고, Workload(828885965304)·Management(307223751140) 자격증명은 이 state에 접근하지 않는다. state 파일에는 버킷 정책·KMS 정책 전문이 들어가므로, state 접근 = 로그 방어선 설계도 열람이다. 계정별 state 분리는 그 자체가 보안 통제다.

### L4–13 · terraform { backend "s3" }

- `bucket = "gochuchamchi-tfstate-564186750363"` — Log 계정 소유 tfstate 버킷. 계정 ID를 이름에 박아 어느 계정 소유인지 이름만으로 드러낸다(부트스트랩 단계에서 계정마다 하나씩 만든 버킷).
- `key = "log-archive/terraform.tfstate"` — 같은 버킷을 쓰는 다른 루트와 경로로 격리한다.
- `region = "ap-northeast-2"` — backend 블록은 변수를 못 쓰므로(`var.` 참조 불가) 리터럴로 적는다.
- `profile = "log-admin"` — state 접근 자격증명도 본체와 같은 Log 계정 프로파일. 같은 이유로 리터럴이다.
- `encrypt = true` — state 객체 SSE 암호화. state에는 정책 전문 등 민감 정보가 들어가므로 필수에 가깝다.
- `use_lockfile = true` — DynamoDB 테이블 없이 S3 조건부 쓰기(conditional write)로 잠금을 거는 Terraform 1.10+ 네이티브 방식. 잠금용 DynamoDB 테이블을 계정마다 만들고 관리하는 비용을 없앤다. `providers.tf`의 `required_version >= 1.10`이 이 기능의 전제다.

---

## log-archive/variables.tf (87줄)

루트의 입력 9개. 대부분 default가 있어 tfvars 없이도 apply되지만, validation으로 실수 범위를 좁힌다. "계정 ID를 변수로 두되 validation으로 고정"하는 패턴이 반복된다 — 변수라서 문서화·참조가 깔끔하고, validation이라서 오입력이 원천 차단된다.

### L1–4 · variable "region"

기본 `ap-northeast-2`. 프로바이더 리전이자, Firehose·CloudTrail ARN 조립, Athena 쿼리의 `WHERE region = '...'` 조건 등에 두루 쓰인다.

### L6–10 · variable "log_profile"

기본 `log-admin`. Security/Log 계정의 AWS CLI 프로파일 이름. 이 값을 바꾸면 다른 자격증명으로 apply할 수 있지만 account-guard가 계정 자체는 검증한다.

### L12–21 · variable "management_account_id"

기본 `307223751140`, validation이 **정확히 이 값**만 허용한다(`condition = var.management_account_id == "307223751140"`). 사실상 상수를 변수로 둔 형태다. 이 ID는 org trail ARN 조립(`local.cloudtrail_arn`)과 CloudTrail 쓰기 경로(`AWSLogs/<management_id>/*`)에 쓰이는데, 잘못된 계정 ID가 들어가면 버킷·KMS 정책이 엉뚱한 Trail을 신뢰하게 되므로 validation으로 못박았다.

### L23–32 · variable "workload_account_id"

기본 `828885965304`. validation은 `can(regex("^\\d{12}$", ...))` — 12자리 숫자 형식만 검사한다. management와 달리 값 자체를 고정하지 않은 것은 Workload 계정이 교체될 수 있는 여지를 남긴 것이지만, 형식 검사로 오타(11자리 등)는 잡는다. Flow Logs·구독 필터 발신자 인가, Athena 경로(`AWSLogs/<workload>/...`), OAM sink 정책 등 크로스 계정 인가의 기준값이다.

### L34–43 · variable "cloudwatch_log_archive_retention_days"

기본 365. 중앙 S3의 총 보존 기간으로, 수명주기 `expiration.days`에 들어간다. validation `> 90` — 수명주기 전환이 30일(STANDARD_IA)→90일(GLACIER)이므로, 만료가 Glacier 전환(90일)보다 빠르면 전환 규칙이 무의미해지고 S3가 설정 충돌을 일으킬 수 있다. "만료는 마지막 전환보다 뒤"라는 제약을 코드로 강제한 것이다.

### L45–59 · variable "log_archive_object_lock_days"

기본 30. Object Lock COMPLIANCE 모드의 기본 보존 일수다. description이 이 프로젝트에서 가장 중요한 문장 중 하나를 담는다 — "이 기간 동안은 **루트를 포함한 누구도** 객체 버전을 삭제할 수 없다(8/4 §5.5에서 실증)". 구(舊) Workload 시절 버킷은 Object Lock을 생성 시점에 못 켜서 보류했던 설계("fin 라인")를, 신규 버킷을 만드는 지금 반영했다는 이력도 적혀 있다. validation `>= 1 && < 90` — 잠금 기간이 수명주기 만료·Glacier 전환보다 짧아야 만료 정리가 정상 동작한다(잠긴 버전은 수명주기가 못 지우고 건너뛰므로, 잠금이 만료보다 길면 정리가 계속 밀린다).

### L61–65 · variable "cloudwatch_log_archive_admin_arns"

기본 `[]`(빈 리스트). 로그 버킷의 불변성 Deny(`DenyObjectDeletion`/`DenyPolicyTampering`)에서 예외로 인정할 운영 주체 ARN 목록이다. 비워두면 `log-archive.tf` L38에서 apply 실행 주체(caller ARN)로 대체된다. list 타입인 이유: 운영자가 여럿이 될 수 있고, ArnNotLike 조건이 목록을 받기 때문이다.

### L67–76 · variable "athena_cloudtrail_projection_start_date"

기본 `"2026/08/10"`. CloudTrail·Flow Logs Athena 테이블의 파티션 프로젝션 시작일이다. 새 버킷에는 (2계정→3계정) 전환일 이후 로그만 있으므로 시작일을 전환일로 잡아, Athena가 존재하지도 않는 과거 날짜 경로를 스캔 대상으로 계산하지 않게 한다. validation은 `yyyy/MM/dd` 형식을 regex로 검사한다(월 01–12, 일 01–31 범위까지 패턴에 포함).

### L78–87 · variable "athena_alb_projection_start_date"

기본 `"2026/08/12"`. ALB 액세스 로그 테이블의 프로젝션 시작일. CloudTrail(8/10)과 별도 변수인 이유는 ALB 로그 수집이 이틀 늦게 시작됐기 때문이다 — 소스마다 "그 로그가 실제로 존재하기 시작한 날"을 정확히 반영하는 방식. validation은 위와 동일한 형식 검사다.

---

## log-archive/account-guard.tf (10줄)

"이 루트를 엉뚱한 계정 자격증명으로 apply하는 사고"를 plan 단계에서 차단하는 안전핀이다. 3계정 프로젝트에서 프로파일을 잘못 잡고 apply하면 Workload 계정에 로그 버킷이 만들어지는 식의 대형 사고가 나는데, 그걸 리소스 하나로 막는다.

### L1–10 · resource "terraform_data" "account_guard"

- `terraform_data`는 실물 인프라를 만들지 않는 Terraform 내장 리소스다(구 `null_resource`의 공식 대체). 여기서는 lifecycle precondition을 걸 "자리"로만 쓴다.
- `input = data.aws_caller_identity.current.account_id` — 현재 계정 ID를 값으로 저장한다. 계정이 바뀌면 리소스가 교체(replace)로 계획되어 diff에도 드러난다.
- `lifecycle.precondition` — `condition = data.aws_caller_identity.current.account_id == "564186750363"`. 조건이 거짓이면 plan/apply가 `error_message`("log-archive/는 Security/Log 계정 564186750363에서만 실행할 수 있습니다.")와 함께 즉시 실패한다. variable validation과 달리 **자격증명이 가리키는 실제 계정**을 검사한다는 점이 핵심이다 — 변수는 다 맞아도 프로파일이 틀린 경우를 잡는다.

---

## log-archive/kms-logs.tf (125줄)

중앙 로그 버킷(`gochuchamchi-log-archive-*`)을 암호화하는 Log 계정 전용 KMS CMK와 그 키 정책이다. 상단 주석(L1–10)이 배치 이력을 설명한다 — `../account-baseline/kms-logs.tf`에서 이식했고, 원본 키는 Workload 계정에 Config 버킷 전용으로 축소되어 남았으므로 "logs 키"는 계정마다 하나씩 총 2개다. 크로스 계정 관점의 차이도 명시한다: 암호화 요청이 Flow Logs는 Workload 계정에서, Org Trail은 Management 계정에서 오므로 각각 SourceAccount/SourceArn으로 발신자를 제한하고, Config는 Workload 자기 버킷을 쓰므로 여기서는 아예 허용하지 않는다.

### L12–23 · resource "aws_kms_key" "logs"

- `description` — 용도(CloudTrail/Firehose/Flow Logs 중앙 아카이브 암호화)를 콘솔에서 식별하게 한다.
- `enable_key_rotation = true` — 연 1회 자동 키 회전. CIS 벤치마크 항목이며 켜지 않을 이유가 없다.
- `deletion_window_in_days = 7` — 삭제 예약 대기 기간의 최소값. 주석대로 "실습 환경 최소값. 운영 전환 시 30일 권장"이다. 학생 프로젝트라 teardown 회전이 빨라 7일을 택했지만, 운영이라면 실수 삭제 복구 여유를 위해 30일이 맞다는 판단까지 코드에 남겼다.
- `policy = data.aws_iam_policy_document.kms_logs.json` — 아래 정책 문서. KMS는 리소스 정책(키 정책)이 1차 인가 경계라 여기가 사실상 이 키의 방화벽이다.
- `tags` — 공통 태그(`local.cloudwatch_log_archive_tags`)에 `Name = "gochuchamchi-logs-cmk"`를 merge.

### L25–28 · resource "aws_kms_alias" "logs"

`alias/gochuchamchi-logs`를 키에 붙인다. 키 ID(UUID)는 사람이 못 외우므로, 콘솔·CLI에서 별칭으로 참조하게 하는 관례적 리소스다. `target_key_id = aws_kms_key.logs.key_id`.

### L30–115 · data "aws_iam_policy_document" "kms_logs" — 키 정책 4문

**문 1 `EnableIAMPolicies` (L33–44)** — principal `arn:aws:iam::<이계정>:root`에 `kms:*` 전체 허용. "계정 루트 위임"이라 불리는 표준 문구로, 이게 있어야 이 계정의 IAM 정책 기반 접근(예: admin이 Athena로 KMS 암호화 로그를 읽는 것)이 동작한다. 주석이 경고하듯 이 문구가 없으면 키가 어떤 주체도 관리할 수 없는 "관리 불가(unmanageable)" 상태에 빠질 수 있다 — 키 정책이 유일한 인가 경로인 KMS 특유의 함정이다.

**문 2 `AllowCloudTrailEncrypt` (L47–67)** — 서비스 프린시펄 `cloudtrail.amazonaws.com`에 `kms:GenerateDataKey*`, `kms:DescribeKey` 허용. Org Trail이 로그 객체를 SSE-KMS로 쓸 때 데이터 키를 발급받는 권한이다. `kms:Decrypt`가 없다는 점이 의도적이다 — Trail은 쓰기만 하지 읽지 않는다. condition `aws:SourceArn = local.cloudtrail_arn` — **Management 계정 소유의 특정 Trail ARN**(`arn:aws:cloudtrail:<리전>:<management>:trail/gochuchamchi-org-trail`)에서 온 요청만 허용해, 다른 계정의 아무 Trail이 이 키로 위장 로그를 쓰는 confused deputy를 차단한다.

**문 3 `AllowLogDeliveryServices` (L70–90)** — 서비스 프린시펄 `delivery.logs.amazonaws.com`(VPC Flow Logs 등의 S3 배달 서비스)에 `kms:GenerateDataKey*`, `kms:Decrypt` 허용. Flow Logs의 parquet 배달은 멀티파트 처리 과정에서 Decrypt도 필요해 포함한다. condition `aws:SourceAccount = local.workload_account_id` — 배달을 일으킨 계정이 Workload일 때만. Trail처럼 ARN 단위가 아니라 계정 단위인 이유는 Flow Log 리소스가 daily-up/down으로 매일 재생성되어 ARN이 고정되지 않기 때문이다.

**문 4 `AllowProjectRoles` (L94–114)** — principal은 `AWS: "*"`로 열되, condition `StringLike aws:PrincipalArn = arn:aws:iam::<이계정>:role/gochuchamchi-*`로 좁힌다. 이 계정의 프로젝트 IAM 역할(실질적으로는 Firehose 전달 역할 `gochuchamchi-cloudwatch-log-archive-firehose`)이 버킷에 GZIP 객체를 쓸 때 필요한 `GenerateDataKey*`/`Decrypt`를 준다. 주석의 설계 이유가 중요하다 — **역할 ARN을 직접 참조하면 순환 의존**이 생긴다. 키 정책이 역할 ARN을 참조하고(키→역할), 역할은 키로 암호화된 버킷에 쓰기 위해 키를 참조하는(역할→키) 구조가 되므로, baseline과 동일하게 "이름 패턴 조건"으로 끊었다. 와일드카드 principal이지만 PrincipalArn 조건이 사실상의 principal 역할을 하는 관용 패턴이다.

### L122–125 · output "kms_logs_key_arn"

CMK ARN을 노출한다. Workload 쪽(`../terraform/flow-logs.tf` 등)이 remote state 없이 문서·검증 스크립트에서 참조하거나, 사람이 확인하는 용도다.

---

## log-archive/log-archive.tf (710줄)

이 루트의 심장이다. 중앙 로그 S3 버킷(Object Lock COMPLIANCE)과 그것을 지키는 버킷 정책, CloudWatch Logs를 받아 S3로 내리는 Firehose 4개, 그리고 크로스 계정 수신 창구인 Logs Destination까지 — 수집 파이프라인 전체가 한 파일에 있다. 상단 주석(L1–13)이 baseline(구 Workload 버전)과의 3대 차이를 요약한다: (1) Object Lock COMPLIANCE를 신규 생성 시점에 켰다(정책 Deny는 정책이 지워지면 사라지지만 Object Lock은 보존기간 동안 루트도 못 푼다), (2) 쓰기 허용 조건이 전부 크로스 계정이다, (3) Workload 구독 필터가 다른 계정 Firehose를 직접 못 가리키므로 Log Destination을 신설했다.

### L15–47 · locals — 소스 목록·태그·불변성 예외·CloudTrail 상수

이 파일에서 가장 중요한 블록이다. **소스 한 줄 → 리소스 자동 생성** 패턴의 원장(ledger)이 여기 있다.

- `cloudwatch_log_archive_sources = toset(["application", "control-plane", "rds-audit"])` (L21) — **서울 리전에서 구독 Destination까지 만들어 주는 소스 집합.** L16–20 주석이 최신 추가분 "rds-audit"(2026-08-12)의 의도를 기록한다: RDS 감사 로그(누가 접속해 어떤 DML/DDL/DCL을 실행했나)를 Workload에서 불변 중앙 버킷으로 받으며, 로그 그룹이 서울 리전이라 application/control-plane과 같은 그룹에 둔다(WAF만 us-east-1). **이 한 줄이 만들어내는 리소스**를 세어 보면 — 이 파일에서 Firehose 오류 로그 그룹 1 + 로그 스트림 1 + Firehose 스트림 1 + Logs Destination 1 + Destination 정책 1 = 5개, `firehose-monitoring.tf`에서 메트릭 필터 1 + 알람 3 = 4개, 합계 **리소스 9개**가 자동 생성되고, 여기에 Firehose IAM 정책·Destination IAM 정책·Destination 접근 정책의 for 표현식 리소스 목록이 자동 확장된다. 짝으로 `../terraform/log-archive-subscriptions.tf`에 구독 필터 한 줄, 그리고 원문 테이블이 필요하면 `rds-audit-analytics.tf` 같은 분석 파일을 수동으로 추가한다.
- `cloudwatch_log_delivery_sources = setunion(local.cloudwatch_log_archive_sources, toset(["waf"]))` (L24–27) — **Firehose/S3 배송까지 필요한 소스 집합(4개).** WAF를 별도 집합으로 뺀 이유는 Destination의 리전 때문이다: application/control-plane/rds-audit의 Destination은 서울, WAF Destination만 us-east-1이라 provider가 갈린다. 그래서 "Firehose·로그그룹·알람"은 delivery_sources(4개)로 돌리고, "서울 Destination"은 archive_sources(3개)로 돌리며, WAF Destination은 별도 리소스로 둔다. 집합 둘의 차이가 곧 리전 분기다.
- `cloudwatch_log_archive_tags` (L29–34) — Project/Environment/ManagedBy/Component 공통 태그. 루트 전 파일이 merge해서 쓴다.
- `cloudwatch_log_archive_admin_arns` (L38) — `length(var.cloudwatch_log_archive_admin_arns) > 0 ? var... : [data.aws_caller_identity.current.arn]`. 불변성 Deny의 예외 주체 목록으로, 변수를 비우면 **현재 apply를 돌리는 주체**가 들어간다. 주석이 전제를 명시한다 — log-admin은 IAM user 직접 프로파일이라 ARN이 고정이다. 만약 assume-role로 apply했다면 caller ARN이 STS 세션 ARN(`…:assumed-role/…/세션명`)이 되어 다음 세션부터 Deny에 걸리는 함정이 있는데, IAM user를 쓰는 운영 방식이 이를 회피한다.
- `cloudtrail_name`/`cloudtrail_s3_key_prefix`/`cloudtrail_arn` (L42–44) — Org Trail은 Management 계정 소유이고 `../management/audit`이 관리하므로, 이 루트는 Trail 리소스 없이 **ARN 문자열만 조립**한다: `arn:aws:cloudtrail:<리전>:<management계정>:trail/gochuchamchi-org-trail`. 버킷/KMS 정책은 이 ARN만 신뢰한다(L40–41 주석). remote state 참조 대신 결정적 ARN 조립을 쓰는 프로젝트 전반의 패턴이다.
- `vpc_flow_logs_s3_prefix = "vpc-flow-logs"` (L46) — Flow Logs 배달 경로의 최상위 접두사.

### L54–72 · resource "aws_s3_bucket" "cloudwatch_log_archive"

중앙 로그 버킷 본체.

- `bucket = "gochuchamchi-log-archive-${data.aws_caller_identity.current.account_id}"` — 계정 ID 접미사로 전역 유일성을 확보한다. 주석 두 가지가 중요하다: (1) 구 Workload 시절 버킷(`gochuchamchi-cloudwatch-log-archive-…`)과 **일부러 이름을 다르게** 둬서 구 인프라 teardown 진행 상황과 무관하게 충돌하지 않게 했다. (2) **이 이름은 `../terraform/flow-logs.tf`가 ARN 조립으로 재현한다 — 바꾸면 같이 바꿀 것.** 크로스 루트 결합이 문자열 규약으로 존재한다는 경고다.
- `object_lock_enabled = true` — **버킷 생성 시점에만 켤 수 있는** 속성(구 버킷이 못 켠 이유가 바로 이것). 켜면 versioning이 강제된다.
- `force_destroy = false` — `terraform destroy`가 객체가 남아 있는 버킷을 지우지 못하게 한다. 로그 버킷에서 true는 자기부정이다.

### L74–83 · resource "aws_s3_bucket_object_lock_configuration" "cloudwatch_log_archive"

- `rule.default_retention { mode = "COMPLIANCE", days = var.log_archive_object_lock_days }` — 새로 쓰이는 모든 객체 버전에 기본 30일 COMPLIANCE 보존을 건다. GOVERNANCE 모드는 `s3:BypassGovernanceRetention` 권한으로 우회 가능하지만 **COMPLIANCE는 루트 계정도 보존기간 내 삭제가 불가능**하다. "공격자가 Log 계정 관리자까지 탈취해도 최근 30일 로그는 못 지운다"가 이 한 블록으로 성립한다. 30일이라는 값은 variables.tf 해설대로 수명주기 만료(365일)·Glacier 전환(90일)보다 짧아야 한다는 제약에서 나왔다.

### L85–91 · resource "aws_s3_bucket_ownership_controls" "cloudwatch_log_archive"

`object_ownership = "BucketOwnerEnforced"` — ACL을 완전히 비활성화하고 버킷 소유자가 모든 객체를 소유한다. 크로스 계정 배달에서 "객체는 쓴 계정 소유라 버킷 주인이 못 읽는" 고전적 함정을 원천 차단한다. (아래 버킷 정책의 `s3:x-amz-acl` 조건은 배달 서비스가 여전히 그 헤더를 보내므로 그대로 동작한다.)

### L93–100 · resource "aws_s3_bucket_public_access_block" "cloudwatch_log_archive"

4개 플래그(`block_public_acls`/`block_public_policy`/`ignore_public_acls`/`restrict_public_buckets`) 전부 true — 퍼블릭 노출 전면 차단 표준 세트다. 로그 버킷이 공개될 정당한 시나리오는 없다.

### L102–108 · resource "aws_s3_bucket_versioning" "cloudwatch_log_archive"

`status = "Enabled"`. Object Lock이 버전 단위로 잠그므로 versioning은 전제 조건이다(버킷 생성 시 이미 강제되지만 Terraform 리소스로 명시해 state 관리 하에 둔다). 뒤의 object_lock_configuration·lifecycle_configuration이 이 리소스에 depends_on을 걸거나(ALB 버킷 쪽) 순서를 의존한다.

### L110–120 · resource "aws_s3_bucket_server_side_encryption_configuration" "cloudwatch_log_archive"

- `sse_algorithm = "aws:kms"`, `kms_master_key_id = aws_kms_key.logs.arn` — 기본 암호화를 우리 CMK(SSE-KMS)로. AES256(SSE-S3)이 아닌 CMK를 쓰는 이유는 **키 정책이 추가 인가 계층**이 되기 때문이다 — 버킷 정책을 뚫어도 키 정책이 막는다.
- `bucket_key_enabled = true` — S3 Bucket Key. 객체마다 KMS API를 부르지 않고 버킷 수준 데이터 키를 재사용해 **KMS 요청 비용을 크게 절감**한다(주석 그대로). Firehose가 5분마다 객체를 쓰는 워크로드에서 실질적인 비용 차이를 만든다.

### L122–157 · resource "aws_s3_bucket_lifecycle_configuration" "cloudwatch_log_archive"

규칙 1개(`archive-cloudwatch-logs`, Enabled)로 전체 버킷(`filter.prefix = ""`)을 다룬다.

- `transition` 30일 → `STANDARD_IA`, 90일 → `GLACIER` — "최근 로그는 자주 조회(Athena), 오래된 로그는 규정 보관"이라는 접근 패턴에 맞춘 계단식 비용 절감. IA 최소 보관 30일 제약과도 맞는다.
- `expiration.days = var.cloudwatch_log_archive_retention_days`(365) — 1년 후 현재 버전 만료.
- `noncurrent_version_expiration.noncurrent_days = 30` — 비최신 버전은 30일 후 정리. L147–148 주석이 Object Lock과의 상호작용을 설명한다: **수명주기는 잠긴 버전을 지우지 못하고 건너뛰었다가, 잠금(30일)이 풀린 뒤에 정리한다.** 그래서 잠금 30일·비최신 정리 30일 조합이 충돌 없이 맞물린다.
- `depends_on = [versioning]` — 버전 관리가 켜진 뒤에 noncurrent 규칙이 의미를 갖도록 순서를 명시한다.

### L164–365 · data "aws_iam_policy_document" "cloudwatch_log_archive_bucket" — 버킷 정책 7문

L161 주석이 요지를 박는다 — "쓰기 주체가 전부 '다른 계정'인 것이 baseline과의 차이".

**문 1 `DenyInsecureTransport` (L165–188)** — principal `*`, `s3:*` 전체를 `aws:SecureTransport = false` 조건으로 Deny. 평문 HTTP 접근 전면 금지. 버킷·객체 ARN 둘 다 대상이다(버킷 수준 API와 객체 API가 리소스가 다르므로 둘 다 적어야 완전하다).

**문 2 `AWSCloudTrailAclCheck` (L190–214)** — `cloudtrail.amazonaws.com`에 버킷 ARN 대상 `s3:GetBucketAcl` 허용. CloudTrail은 배달 시작 전에 버킷 ACL을 확인하는 프로토콜을 갖는다(고전 관례). condition `aws:SourceArn = local.cloudtrail_arn`으로 **우리 org trail에서 비롯된 확인 요청만** 허용 — 타 계정 Trail이 이 버킷을 배달 대상으로 지정하는 것 자체를 막는다.

**문 3 `AWSCloudTrailWrite` (L221–252)** — `cloudtrail.amazonaws.com`에 `s3:PutObject` 허용. **resources가 두 갈래**인 것이 org trail의 핵심 함정이다(L216–220 주석):
  - `…/cloudtrail/AWSLogs/<management계정ID>/*` — Management 계정 **자신의** 이벤트 경로
  - `…/cloudtrail/AWSLogs/<org-ID>/*` — **멤버 계정(워크로드) 이벤트** 경로(`AWSLogs/o-xxxx/<계정ID>/…`)

  둘 다 열어야 org trail 생성이 통과된다. 조사 대상의 대부분(워크로드 이벤트)은 두 번째 경로로 오고, `athena.tf`의 테이블이 그 경로를 본다. condition 두 개 — `s3:x-amz-acl = bucket-owner-full-control`(배달 객체 소유권 관례 헤더 강제), `aws:SourceArn = local.cloudtrail_arn`(우리 Trail 한정).

**문 4 `AWSLogDeliveryAclCheck` (L255–277)** — `delivery.logs.amazonaws.com`(Flow Logs 배달 서비스)에 `s3:GetBucketAcl` 허용, condition `aws:SourceAccount = local.workload_account_id`. 문 2의 Flow Logs 판이다 — 보내는 쪽이 이제 Workload 계정이므로 계정 조건이 붙는다.

**문 5 `AWSLogDeliveryWrite` (L279–307)** — 같은 서비스에 `s3:PutObject`를 `…/vpc-flow-logs/AWSLogs/<workload계정ID>/*` 경로 한정으로 허용. condition은 `s3:x-amz-acl = bucket-owner-full-control` + `aws:SourceAccount = workload`. 경로에 계정 ID가 박혀 있으므로 다른 계정의 Flow Logs가 이 접두사로 위장 배달하는 것도 불가능하다.

**문 6 `DenyObjectDeletion` (L316–339)** — principal `*`에 `s3:DeleteObject`/`s3:DeleteObjectVersion` Deny, condition `ArnNotLike aws:PrincipalArn = local.cloudwatch_log_archive_admin_arns`(예외 목록에 없는 모든 주체). L309–315 주석이 Object Lock과의 역할 분담을 정리한다: **Object Lock은 "보존기간 내 버전 삭제"만 막는다. 이 Deny는 보존기간이 지난 객체의 API 삭제까지 막는다**(수명주기 만료에 의한 자동 정리는 버킷 정책 평가를 받지 않으므로 영향 없음). 그리고 결정적인 문장 — "워크로드 계정 주체는 여기 예외 목록에 없으므로 구조적으로 차단된다. 이 계층을 분리한 목적 그 자체."

**문 7 `DenyPolicyTampering` (L341–364)** — 같은 예외 구조로 `s3:PutBucketPolicy`/`s3:DeleteBucketPolicy` Deny. 정책 Deny의 약점("정책을 지우면 Deny도 사라진다")을 정책 스스로 보완한다 — 정책 변경 권한 자체를 admin ARN 외 전원에게 거부. Object Lock(정책과 무관하게 동작)과 이 문이 이중 방어를 이룬다.

### L367–375 · resource "aws_s3_bucket_policy" "cloudwatch_log_archive"

위 문서를 버킷에 부착한다. `depends_on = [ownership_controls, public_access_block]` — BucketOwnerEnforced·퍼블릭 차단이 자리 잡기 전에 정책이 먼저 붙는 레이스를 막는 순서 고정이다.

### L382–389 · resource "aws_cloudwatch_log_group" "cloudwatch_log_archive_firehose" (for_each)

`for_each = local.cloudwatch_log_delivery_sources` — **4개**(application/control-plane/rds-audit/waf) 생성. Firehose 자신의 배달 오류 로그를 받을 그룹으로, 이름은 `/aws/kinesisfirehose/gochuchamchi-<소스>-log-archive`(Firehose 콘솔 관례 경로). `retention_in_days = 14` — 오류 로그는 진단용이라 짧게 보존한다(중앙 아카이브 365일과 대비되는 값). 이 로그 그룹은 `firehose-monitoring.tf`의 메트릭 필터가 다시 구독한다.

### L391–396 · resource "aws_cloudwatch_log_stream" "cloudwatch_log_archive_firehose" (for_each)

각 그룹 안에 스트림 `S3Delivery`를 만든다. Firehose의 `cloudwatch_logging_options`는 로그 그룹·스트림 이름을 명시적으로 요구하며 스트림을 스스로 만들지 않으므로 미리 만들어 둔다. 이름 `S3Delivery`는 Firehose가 쓰는 관례 이름이다.

### L403–419 · data "aws_iam_policy_document" "cloudwatch_log_archive_firehose_assume_role"

Firehose 전달 역할의 신뢰 정책 — `firehose.amazonaws.com` 서비스가 `sts:AssumeRole` 가능. 단순한 서비스 신뢰 문서다.

### L421–426 · resource "aws_iam_role" "cloudwatch_log_archive_firehose"

이름 `gochuchamchi-cloudwatch-log-archive-firehose`. **4개 Firehose가 이 역할 하나를 공유한다** — 소스별 역할 분리 대신 단일 역할로 관리를 단순화했다(어차피 대상 버킷이 같다). 이름이 `gochuchamchi-*` 패턴이라 `kms-logs.tf` 문 4(AllowProjectRoles)의 PrincipalArn 조건에 걸려 KMS 사용 권한을 얻는다 — 이름 규약이 인가의 일부다.

### L428–461 · data "aws_iam_policy_document" "cloudwatch_log_archive_firehose"

역할의 권한 정책 2문.

- `WriteLogArchiveBucket` (L429–446) — 버킷·객체에 `s3:AbortMultipartUpload`/`GetBucketLocation`/`GetObject`/`ListBucket`/`ListBucketMultipartUploads`/`PutObject`. AWS 문서가 Firehose S3 destination에 요구하는 정확한 최소 액션 세트다(대용량 객체는 멀티파트로 쓰므로 Abort/List 계열이 필요하다).
- `WriteFirehoseErrorLogs` (L448–460) — `logs:PutLogEvents`를 **for 표현식**으로 조립한 리소스 목록에 허용: `for log_group in values(aws_cloudwatch_log_group...) : "${log_group.arn}:log-stream:*"`. 소스가 늘면 이 목록도 자동으로 늘어난다 — for_each 패턴이 IAM 정책까지 관통하는 지점이다.

### L463–467 · resource "aws_iam_role_policy" "cloudwatch_log_archive_firehose"

위 문서를 인라인 정책으로 역할에 부착한다. 관리형 정책 대신 인라인인 것은 이 역할 전용 정책이라 재사용 필요가 없기 때문이다.

### L474–537 · resource "aws_kinesis_firehose_delivery_stream" "cloudwatch_log_archive" (for_each)

`for_each = local.cloudwatch_log_delivery_sources` — **파이프라인 본체 4개**. `name = "gochuchamchi-<소스>-log-archive"`, `destination = "extended_s3"`(파티셔닝·처리·오류 접두사를 지원하는 확장 S3 모드).

`extended_s3_configuration` 내부 인자:

- `role_arn`/`bucket_arn` — 위 공유 역할과 중앙 버킷.
- `prefix` (L484–490) — `join`으로 조립한 `cloudwatch/<소스>/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/`. `!{timestamp:…}`는 Firehose 네임스페이스 치환자(도착 시각 기준, UTC)다. **`year=`/`month=` 같은 Hive 스타일 키=값 폴더**로 쓰는 이유는 Athena 파티션 프로젝션의 `storage.location.template`(각 analytics 파일)과 문자 그대로 일치시키기 위해서다 — 여기서 경로 형식이 어긋나면 Athena가 0건을 읽는다. 소스별 접두사(`cloudwatch/application/` 등)가 곧 테이블 분리 기준이다.
- `error_output_prefix` (L492–498) — 처리 실패 레코드를 `firehose-errors/<소스>/<오류유형>/year=…/month=…/day=…/`로 격리한다. `!{firehose:error-output-type}`이 오류 종류(processing-failed 등) 폴더를 만든다. 실패분이 정상 데이터 경로에 섞이면 Athena 테이블이 오염되므로 반드시 분리한다.
- `buffering_size = 5`(MB) / `buffering_interval = 300`(초) — "5MB가 차거나 5분이 지나면" 객체 하나를 쓴다. 로그량이 적은 학생 프로젝트에서는 사실상 5분 주기 배출이다. 값이 작을수록 실시간성이 좋지만 작은 객체가 많아져 S3 요청 비용과 Athena 스캔 효율이 나빠진다 — 300초는 그 절충이며, `firehose-monitoring.tf`의 freshness 알람 임계(900초 = 버퍼 주기의 3배)와 짝을 이룬다.
- `compression_format = "GZIP"` / `file_extension = ".log.gz"` — 저장 비용·Athena 스캔 바이트를 줄인다(모든 analytics 테이블이 `compressed = true`로 이를 전제한다). 확장자를 명시해 gunzip 도구·콘솔 미리보기와의 호환을 확보한다.
- `processing_configuration` (L506–521) — **이 파이프라인의 데이터 형태를 결정하는 블록.** CloudWatch Logs 구독이 Firehose로 보내는 payload는 "gzip 압축된 CloudWatch 이벤트 봉투(JSON: owner/logGroup/logEvents[…])"다. 프로세서 둘을 순서대로 적용한다:
  1. `type = "Decompression"` — 구독 payload의 gzip을 푼다.
  2. `type = "CloudWatchLogProcessing"` + `parameter_name = "DataMessageExtraction", parameter_value = "true"` — 봉투를 벗기고 **각 logEvent의 message 원문만 한 줄씩** 추출한다.

  이 덕분에 S3에는 "CloudWatch 래핑이 벗겨진 로그 원문"이 줄 단위로 쌓이고, Athena 테이블들이 (JSON이면 JsonSerDe로, 원문이면 한 컬럼 Regex로) 바로 읽을 수 있다. 이 프로세서가 없으면 모든 테이블 스키마를 봉투 구조로 짜야 했다.
- `cloudwatch_logging_options` (L523–527) — 자체 오류를 위에서 만든 그룹/스트림(`S3Delivery`)에 기록. 모니터링 파일의 메트릭 필터가 이걸 본다.
- `depends_on` (L532–536) — 역할 정책(권한 없이 스트림이 먼저 생겨 첫 배달이 실패하는 것 방지), 버킷 정책, SSE 구성이 먼저 완성되도록 고정한다.

### L550–580 · data "aws_iam_policy_document" "logs_destination_assume_role"

L540–548의 구획 주석이 크로스 계정 수신의 구조를 요약한다 — 같은 계정일 때는 구독 필터가 Firehose ARN을 직접 가리켰지만(구 baseline 방식), **크로스 계정에서는 반드시 Destination을 거쳐야 하며 인가가 두 단계로 갈린다**: destination policy("워크로드 계정이 이 destination을 구독해도 된다") / destination의 role("logs 서비스가 이 계정의 Firehose에 넣어도 된다"). 워크로드 쪽 구독 필터에는 role_arn을 넣지 않는다(수신 계정 역할이므로).

이 문서는 그 role의 신뢰 정책이다 — `logs.amazonaws.com`이 AssumeRole 가능하되, condition `ArnLike aws:SourceArn`으로 발신 Logs ARN을 4개로 제한한다: **Workload 계정과 이 계정(Log), 서울과 us-east-1의 조합 전부**. L566–568 주석이 이 특이한 목록의 이유를 설명한다 — `PutDestination`은 생성 시 **수신 계정에서 테스트 메시지**를 보내므로 발신(Workload)뿐 아니라 수신(Log) 계정의 Logs ARN도 허용해야 생성이 통과된다. 실제 구독 권한은 아래 destination access policy가 Workload로 제한하므로 여기의 폭은 위험하지 않다.

### L582–587 · resource "aws_iam_role" "logs_destination"

이름 `gochuchamchi-logs-destination`. 서울 3개 + WAF 1개, **모든 Destination이 공유하는 단일 역할**이다. IAM은 글로벌이므로 us-east-1 Destination도 같은 역할을 쓸 수 있다.

### L589–604 · data "aws_iam_policy_document" "logs_destination"

역할 권한 — `firehose:PutRecord`/`PutRecordBatch`를 **for 표현식으로 4개 Firehose 스트림 ARN 전부**에 허용(`for stream in values(aws_kinesis_firehose_delivery_stream...)`). 소스 추가 시 자동 확장되는 세 번째 지점이다.

### L606–610 · resource "aws_iam_role_policy" "logs_destination"

위 문서를 인라인 부착.

### L614–622 · resource "aws_cloudwatch_log_destination" "cloudwatch_log_archive" (for_each)

`for_each = local.cloudwatch_log_archive_sources` — **서울 Destination 3개**(application/control-plane/rds-audit). `name = "gochuchamchi-<소스>-log-archive"`, `role_arn`은 공유 역할, `target_arn`은 같은 키의 Firehose. `depends_on = [aws_iam_role_policy.logs_destination]` — 역할에 Firehose 쓰기 권한이 붙기 전에 Destination이 생성 검증(테스트 전송)을 시도해 실패하는 것을 막는다. L612–613 주석의 경고가 중요하다 — **이 이름은 `../terraform/log-archive-subscriptions.tf`가 ARN 조립(`arn:aws:logs:…:destination:gochuchamchi-<소스>-log-archive`)으로 참조한다. 바꾸면 그쪽 조립식도 함께 바꿀 것.** remote state 대신 이름 규약으로 두 루트를 잇는 프로젝트 패턴의 대표 사례다.

### L624–643 · data "aws_iam_policy_document" "logs_destination_access"

Destination 접근 정책(두 단계 인가의 첫째) — principal `AWS: local.workload_account_id`(계정 전체)에 `logs:PutSubscriptionFilter` 허용, resources는 for 표현식으로 서울 Destination 3개 ARN. 즉 "Workload 계정이라면 이 3개 창구에 구독 필터를 걸 수 있다". 계정 단위로 연 것은 daily-up/down으로 Workload 쪽 주체가 매일 바뀌기 때문이다.

### L645–650 · resource "aws_cloudwatch_log_destination_policy" "cloudwatch_log_archive" (for_each)

`for_each = aws_cloudwatch_log_destination.cloudwatch_log_archive` — 리소스 맵 자체를 for_each로 받아 Destination마다 위 정책을 부착한다. `destination_name = each.value.name`, `access_policy`는 공통 문서. **Log 계정이 이 정책까지 apply해야 Workload 구독 필터 생성이 성공한다** — 순서 제약이 물리적으로 걸리는 지점이다.

### L654–662 · resource "aws_cloudwatch_log_destination" "waf" (us_east_1)

`provider = aws.us_east_1` — WAF 전용 Destination만 버지니아에 만든다. L652–653 주석: CloudFront WAF 로그 그룹과 Destination은 같은 리전이어야 하지만, **Destination이 가리키는 Firehose는 서울에 있어도 된다**(`target_arn = ...cloudwatch_log_archive["waf"].arn`). 즉 로그는 us-east-1 → 서울 Firehose → 서울 S3로 흐른다. 리소스를 이중으로 만들지 않는 비용 절약 포인트다.

### L664–677 · data "aws_iam_policy_document" "logs_destination_access_waf"

서울판과 동일 구조의 WAF 전용 접근 정책 — Workload 계정에 `logs:PutSubscriptionFilter`, 대상은 WAF Destination ARN 하나.

### L679–684 · resource "aws_cloudwatch_log_destination_policy" "waf"

`provider = aws.us_east_1`로 WAF Destination에 정책 부착. Destination 정책은 Destination과 같은 리전 API로 관리해야 하므로 provider를 맞춘다.

### L691–710 · output 3종

- `cloudwatch_log_archive_bucket_name`/`cloudwatch_log_archive_bucket_arn` — 중앙 버킷 이름/ARN.
- `cloudwatch_log_destination_arns` (L701–710) — 서울 Destination 맵(`{application=…, control-plane=…, rds-audit=…}`)에 `{ waf = … }`를 merge한 **소스명→Destination ARN 맵**. description이 명시하듯 Workload 구독 필터가 가리킬 값이며, `terraform/`은 이 output을 읽는 대신 ARN을 조립로 재현한다 — output은 검증·문서화 용도다.

---

## log-archive/cloudtrail.tf (17줄)

파일 이름과 달리 지금은 Trail 리소스가 없다 — Organization Trail이 Management 계정의 `../management/audit`으로 **이관된 흔적**을 state 수준에서 처리하는 파일이다. 상단 주석(L1–5)이 절차를 기록한다: 기존 2계정 시절 state에 Trail이 들어 있는 경우, 실물을 삭제하지 않고 Log state에서만 분리한 뒤 Management audit state로 동일 Trail을 import한다.

### L6–12 · removed { from = aws_cloudtrail.org }

Terraform 1.7+의 `removed` 블록 — `terraform state rm`을 코드로 선언하는 기능이다. `from = aws_cloudtrail.org`(이 루트가 예전에 관리하던 주소)를 state에서 제거하되, `lifecycle { destroy = false }`로 **실물 Trail은 파괴하지 않는다**. CLI 명령 대신 코드로 남긴 덕에 "Trail이 왜 이 state에 없는가"가 이력으로 추적된다. 소유권 이전(state 수술)의 모범 패턴이다.

### L14–17 · output "cloudtrail_s3_location_workload"

Workload 계정 이벤트가 쌓이는 S3 기본 경로를 조립해 노출한다 — `s3://<중앙버킷>/cloudtrail/AWSLogs/<org-ID>/<workload계정ID>/CloudTrail/`. org trail의 멤버 계정 경로(org-ID 포함)를 그대로 보여주는 문서화 output으로, Athena 테이블(`athena.tf`)이 읽는 위치와 일치한다.

---

## log-archive/athena.tf (374줄)

Athena 분석 계층의 뼈대다 — 쿼리 결과 전용 S3 버킷, Glue 데이터베이스, CloudTrail 테이블, Workgroup, 저장 쿼리 3개가 여기 있고, 나머지 analytics 파일들은 전부 이 파일의 데이터베이스·Workgroup 위에 테이블과 쿼리를 얹는다. 상단 주석(L1–12)이 두 가지를 못박는다: (1) `../account-baseline/athena.tf`에서 이식했고 **전환일 이전 로그는 워크로드 계정 Athena(구 버킷)에 남는다** — 조회 창구가 날짜 기준으로 두 계정에 갈린다는 runbook 사항. (2) org trail의 경로 이원화 — Management 자신의 이벤트는 `AWSLogs/<계정ID>/CloudTrail/…`, 멤버(워크로드) 이벤트는 `AWSLogs/<org-ID>/<워크로드계정ID>/CloudTrail/…`로 오는데, 조사 대상의 대부분이 워크로드 이벤트라 **테이블은 워크로드의 org 경로만 잡는다**. Management 자신의 이벤트가 필요하면 앞 경로로 테이블을 하나 더 만들면 된다는 확장 방향까지 주석에 있다.

### L14–62 · locals — 이름·경로·CloudTrail 스키마 원장

- `athena_security_database_name = "gochuchamchi_security_logs"` / `athena_cloudtrail_table_name = "cloudtrail_logs"` / `athena_workgroup_name = "gochuchamchi-security-logs"` (L15–17) — 분석 계층 전체가 공유하는 이름 3종. Glue 데이터베이스 이름에 하이픈이 아닌 언더스코어를 쓰는 것은 Athena(HiveQL) 식별자 규칙 때문이다.
- `cloudtrail_s3_base_prefix` (L19) — `cloudtrail/AWSLogs/<org-ID>/<워크로드계정ID>/CloudTrail`을 조립한다. `log-archive.tf`의 `cloudtrail_s3_key_prefix`("cloudtrail")와 providers.tf의 org ID data 소스가 여기서 합류한다. 버킷 정책 문 3(AWSCloudTrailWrite)이 허용한 멤버 계정 쓰기 경로와 정확히 같은 문자열이다 — 쓰는 쪽 정책과 읽는 쪽 테이블이 같은 경로 규약을 공유한다.
- `cloudtrail_athena_columns` (L21–54) — **CloudTrail 이벤트 스키마 30컬럼의 원장.** AWS 공식 Athena용 CloudTrail DDL을 `{ name, type }` 객체 리스트로 옮긴 것으로, 아래 테이블의 `dynamic "columns"`가 이 리스트를 순회해 컬럼 블록을 찍어낸다. 주목할 타입들:
  - `useridentity` (L23–26) — 이 테이블에서 가장 깊은 중첩 struct다. `type`(IAMUser/AssumedRole/…), `principalid`, `arn`, `accountid`, `accesskeyid`, `username`에 더해 `sessioncontext.sessionissuer`(assume-role 세션이라면 **원래 역할**의 type/arn/username)와 `sessioncontext.attributes.mfaauthenticated`(MFA 여부), `webidfederationdata`(OIDC 연합)까지 내려간다. "누가 했나"를 묻는 모든 조사 쿼리가 이 struct를 파고들며, 저장 쿼리들의 `COALESCE(useridentity.arn, useridentity.username, useridentity.principalid) AS actor`가 대표 사용례다.
  - `requestparameters`/`responseelements`/`additionaleventdata` (L35–37) — 구조가 이벤트마다 다르므로 struct가 아닌 **string**으로 둔다. 필요할 때 쿼리에서 `json_extract`로 파고드는 전략 — 스키마를 고정하면 새 이벤트 유형에서 파싱이 깨진다.
  - `resources` (L41) — `array<struct<arn,accountid,type>>`. 이벤트가 건드린 리소스 목록.
  - `tlsdetails` (L53) — TLS 버전·cipher suite. 구식 TLS 접근 탐지 같은 규정 점검에 쓸 수 있다.
- `athena_tags` (L56–61) — 공통 태그에 `Component = "athena"`를 덮어쓴 병합. 루트 공통 태그의 Component를 계층별로 바꿔 다는 패턴이다.

### L69–82 · resource "aws_s3_bucket" "athena_results"

Athena 쿼리 결과 전용 버킷. **원본 로그 버킷과 반드시 분리한다** — 결과를 로그 버킷에 쓰면 Object Lock COMPLIANCE에 걸려 임시 파일이 30일간 안 지워지고, 결과 파일이 테이블 스캔 경로에 섞이는 오염도 생긴다.

- `bucket = "gochuchamchi-log-athena-results-<계정ID>"` — 주석(L70)대로 구 워크로드 시절의 `athena-results` 버킷과 충돌을 피하려고 `log-` 접두사를 끼웠다. 중앙 로그 버킷 이름을 구 버킷과 다르게 지은 것과 같은 이유다.
- `force_destroy = true` — 로그 버킷(`false`)과 정반대다. 쿼리 결과는 언제든 재실행으로 재생성할 수 있는 파생물이므로 프로젝트 정리 시 객체째 지워도 된다. **불변성이 필요한 것과 아닌 것을 버킷 단위로 갈라 정책을 달리한** 대비가 이 한 쌍에 드러난다.

### L84–90 · resource "aws_s3_bucket_ownership_controls" "athena_results"

`BucketOwnerEnforced` — 중앙 버킷과 동일한 ACL 비활성화 표준 세트의 일부. 결과 버킷은 크로스 계정 배달이 없지만 표준을 통일해 두는 쪽이 관리 부담이 적다.

### L92–99 · resource "aws_s3_bucket_public_access_block" "athena_results"

4개 플래그 전부 true — 중앙 버킷과 같은 퍼블릭 차단 표준 세트다.

### L101–109 · resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results"

`sse_algorithm = "AES256"` — 중앙 로그 버킷(SSE-KMS CMK)과 달리 **SSE-S3**다. 결과 버킷은 며칠짜리 임시 파생물이라 키 정책이라는 추가 인가 계층이 과하고, KMS 요청 비용을 붙일 이유도 없다. 데이터의 가치에 암호화 방식을 비례시킨 선택이며, 아래 Workgroup의 `encryption_option = "SSE_S3"`과 짝이 맞는다.

### L111–130 · resource "aws_s3_bucket_lifecycle_configuration" "athena_results"

규칙 `expire-athena-query-results` 하나. `filter.prefix = "results/"` — Workgroup이 결과를 쓰는 접두사만 대상으로 한다. `expiration.days = 7` — 결과는 일주일이면 수명이 끝난다는 판단. `abort_incomplete_multipart_upload.days_after_initiation = 7` — 실패한 멀티파트 업로드 조각이 과금 대상으로 남는 것을 청소한다(눈에 안 보이는 비용 누수를 막는 관례 설정).

### L132–155 · data "aws_iam_policy_document" "athena_results_bucket"

`DenyInsecureTransport` 1문 — principal `*`의 `s3:*`를 `aws:SecureTransport = false` 조건으로 Deny. 중앙 버킷 정책 문 1과 같은 문구다. 결과 버킷에는 크로스 계정 쓰기 주체가 없으므로 Allow 문 없이 HTTPS 강제만 남긴 최소 정책이다.

### L157–165 · resource "aws_s3_bucket_policy" "athena_results"

위 문서를 부착. `depends_on = [ownership_controls, public_access_block]` — 중앙 버킷과 동일한 순서 고정 패턴이다.

### L172–175 · resource "aws_glue_catalog_database" "security_logs"

**분석 계층 전체의 논리적 컨테이너.** `gochuchamchi_security_logs` 데이터베이스 하나에 CloudTrail·ALB·WAF·Flow Logs·앱·EKS·RDS 테이블 7개(+SIEM 뷰)가 전부 들어간다. 데이터베이스를 하나로 모은 덕에 크로스 소스 조인 쿼리(예: application 파일의 16번 WAF 상관분석)가 데이터베이스 전환 없이 성립한다.

### L177–233 · resource "aws_glue_catalog_table" "cloudtrail"

CloudTrail JSON을 읽는 외부 테이블. `table_type = "EXTERNAL_TABLE"` — Glue/Athena는 메타데이터만 갖고 실제 데이터는 S3에 있다(테이블을 지워도 데이터는 남는다).

`parameters` 블록이 이 테이블의 핵심인 **파티션 프로젝션** 설정이다:

- `EXTERNAL = "TRUE"` — Glue API 수준에서 외부 테이블임을 명시하는 관례 파라미터. `classification = "cloudtrail"` — Glue 크롤러·콘솔이 형식을 인식하는 힌트다.
- `"projection.enabled" = "true"` — 파티션 프로젝션 활성화. 파티션을 메타스토어에 등록(`MSCK REPAIR TABLE`이나 크롤러)하는 대신, **파티션 값의 규칙을 선언해 두면 Athena가 쿼리 시점에 존재 가능한 파티션을 계산**한다. Firehose·CloudTrail처럼 시간 단위 폴더가 무한히 늘어나는 데이터에서 파티션 등록 운영을 통째로 없애는 기능이며, 이 루트의 테이블 7개가 전부 이 방식이다.
- `"projection.region.type" = "injected"` (L189) — region 파티션은 **injected 타입**: 가능한 값 목록을 선언하지 않고, **쿼리 WHERE절에 반드시 등호 조건으로 값을 주입해야** 한다(안 주면 쿼리가 에러난다). org trail은 모든 리전의 이벤트를 리전별 폴더로 쌓으므로 값 목록을 열거하기 번거로운데, 조사 시엔 어차피 리전을 특정하므로 injected가 맞다. 저장 쿼리 3개가 전부 `WHERE region = '<리전>'`을 넣는 이유가 이것이다.
- `"projection.event_date.*"` (L190–194) — date 타입, `format = "yyyy/MM/dd"`(CloudTrail 배달 경로의 날짜 폴더 형식 그대로), interval 1 DAYS, `range = "${var.athena_cloudtrail_projection_start_date},NOW"` — 시작일(8/10, 3계정 전환일)부터 현재까지만 파티션 후보로 계산한다. variables.tf 해설대로 존재하지 않는 과거 경로를 후보에서 배제하는 최적화다.
- `"storage.location.template"` (L196) — `s3://<중앙버킷>/<base_prefix>/$${region}/$${event_date}/`. **`$${…}`는 Terraform 이스케이프**로, 렌더링 결과는 `${region}`이라는 리터럴이 되어 Athena의 치환자로 남는다(Terraform 보간과 Athena 치환이 같은 문법을 쓰는 충돌을 이렇게 푼다). CloudTrail 실제 경로가 `…/CloudTrail/ap-northeast-2/2026/08/12/…`이므로 region 다음에 날짜가 오는 이 템플릿과 정확히 맞는다.

`partition_keys` (L199–207) — `region`, `event_date` 둘 다 string. 프로젝션 파티션 키는 데이터 파일 안에 없고 **경로에서 오는 가상 컬럼**이다.

`storage_descriptor` (L209–232):

- `location` — 템플릿의 고정 접두사 부분. 프로젝션이 꺼진 도구가 볼 기본 위치이기도 하다.
- `input_format = "com.amazon.emr.cloudtrail.CloudTrailInputFormat"` — CloudTrail 전용 InputFormat. CloudTrail 배달 파일은 로그 한 줄이 아니라 `{"Records":[{…},{…}]}` **봉투 구조의 gzip JSON**이라, 이 InputFormat이 Records 배열을 풀어 이벤트 하나를 레코드 하나로 만들어 준다. 일반 TextInputFormat으로는 파일 전체가 한 레코드가 되어 못 읽는다.
- `output_format = HiveIgnoreKeyTextOutputFormat` — 외부 읽기 전용 테이블이라 실질 의미는 없지만 DDL 필수 항목이라 관례값을 적는다(이하 모든 테이블 공통).
- `compressed = true` — gzip 저장 전제.
- `dynamic "columns"` (L215–222) — locals의 30컬럼 리스트를 순회하며 `columns { name, type }` 블록을 생성한다. **리스트 한 줄 추가 = 컬럼 하나 추가**로 스키마 변경이 데이터화되어 있다.
- `ser_de_info` (L224–231) — `serialization_library = "org.apache.hive.hcatalog.data.JsonSerDe"`. InputFormat이 잘라준 이벤트 JSON 하나를 컬럼으로 매핑하는 SerDe다. CloudTrail 공식 DDL이 지정하는 hcatalog JsonSerDe를 그대로 쓴다(앱·WAF 테이블의 OpenX JsonSerDe와 다른 계열이라는 점은 해당 파일에서 다룬다).

### L240–275 · resource "aws_athena_workgroup" "security_logs"

쿼리 실행 환경을 강제하는 Workgroup. 개인 설정에 의존하지 않고 팀 전체의 결과 위치·암호화·비용 상한을 서버 측에서 고정하는 장치다.

- `enforce_workgroup_configuration = true` — **핵심 스위치.** 클라이언트가 자기 결과 위치·암호화 설정을 가져와도 Workgroup 설정이 이긴다. false면 아래 설정 전부가 "기본값 제안"으로 격하된다.
- `publish_cloudwatch_metrics_enabled = true` — 쿼리 스캔량·실행 시간 메트릭 발행. 비용 추적 근거가 된다.
- `bytes_scanned_cutoff_per_query = 1073741824` — **쿼리당 스캔 1 GiB 상한**(주석 그대로). Athena 과금이 스캔 바이트 비례($5/TB)이므로, 파티션 조건을 빼먹은 쿼리가 버킷 전체를 훑는 사고의 피해액을 구조적으로 제한한다. 한도 초과 시 쿼리가 중단된다.
- `engine_version.selected_engine_version = "AUTO"` — 엔진 버전 관리를 AWS에 위임.
- `result_configuration` — `output_location = s3://<결과버킷>/results/`(수명주기 filter.prefix와 일치), `expected_bucket_owner = <이 계정>`(결과 버킷이 다른 계정 소유로 바뀌치기되는 것을 방어하는 소유자 검증), `encryption_configuration.encryption_option = "SSE_S3"`(결과 버킷 기본 암호화와 일치).
- `force_destroy = true` — 실행 이력이 남은 Workgroup도 destroy 가능하게. 이력은 보존 대상이 아니라는 판단이다.
- `depends_on` — 결과 버킷의 정책·암호화·수명주기가 완성된 뒤 Workgroup이 생기도록 고정한다.

### L282–303 · resource "aws_athena_named_query" "recent_management_events"

저장 쿼리 1번. 이름 `01-recent-management-events` — **번호 접두사는 콘솔 정렬 규약**이다. 이 루트의 저장 쿼리 24개(01–24)가 파일별로 번호 대역을 나눠 갖는다: 01–03 CloudTrail, 04–06 Flow Logs, 07–08 WAF, 09–13·16 애플리케이션, 14–15 ALB, 17–20 RDS, 21–24 EKS. 콘솔에서 시나리오 순서대로 줄 세우기 위한 장치다.

쿼리 내용: 최근 7일간 현재 리전의 관리 이벤트 100건. `WHERE region = '${var.region}'`은 injected 파티션의 필수 조건이고, `event_date >= date_format(current_date - INTERVAL '7' DAY, '%Y/%m/%d')`는 **파티션 컬럼(string)을 날짜 형식 문자열과 사전순 비교**해 프로젝션 계산 범위를 7일로 좁힌다(yyyy/MM/dd는 사전순=시간순이라 성립하는 트릭이다). SELECT의 `COALESCE(useridentity.arn, useridentity.username, useridentity.principalid) AS actor`는 자격증명 유형마다 채워지는 필드가 달라도 "행위자" 한 컬럼으로 정규화한다. Terraform 보간으로 데이터베이스·테이블 이름을 심으므로 이름 변경도 쿼리에 자동 반영된다.

### L305–327 · resource "aws_athena_named_query" "failed_api_calls"

저장 쿼리 2번 — 같은 골격에 `AND errorcode IS NOT NULL`만 추가. AccessDenied·UnauthorizedOperation 등 실패 호출만 남긴다. 권한 탐색(enumeration) 시도는 성공보다 실패 기록에서 먼저 드러나므로 침해 조사의 1차 필터다.

### L329–350 · resource "aws_athena_named_query" "write_events"

저장 쿼리 3번 — `AND readonly = 'false'`로 리소스를 변경한 쓰기 이벤트만. SELECT에 `errorcode` 대신 `requestparameters`를 넣어 "무엇을 어떻게 바꿨나"를 바로 보게 했다. readonly가 string 타입이라 불리언이 아닌 문자열 `'false'`와 비교하는 것도 CloudTrail 스키마의 특징이다.

### L356–374 · output 4종

`athena_security_database_name` / `athena_cloudtrail_table_name` / `athena_security_workgroup_name` / `athena_query_results_bucket_name` — 데이터베이스·테이블·Workgroup·결과 버킷 이름. 검증 스크립트와 runbook이 콘솔 진입점을 확인하는 용도다.

---

## log-archive/alb-access-logs.tf (330줄)

ALB 액세스 로그만을 위한 **전용 버킷 + 테이블 + 저장 쿼리** 파일이다. 상단 주석(L1–7)이 전용 버킷이 필요한 이유를 명시한다 — **ALB 액세스 로그 배달은 SSE-S3만 지원**하므로 KMS(CMK) 암호화가 기본인 중앙 버킷에는 쓸 수 없다. 그래서 Log 계정 안에 SSE-S3 버킷을 따로 만들되 Object Lock COMPLIANCE + versioning으로 불변성 수준은 중앙 버킷과 동일하게 맞춘다. 수집 경로도 다르다 — 다른 소스들이 CloudWatch Logs→구독→Firehose를 타는 것과 달리 **ALB는 ELB 서비스가 S3에 직접 배달**한다(5분 주기). 이 버킷(`gochuchamchi-alb-access-logs-*`)은 Log 계정 소유라 Workload 자격증명으로는 콘솔에서 보이지 않는다 — "버킷이 안 보인다"는 팀원 질문의 답이 계정 분리 그 자체다.

### L9–57 · locals — 버킷·테이블 이름, 34컬럼, 공식 정규식

- `alb_access_log_bucket_name` (L10) — `gochuchamchi-alb-access-logs-<Log계정ID>`. **이 이름은 Workload 쪽 ALB 리소스의 `access_logs { bucket = … }` 설정이 문자열로 재현해야 한다** — Destination 이름과 같은 크로스 루트 이름 규약이다.
- `alb_access_log_prefix = "alb"` (L11) — 버킷 내 최상위 접두사. ALB 배달 규약이 이 밑에 `AWSLogs/<계정ID>/elasticloadbalancing/<리전>/yyyy/MM/dd/` 경로를 스스로 만든다.
- `alb_access_log_columns` (L14–48) — **ALB 액세스 로그 한 줄의 필드 34개.** AWS 공식 Athena DDL의 컬럼 순서 그대로다. 타입 선택이 로그 형식의 실상을 반영한다:
  - `client_port`/`target_port`는 int로 분리 — 로그에는 `IP:PORT` 한 토큰이지만 정규식 캡처가 둘로 쪼갠다.
  - `request_processing_time`/`target_processing_time`/`response_processing_time`은 double — 초 단위 소수이며, **-1은 타임아웃/연결실패**를 뜻하는 센티널 값이라 함께 수용해야 한다.
  - `elb_status_code`는 int인데 `target_status_code`는 **string** — 타깃에 도달 못 한 요청은 이 필드가 `-`라서 int로 두면 파싱이 깨진다. 저장 쿼리 15번이 `try_cast(target_status_code AS integer)`로 읽는 이유다.
  - `request_verb`/`request_url`/`request_proto` — 로그의 따옴표 친 `"GET https://… HTTP/2.0"` 한 필드를 정규식이 3분할한다.
  - 말미의 `classification`/`classification_reason`(desync 완화 분류), `conn_trace_id` — 최신 필드까지 반영한 목록이다.
- `alb_access_log_regex` (L53–56) — **RegexSerDe에 넣을 AWS 공식 정규식.** heredoc으로 적고 `trimspace`로 앞뒤 개행을 제거한다(개행이 남으면 정규식 자체가 달라진다). 캡처 그룹이 컬럼 순서대로 1:1 대응하며, 그룹 문법이 로그 형식의 예외를 흡수한다 — `([^ ]*):([0-9]*)`(client ip:port 분리), `([^ ]*)[:-]([0-9]*)`(target은 `-`일 수 있어 구분자가 `:` 또는 `-`), `(|[-0-9]*)`(빈 값 허용 상태 코드), `"([^ ]*) (.*) (- |[^ ]*)"`(요청 3분할). 주석(L51–52)이 마지막 `?( .*)?`(optional trailing group)의 존재 이유를 못박는다 — **ALB가 미래에 필드를 뒤에 추가해도 정규식 전체 매치가 실패하지 않게** 남는 꼬리를 삼키는 그룹이다. RegexSerDe는 정규식이 라인과 통째로 매치하지 않으면 **모든 컬럼을 NULL로** 만들기 때문에, 이 그룹 하나가 "새 필드 추가 = 테이블 전체 무용지물" 사고를 막는다.

### L59–68 · resource "aws_s3_bucket" "alb_access_logs"

`object_lock_enabled = true`, `force_destroy = false` — 중앙 로그 버킷과 동일한 불변 원장 설정. 생성 시점에만 켤 수 있는 Object Lock을 신규 버킷이라 처음부터 켰다. 태그에 `Component = "alb-access-logs"`를 덧붙인다.

### L70–76 · resource "aws_s3_bucket_ownership_controls" "alb_access_logs"

`BucketOwnerEnforced` — ALB 로그 배달은 역사적으로 ACL(`bucket-owner-full-control`) 기반이었지만, 신형 서비스 프린시펄 배달은 ACL 없이 동작하므로 ACL 전면 비활성화와 공존한다. 크로스 계정 배달 객체의 소유권이 버킷 주인(Log 계정)으로 강제되는 것이 핵심이다.

### L78–85 · resource "aws_s3_bucket_public_access_block" "alb_access_logs"

4개 플래그 전부 true — 표준 퍼블릭 차단 세트.

### L87–93 · resource "aws_s3_bucket_versioning" "alb_access_logs"

`status = "Enabled"` — Object Lock의 전제. 아래 두 리소스가 `depends_on`으로 이 리소스를 명시적으로 기다린다.

### L95–106 · resource "aws_s3_bucket_object_lock_configuration" "alb_access_logs"

중앙 버킷과 동일 — `mode = "COMPLIANCE"`, `days = var.log_archive_object_lock_days`(30). 같은 변수를 공유하므로 잠금 기간 정책이 버킷 두 개에서 한 곳으로 관리된다. `depends_on = [versioning]` — 버전 관리가 자리 잡기 전 잠금 설정이 붙는 레이스를 막는다.

### L108–116 · resource "aws_s3_bucket_server_side_encryption_configuration" "alb_access_logs"

`sse_algorithm = "AES256"` — 이 파일의 존재 이유가 압축된 한 줄이다. ALB 배달이 SSE-KMS를 못 쓰므로 SSE-S3가 상한이고, 대신 Object Lock·버킷 정책·계정 분리가 방어를 맡는다.

### L118–149 · resource "aws_s3_bucket_lifecycle_configuration" "alb_access_logs"

중앙 버킷과 같은 계단 — 30일 STANDARD_IA, 90일 GLACIER, `expiration = var.cloudwatch_log_archive_retention_days`(365), 비최신 버전 30일 정리. 차이는 `filter.prefix = "alb/"` — ALB 배달 경로 밑만 대상으로 한정한 것뿐이다. 보존 정책 변수를 중앙 버킷과 공유해 "로그 보존 1년"이라는 정책이 한 변수로 수렴한다.

### L151–200 · data "aws_iam_policy_document" "alb_access_logs_bucket" — 버킷 정책 2문

**문 1 `DenyInsecureTransport` (L152–172)** — 표준 HTTPS 강제 Deny. 중앙 버킷 문 1과 동일 구조다.

**문 2 `AllowWorkloadAlbLogDelivery` (L174–199)** — 이 버킷의 유일한 쓰기 허용 문이다.

- principal `Service: logdelivery.elasticloadbalancing.amazonaws.com` — **신형 ALB 로그 배달 서비스 프린시펄.** 구식(리전별 ELB AWS 계정 ID를 principal로 넣는 방식) 대신 서비스 프린시펄 + 조건 방식을 쓴다. 서울 리전의 신규 버킷 정책 관례다.
- `actions = ["s3:PutObject"]`, resources는 `…/alb/AWSLogs/<워크로드계정ID>/*` — **경로에 워크로드 계정 ID를 박아** 다른 계정 ALB가 이 접두사로 배달하는 것을 원천 차단한다(Flow Logs 문 5와 같은 수법).
- condition `StringEquals aws:SourceOrgId = <org-ID>` — 배달을 일으킨 계정이 **우리 Organization 소속**일 때만. providers.tf에서 읽은 org ID가 여기서 쓰인다.
- condition `ArnLike aws:SourceArn = arn:aws:elasticloadbalancing:<리전>:<워크로드>:loadbalancer/*` — 발신 리소스가 **워크로드 계정의 서울 리전 로드밸런서**일 때만. 계정·조직·리소스 세 겹으로 발신자를 좁힌 confused deputy 방어다. ALB가 daily-up/down으로 매일 재생성돼 이름이 바뀌므로 `loadbalancer/*` 와일드카드가 필요하다.

### L202–210 · resource "aws_s3_bucket_policy" "alb_access_logs"

정책 부착. `depends_on = [ownership_controls, public_access_block]` — 표준 순서 고정. **Workload 쪽에서 ALB의 access_logs를 켜기 전에 이 정책이 apply되어 있어야** ALB 설정 검증(테스트 객체 쓰기)이 통과한다 — Destination과 같은 "Log 계정 먼저" 순서 제약의 ALB 판이다.

### L212–263 · resource "aws_glue_catalog_table" "alb_access_logs"

ALB 로그를 읽는 외부 테이블. CloudTrail 테이블과의 차이가 곧 소스 형식의 차이다.

- `parameters` — `"projection.day.type" = "date"`, `format = "yyyy/MM/dd"`, `range = "${var.athena_alb_projection_start_date},NOW"`(8/12부터), interval 1 DAYS. **파티션이 day 하나뿐**이다 — ALB 배달 경로는 Firehose의 Hive 스타일(`year=…/month=…`)이 아니라 **평범한 날짜 폴더**(`…/ap-northeast-2/2026/08/12/파일`)라서, 다단 integer 파티션 대신 `yyyy/MM/dd` 전체를 date 타입 파티션 하나로 매핑하는 것이 정확하다. region 파티션이 없는 것도 경로에 리전이 고정 문자열(`var.region`)로 박혀 있기 때문이다.
- `"storage.location.template"` (L228) — `s3://<ALB버킷>/alb/AWSLogs/<워크로드>/elasticloadbalancing/<리전>/$${day}/`. 버킷 정책이 허용한 배달 경로와 문자 그대로 일치한다.
- `storage_descriptor` — `input_format = TextInputFormat`(gzip 텍스트 라인), `compressed = true`(ALB가 `.log.gz`로 배달), `dynamic "columns"`가 34컬럼 리스트를 전개, `ser_de_info.serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"` + `"input.regex" = local.alb_access_log_regex` — **정규식 캡처 그룹 순서 = 컬럼 선언 순서**라는 암묵 계약으로 파싱된다. 컬럼을 중간에 추가하면 그 뒤 전부가 어긋나므로, 스키마 변경은 반드시 목록 끝에 붙이고 정규식 그룹도 같이 늘려야 한다는 함정을 기억할 것.
- `depends_on = [aws_s3_bucket_policy.alb_access_logs]` — 배달 인가가 완성된 뒤 테이블이 생기도록 순서를 고정한다.

### L265–308 · locals — ALB 저장 쿼리 2종 정의

named query를 `{ 이름 = { description, query } }` 맵으로 데이터화한 블록이다(이 패턴은 이후 모든 analytics 파일에서 반복된다 — 쿼리 추가가 맵 항목 추가로 끝난다).

- `"14-alb-status-codes-24h"` — 최근 24시간 ALB/타깃 상태 코드 조합별 요청 수. WHERE가 2단이다: `day >= date_format(…)`이 **파티션 프루닝**(스캔 범위를 이틀로 축소)을 하고, `try(from_iso8601_timestamp(time)) >= current_timestamp - INTERVAL '24' HOUR`가 **정확한 24시간 경계**를 자른다. `time`이 string이라 파싱이 필요하고, 깨진 라인이 있어도 쿼리가 죽지 않도록 `try()`로 감싼다(실패 시 NULL → 조건 탈락).
- `"15-alb-error-request-details"` — 4xx/5xx 요청 상세. `(elb_status_code >= 400 OR try_cast(target_status_code AS integer) >= 400)` — ALB가 낸 오류와 타깃이 낸 오류를 모두 잡되, `-` 값은 try_cast가 NULL로 흘려보낸다. 처리 시간 3종·`trace_id`(X-Ray/추적 연계)·`classification`(desync 판정)까지 뽑아 지연·오류 조사를 한 쿼리로 끝낸다.

### L310–320 · resource "aws_athena_named_query" "alb_access_logs" (for_each)

`for_each = local.alb_access_log_named_queries` — **맵 항목 2개 → named query 리소스 2개.** `name = each.key`(번호 접두사 이름), 나머지는 공통 데이터베이스·Workgroup. `depends_on`으로 테이블이 먼저 생기게 한다. 이후 모든 analytics 파일이 이 리소스 골격을 복제한다.

### L322–330 · output 2종

`alb_access_log_bucket_name` — **Workload ALB의 access_logs 설정이 가리켜야 할 버킷 이름.** description이 그 용도를 명시한다. `athena_alb_access_log_table_name` — 테이블 이름. 둘 다 크로스 루트 이름 규약의 문서화 장치다.

---

## log-archive/application-logs-analytics.tf (386줄)

EKS 위 Spring 애플리케이션의 HTTP 접근·보안 감사 로그를 읽는 테이블과 저장 쿼리 6개다. 상단 주석(L1–7)이 이 파일 스키마 설계의 전제를 설명한다 — **EKS CloudWatch Observability add-on(Fluent Bit)은 컨테이너 stdout의 JSON 한 줄을 파싱해 `log_processed` 밑에 병합**한 봉투(`{log, stream, time, log_processed:{…}, kubernetes:{…}}`)로 CloudWatch에 넣는다. 그런데 수집기를 나중에 바꿔 **Spring JSON 원문이 그대로 오는 경우에도 테이블이 살아 있도록**, 같은 필드들을 루트 레벨 컬럼으로도 이중 선언한다. 이 이중화가 이 파일의 locals 절반과 COALESCE 정규화 SELECT의 존재 이유다.

### L9–112 · locals — 스키마 이중 선언과 쿼리 조각 재사용

- `athena_application_table_name = "application_logs"` / `application_logs_s3_prefix = "cloudwatch/application"` (L10–11) — 접두사가 Firehose `prefix`(`cloudwatch/application/year=…`)의 고정부와 일치한다. Firehose 해설에서 예고한 "경로 규약 = 테이블 분리 기준"의 수신 측이다.
- `application_event_struct_fields` (L13–36) — Spring 로그 이벤트의 필드 22개(`timestamp`, `eventcategory`, `eventtype`, `severity`, `requestid`, `cloudfrontrequestid`, `clientip`, `method`, `uri`, `useragent`, `principal`, `roles:array<string>`, `statuscode:int`, `responsetimems:bigint`, `outcome`, `exceptiontype`, `actoruserid:bigint`, `actorusername`, `targettype`, `targetid`, `reasoncode`, `details`)를 `"이름:타입"` 문자열 리스트로 두고 `join(",", …)`으로 합친다. struct 타입 문자열(`struct<a:string,b:int,…>`)을 한 줄에 그대로 쓰면 사람이 못 읽으니 **리스트로 펼쳐 두고 조립**하는 가독성 장치다. 필드 중 `cloudfrontrequestid`는 CloudFront가 붙인 요청 ID를 앱이 로그에 새긴 것으로, 16번 쿼리의 WAF 조인 키가 된다.
- `application_athena_columns` (L38–66) — 실제 테이블 컬럼 27개. 구성이 3층이다: (1) Fluent Bit 봉투 컬럼 `log`(원문 문자열)·`stream`(stdout/stderr)·`time`, (2) `log_processed`(위 struct 조립 결과)와 `kubernetes`(pod_name/namespace_name/container_name/host struct — 어느 파드가 낸 로그인지), (3) **루트 레벨 이중 선언 22개** — 수집기가 봉투 없이 Spring JSON을 그대로 배달하는 미래 구성 대비다. JSON SerDe는 문서에 없는 컬럼을 NULL로 채우므로 두 구성 중 한쪽 컬럼들은 항상 NULL이고, 그걸 아래 COALESCE가 봉합한다.
- `application_recent_partition` (L68–78) — **"오늘 OR 어제" 파티션 조건 SQL 조각.** year/month/day가 각각 독립 파티션이라 단순 부등호로 "최근 24시간"을 표현할 수 없다(월말·연말 경계에서 깨진다). 그래서 current_timestamp의 오늘 날짜와 어제 날짜를 각각 등호 3연으로 묶어 OR한 조건을 만들어, 파티션 프루닝을 이틀치로 좁힌 다음 정밀한 24시간 필터는 각 쿼리의 event_time 조건에 맡긴다. 이 조각은 EKS·RDS 파일에도 같은 이름 패턴으로 복제되는 이 루트의 표준 관용구다.
- `application_normalized_event_select` (L80–111) — **정규화 SELECT 조각.** 모든 필드를 `COALESCE(log_processed.X, X) AS x_snake_case`로 묶어 "봉투형이든 원문형이든 같은 컬럼 이름으로 나오는" 이벤트 뷰를 만든다. `COALESCE(log_processed.timestamp, "timestamp")`에서 루트 컬럼을 따옴표로 감싸는 것은 timestamp가 예약어이기 때문이다. `kubernetes.namespace_name`/`pod_name`과 파티션 컬럼(year~hour)도 함께 내보내, 아래 쿼리들이 전부 `WITH events AS (이 조각 + WHERE 파티션)` 골격으로 시작할 수 있게 한다. **SQL 재사용을 뷰가 아니라 Terraform 문자열 조각으로 푼 것**이 특징인데, 뷰 관리(Glue 뷰는 Terraform 지원이 불편) 없이 저장 쿼리에 인라인되는 대신, 조각을 고치면 쿼리 6개가 전부 갱신되는 장점이 있다.

### L114–188 · resource "aws_glue_catalog_table" "application_logs"

- `parameters` — `classification = "json"`. 프로젝션이 **year/month/day/hour 4단 integer**다: year `range = "2026,2036"`(10년 창)·`digits = "4"`, month `1,12`·`digits = "2"`, day `1,31`·`digits = "2"`, hour `0,23`·`digits = "2"`. `digits`는 폴더 이름의 zero-padding(`month=08`)과 맞추는 자릿수 선언으로, 이게 틀리면 경로 계산이 어긋나 0건이 나온다. CloudTrail 테이블의 date 타입과 달리 integer 4단인 이유는 **Firehose가 만든 Hive 스타일 경로(`year=2026/month=08/day=12/hour=09/`)** 그대로이기 때문이다 — Firehose `prefix` 해설에서 예고한 그 짝맞춤이다.
- `"storage.location.template"` — `s3://<중앙버킷>/cloudwatch/application/year=$${year}/month=$${month}/day=$${day}/hour=$${hour}/`.
- `partition_keys` 4개 — 전부 string 선언(프로젝션 타입은 integer지만 키 자체는 string으로 두는 관례).
- `storage_descriptor` — TextInputFormat + `compressed = true`(Firehose GZIP), `dynamic "columns"`로 27컬럼 전개. `ser_de_info.serialization_library = "org.openx.data.jsonserde.JsonSerDe"` — CloudTrail의 hcatalog JsonSerDe가 아니라 **OpenX JsonSerDe**다. 선택 이유는 `parameters`의 `"case.insensitive" = "true"`에 있다 — Spring 로그의 camelCase 키(`eventCategory`)를 Hive의 소문자 컬럼(`eventcategory`)에 대소문자 무시로 매핑해 준다. hcatalog SerDe에는 이 옵션이 없다. 애플리케이션이 만든 JSON(키 표기가 통제 밖)을 읽을 때는 OpenX, AWS가 만든 JSON(키가 고정)을 읽을 때는 공식 DDL의 SerDe — 이 루트의 SerDe 선택 기준이다.

### L190–361 · locals — 애플리케이션 저장 쿼리 6종 정의

모두 `WITH events AS (정규화 SELECT + 파티션 조건)` 골격에서 시작한다.

- `"09-application-status-codes-24h"` — `event_category = 'HTTP_ACCESS'` 이벤트를 상태 코드별 집계. 서비스 상태의 첫 화면 격 쿼리다.
- `"10-application-top-4xx-sources"` — 4xx를 많이 유발한 `client_ip × method × uri × status_code` 조합 상위 200. 4xx 다발은 크리덴셜 스터핑·경로 스캔의 흔적이라 "누가 어딜 두드리나"를 바로 보여준다. `MAX(event_time) AS last_seen`으로 최신성도 함께.
- `"11-application-5xx-errors"` — 5xx를 `uri × exception_type × pod_name`으로 집계. 예외 타입과 파드가 같이 나오므로 "코드 버그인가 특정 파드 문제인가"를 즉시 가른다. `MAX(response_time_ms)`로 타임아웃성 오류도 드러난다.
- `"12-application-security-failures"` — `event_category = 'SECURITY_EVENT'` 중 `outcome = 'FAILURE'` 또는 `event_type IN ('ACCESS_DENIED','ACCESS_BLOCKED')`. 로그인 실패·권한 거부·차단을 시간 역순으로 500건. `COALESCE(actor_username, principal) AS actor` — 인증 전 이벤트는 username이 없어 principal로 대체한다. `request_id`·`cloudfront_request_id`를 함께 뽑아 다른 로그와의 상관 추적 고리를 남긴다.
- `"13-application-high-critical-events"` — severity HIGH/CRITICAL의 권한·계정 변경 이벤트. `target_type`/`target_id`(무엇이 변경됐나)가 12번과의 차이다.
- `"16-waf-allow-application-failure-correlation"` — **이 루트의 크로스 소스 조인 대표작.** CTE 둘: `allowed_waf`(WAF 테이블에서 `action = 'ALLOW'`인 요청의 `httprequest.requestid`를 `cloudfront_request_id`로 추출 — WAF의 requestid가 곧 CloudFront 요청 ID다), `application_events`(정규화 조각). 이 둘을 `cloudfront_request_id`로 JOIN해 **"WAF는 통과시켰는데 앱에서 4xx/거부/실패로 끝난 요청"**을 찾는다 — WAF 규칙의 빈틈(우회 성공 시도)을 역추적하는 쿼리다. CloudFront가 붙인 요청 ID를 앱 로그에 전파해 둔 설계(애플리케이션 쪽 준비)가 있어야 성립하는, 수집 설계와 분석 설계가 맞물린 지점이다. WAF 파티션 조건에 `application_recent_partition`을 재사용하는 것은 두 테이블의 파티션 키 구조(year/month/day/hour)가 같아서 가능하다.

### L363–376 · resource "aws_athena_named_query" "application" (for_each)

맵 6항목 → named query 6개. `depends_on`이 **`aws_glue_catalog_table.application_logs`와 `aws_glue_catalog_table.waf_logs` 둘 다**를 기다린다 — 16번 쿼리가 WAF 테이블을 참조하기 때문으로, 파일 경계(waf-logs-analytics.tf)를 넘는 의존이 명시돼 있다.

### L378–386 · output 2종

`athena_application_table_name` — 테이블 이름. `application_logs_s3_location` — `s3://<중앙버킷>/cloudwatch/application/` 경로. 검증 스크립트가 "Firehose가 정말 이 경로에 쌓는가"를 대조하는 기준값이다.

---

## log-archive/eks-control-plane-analytics.tf (197줄)

EKS control-plane 로그를 읽는 **원문 한 컬럼 테이블**과 K8s audit 조사 쿼리 4개다. 상단 주석(L1–14)이 이 파일의 스키마 결정을 통째로 설명하는 이 루트 최고의 주석 중 하나다 — control-plane 로그는 **api / audit / authenticator 3종이 같은 로그 그룹(따라서 같은 `cloudwatch/control-plane/` 접두사)으로 섞여 오는데**, 원문 형식이 제각각이다: kube-apiserver-audit은 K8s audit event JSON(탐지가 쓰는 것), kube-apiserver는 평문, authenticator는 평문/JSON 혼재. **형식이 혼재하는 데이터에 타입 파서를 테이블에 박으면 절반이 파싱 실패로 깨진다.** 그래서 rds-audit과 같은 `message` 한 컬럼 원문 테이블로 두고, 소비자(아래 쿼리들과 security-events-view.tf의 eks 분기)가 `kind='Event'`인 audit JSON만 골라 `json_extract`로 파싱한다 — 스키마 온 리드(schema-on-read)를 극단까지 밀어붙인 형태다.

### L16–103 · locals — 테이블 이름·파티션 조각·audit 조사 쿼리 4종

- `athena_eks_control_plane_table_name = "eks_control_plane_logs"` / `eks_control_plane_s3_prefix = "cloudwatch/control-plane"` (L17–18) — Firehose "control-plane" 스트림의 배달 접두사와 일치.
- `eks_control_plane_recent_partition` (L20–30) — application 파일과 동일한 "오늘 OR 어제" 파티션 조각의 EKS판.
- `eks_control_plane_named_queries` (L32–102) — 쿼리 4종. 공통 골격: `try(json_extract_scalar(message, '$.kind')) = 'Event'` — **audit 이벤트 JSON만 통과시키는 관문**이다. 평문 라인(api/authenticator)은 json_extract가 실패하는데 `try()`가 NULL로 바꿔 조건에서 자연 탈락시킨다. try 없이는 평문 라인 하나가 쿼리 전체를 죽인다.
  - `"21-eks-audit-pod-exec-24h"` — `verb = 'create'` AND `objectRef.subresource IN ('exec','attach')`. **kubectl exec/attach는 컨테이너 셸 접근**이라 침해 조사 1순위 이벤트다(exec은 K8s API 상 pods/exec 서브리소스의 create로 기록된다는 지식이 조건에 압축돼 있다). username·namespace·pod·응답 코드를 뽑는다.
  - `"22-eks-audit-secret-access-24h"` — `objectRef.resource = 'secrets'` AND verb get/list/watch를 주체별 집계. Secret 대량 열람은 크리덴셜 수집의 신호다. GROUP BY 1,2,3(위치 표기)으로 username×namespace×verb를 묶는다.
  - `"23-eks-audit-forbidden-24h"` — `responseStatus.code = '403'`(json_extract_scalar이 문자열을 돌려주므로 문자열 '403'과 비교). 인가 거부 나열은 RBAC 권한 탐색(enumeration)의 흔적이다.
  - `"24-eks-audit-rbac-change-24h"` — `objectRef.resource IN ('roles','clusterroles','rolebindings','clusterrolebindings')` AND verb create/update/patch/delete. **RBAC 변경은 권한 상승의 직접 증거**라 마지막 번호 대역을 차지한다.

### L105–175 · resource "aws_glue_catalog_table" "eks_control_plane_logs"

- `parameters` — `classification = "text"`(JSON이 아니다 — 혼재 원문이므로), 프로젝션은 application과 동일한 year/month/day/hour 4단 integer(2026–2036, digits 패딩 포함), `storage.location.template`도 접두사만 다른 같은 골격이다.
- `storage_descriptor` — 컬럼이 **`message` string 하나**다(dynamic 없이 직접 선언 — 하나뿐이라 리스트화할 이유가 없다). `ser_de_info`는 RegexSerDe + `"input.regex" = "^(.*)$"` — **라인 전체를 캡처 그룹 하나로 삼켜 message 컬럼에 그대로 담는** 정규식이다. "파싱하지 않는 SerDe 설정"을 RegexSerDe로 구현한 것으로, 어떤 형식의 라인도 실패 없이 들어온다. 원문 보존(불변 증거)과 파싱(가변 해석)을 저장/조회 단계로 분리한 설계의 저장 쪽 절반이다.

### L177–187 · resource "aws_athena_named_query" "eks_control_plane" (for_each)

맵 4항목 → named query 4개. 골격은 다른 파일과 동일하다.

### L189–197 · output 2종

`athena_eks_control_plane_table_name` / `eks_control_plane_logs_s3_location` — 테이블 이름과 S3 경로. 다른 analytics 파일들과 같은 검증·문서화 용도다.

---

## log-archive/waf-logs-analytics.tf (194줄)

CloudFront WAF 로그를 읽는 테이블과 차단 조사 쿼리 2개다. 상단 주석(L1–6)이 데이터의 여정을 요약한다 — Workload us-east-1 CloudWatch Logs → Log 계정 (us-east-1) Destination → 서울 Firehose → 중앙 Object Lock S3의 `cloudwatch/waf/year=…` 경로. log-archive.tf의 WAF 특례(Destination만 버지니아) 해설의 소비 측이 이 파일이다.

### L8–43 · locals — WAF 스키마 24컬럼

- `athena_waf_table_name = "waf_logs"` / `waf_logs_s3_prefix = "cloudwatch/waf"` — Firehose "waf" 스트림의 접두사와 일치.
- `waf_athena_columns` (L13–42) — 주석(L12)대로 **AWS 공식 WAF Athena 스키마 기준 + 신규 필드 수용.** 짚을 컬럼들:
  - `timestamp` — **bigint, epoch 밀리초**다. 쿼리에서 `from_unixtime("timestamp" / 1000.0)`으로 변환하며, 예약어라 따옴표가 필요하다.
  - `action` — ALLOW/BLOCK 등 최종 판정. `terminatingruleid`/`terminatingruletype` — 판정을 확정한 규칙.
  - `terminatingrulematchdetails` (L20) — `array<struct<conditiontype,sensitivitylevel,location,matcheddata:array<string>>>`. SQLi/XSS 매치의 **어느 위치에서 무엇이 걸렸는지**까지 담는 구조다.
  - `rulegrouplist` (L23–26) — 이 테이블에서 가장 깊은 타입. 규칙 그룹별로 terminating rule, non-terminating matching rules(COUNT로 지나간 매치), excluded rules까지 3단 중첩 array/struct로 선언한다. 관리형 규칙 그룹(AWSManagedRules…)의 내부 동작을 재구성할 수 있는 근거 데이터다.
  - `ratebasedrulelist` (L27) — rate 기반 규칙의 한도(`maxrateallowed`)·평가 창(`evaluationwindowsec`) 등.
  - `httprequest` (L30–33) — clientip, country(엣지가 판정한 국가), `headers:array<struct<name,value>>`, uri, args(쿼리스트링), httpmethod, **requestid**(CloudFront 요청 ID — application 16번 쿼리의 조인 키), fragment/scheme/host.
  - `labels` (L34) — 규칙이 붙인 레이블 목록.
  - `captcharesponse`/`challengeresponse`, `ja3fingerprint`/`ja4fingerprint`, `oversizefields`, `requestbodysize`/`requestbodysizeinspectedbywaf` (L35–41) — 봇 대응·TLS 핑거프린트·본문 크기 등 **최신 로그 필드**들. OpenX SerDe는 선언 안 된 필드를 무시하고 선언된 필드가 없으면 NULL로 채우므로, 미리 넉넉히 선언해 두면 로그 형식이 진화해도 테이블이 깨지지 않는다.

### L45–119 · resource "aws_glue_catalog_table" "waf_logs"

- `parameters` — `classification = "json"`, year/month/day/hour 4단 integer 프로젝션(application·EKS와 동일 골격), `storage.location.template`은 `cloudwatch/waf/…` 접두사.
- `storage_descriptor` — TextInputFormat + compressed, `dynamic "columns"`로 24컬럼 전개, **OpenX JsonSerDe + case.insensitive** — WAF 로그 키가 camelCase(`httpRequest`)라 Hive 소문자 컬럼과의 매핑에 필요하다. application 테이블과 같은 선택 기준이다.

### L126–172 · locals — 오늘 파티션 조각과 차단 조사 쿼리 2종

- `waf_today_partition` (L127–131) — "오늘 OR 어제"가 아니라 **오늘 하루만** 등호로 잡는 조각이다. 아래 쿼리들이 "오늘 차단 현황"이라는 실시간 관제 성격이라 24시간 소급이 필요 없고, 스캔 범위도 하루로 최소화된다. 쿼리 설명("오늘 …")과 조각의 의미가 일치한다.
- `"07-waf-blocked-request-details"` — `action = 'BLOCK'`인 요청의 시각·규칙·IP·국가·메서드·URI·쿼리스트링을 시간 역순 200건. `from_unixtime("timestamp" / 1000.0)` 밀리초 변환이 여기 나온다. "지금 무엇이 차단되고 있나"의 상세 화면이다.
- `"08-waf-top-attacking-ips"` — 차단 건수 상위 IP를 `clientip × country × terminatingruleid`로 집계하고 `COUNT(DISTINCT httprequest.uri) AS targeted_uri_count`를 곁들인다 — 한 IP가 **여러 URI를 훑고 있는지**(스캐너 성향)를 차단량과 함께 보는 설계다.

### L174–184 · resource "aws_athena_named_query" "waf" (for_each)

맵 2항목 → named query 2개. 표준 골격이다.

### L186–194 · output 2종

`waf_logs_s3_location` / `athena_waf_table_name` — S3 경로와 테이블 이름.

---

## log-archive/flow-logs-analytics.tf (182줄)

VPC Flow Logs를 읽는 parquet 테이블과 네트워크 조사 쿼리 3개다. 상단 주석(L1–9)이 이식 시 유일하게 달라진 지점을 강조한다 — **Flow Logs 배달 경로의 `AWSLogs/<계정ID>`는 버킷 소유자가 아니라 "로그를 만든 VPC의 계정"**이다. 즉 버킷은 Log 계정 것이지만 경로의 계정 ID는 워크로드 계정 ID다. baseline(같은 계정)에서는 이 구분이 드러나지 않아, 이식할 때 놓치기 쉬운 크로스 계정 특유의 함정이다.

### L11–32 · locals — 경로와 parquet v2 필드 14개

- `vpc_flow_logs_s3_base_prefix` (L13) — `vpc-flow-logs/AWSLogs/<워크로드계정ID>/vpcflowlogs`. log-archive.tf의 `vpc_flow_logs_s3_prefix`("vpc-flow-logs")와 워크로드 계정 ID의 합성으로, 버킷 정책 문 5(AWSLogDeliveryWrite)가 허용한 쓰기 경로의 하위다.
- `flowlogs_athena_columns` (L16–31) — **Flow Logs 기본(v2) 필드 14개**: version, account_id, interface_id(어느 ENI인가), srcaddr/dstaddr, srcport/dstport(int), protocol(int — 6=TCP, 17=UDP 같은 IANA 번호), packets/bytes(bigint), start/end(bigint epoch초 — 집계 창의 양 끝), action(ACCEPT/REJECT — SG/NACL 판정 결과), log_status. 주석(L15)이 형식 선택의 이유를 명시한다 — **parquet은 컬럼 지향이라 Athena 스캔 비용이 JSON/text 대비 크게 준다.** 필요한 컬럼만 읽으므로 `SUM(bytes)` 같은 집계에서 차이가 크다. 이 형식은 Workload 쪽 flow-logs.tf가 배달 옵션으로 지정한 것으로, 쓰는 쪽 형식 선언과 읽는 쪽 SerDe가 짝이다.

### L39–95 · resource "aws_glue_catalog_table" "vpc_flow_logs"

- `parameters` — CloudTrail 테이블과 **같은 프로젝션 패턴**이다: `region` injected + `event_date` date(`yyyy/MM/dd`, interval 1 DAYS). 주석(L49)이 이유를 남긴다 — 이 VPC는 단일 리전이지만 **CloudTrail 테이블과 스키마 구조를 맞춰** 쿼리 작성 습관(WHERE region = … AND event_date >= …)을 통일한다. `projection.event_date.range`도 CloudTrail과 같은 변수(`athena_cloudtrail_projection_start_date`)를 재사용한다 — 주석(L55)대로 Flow Logs도 같은 전환일부터 조회 대상이기 때문이며, 변수 하나로 두 테이블의 시작일이 함께 관리된다.
- `"storage.location.template"` — `s3://<중앙버킷>/<base_prefix>/$${region}/$${event_date}/`. Flow Logs 배달 경로(`…/vpcflowlogs/ap-northeast-2/2026/08/12/`)와 일치한다.
- `storage_descriptor` — **parquet 3종 세트**: `input_format = MapredParquetInputFormat`, `output_format = MapredParquetOutputFormat`, `ser_de_info.serialization_library = ParquetHiveSerDe`. 텍스트 계열 테이블들과 달리 SerDe에 파싱 설정이 없다 — parquet은 스키마를 파일 자체가 갖고 있어 컬럼 이름 매칭으로 읽는다. `compressed = true` — parquet 내부 압축(기본 SNAPPY) 전제.

### L102–160 · locals — 공통 조각과 조사 쿼리 3종

주석(L99)이 이 쿼리 묶음의 성격을 규정한다 — **"GuardDuty finding이 뜬 뒤 원본 증거를 바로 뽑는 용도."** 탐지는 GuardDuty가 하고, Athena는 그 원본 근거(raw evidence)를 재구성한다는 역할 분담이다.

- `flowlogs_query_base` (L104–108) — 모든 쿼리가 공유하는 FROM/WHERE 조각: 현재 리전(injected 파티션 필수 조건) + 최근 24시간(event_date 사전순 비교). SELECT와 GROUP BY만 쿼리마다 갈아 끼우는 구조라, 쿼리 본문에 `${local.flowlogs_query_base}`가 문장 중간에 삽입되는 형태다.
- `"04-flowlogs-rejected-traffic"` — `action = 'REJECT'`를 `srcaddr × dstaddr × dstport × protocol`로 집계. "어떤 IP가 어디를 두드렸는가" — 차단된 시도의 지형도다.
- `"05-flowlogs-port-scan-detect"` — 소스 IP별 `COUNT(DISTINCT dstport)`를 세고 **`HAVING COUNT(DISTINCT dstport) >= 20`** — 한 IP가 24시간 내 20개 이상 포트를 훑었으면 포트스캔 후보로 본다는 임계값이 SQL에 박혀 있다. `MIN(from_unixtime("start"))`/`MAX(from_unixtime("end"))`로 활동 기간, REJECT 비율(CASE 합계)로 차단 효과까지 함께 본다. start/end는 예약어라 따옴표 필수다.
- `"06-flowlogs-top-talkers"` — `action = 'ACCEPT'`(허용된 트래픽만)를 전송 바이트 순으로 상위 50 통신쌍. 설명 그대로 **데이터 유출(exfiltration) 흔적 확인** — 허용된 경로로 대량 데이터가 나간 것이 가장 위험한 시나리오라 ACCEPT만 본다.

### L162–172 · resource "aws_athena_named_query" "flowlogs" (for_each)

맵 3항목 → named query 3개. 표준 골격.

### L179–182 · output "vpc_flow_logs_s3_location"

Flow Logs 원본 S3 기본 경로. 이 파일의 유일한 output이다(테이블 이름 output이 없는 것은 이식 원본의 형태를 유지한 결과다).

---

## log-archive/rds-audit-analytics.tf (177줄)

2026-08-12에 "rds-audit" 소스와 함께 추가된 최신 분석 파일 — RDS 감사 로그의 원문 한 컬럼 테이블과 조사 쿼리 4개다. 상단 주석(L1–8)이 EKS 파일과 같은 계열의 스키마 결정을 설명한다 — **감사 로그 라인 형식은 엔진·설정마다 다르다**(MySQL/MariaDB Audit Plugin의 CSV형 vs PostgreSQL pgaudit의 다른 형식). 그래서 모든 엔진에 안전한 `message` 한 컬럼 외부 테이블로 시작하고, 타입 파서는 필요해지면 나중에 얹는다. "불변 원문을 먼저 확보하고 해석은 소비 시점에" — EKS 테이블과 동일한 원칙이 엔진 다양성이라는 다른 이유로 재적용된 사례다.

### L10–83 · locals — 테이블 이름·파티션 조각·조사 쿼리 4종

- `athena_rds_audit_table_name = "rds_audit_logs"` / `rds_audit_logs_s3_prefix = "cloudwatch/rds-audit"` (L11–12) — log-archive.tf 소스 집합의 "rds-audit" 항목이 만든 Firehose의 배달 접두사와 일치. **소스 한 줄 추가의 마지막 조각(수동 분석 파일)이 바로 이 파일**이다.
- `rds_audit_recent_partition` (L14–24) — 표준 "오늘 OR 어제" 파티션 조각의 RDS판.
- `rds_audit_named_queries` (L26–82) — 원문 테이블이므로 쿼리 전략이 다르다: 구조화 파싱 대신 **`lower(message)`에 대한 문자열 매칭**으로 엔진 불문 검색을 한다. 정밀도는 낮지만(오탐 가능) 어떤 엔진의 어떤 형식에도 동작한다는 트레이드오프다.
  - `"17-rds-audit-recent-events-24h"` — 조건 없이 최근 원문 500건. 수집이 살아 있는지 확인하는 스모크 테스트 겸 형식 관찰용이다.
  - `"18-rds-audit-authentication-failures-24h"` — `'%access denied%'`, `'%authentication failed%'`, `'%login failed%'`, `'%password authentication failed%'` LIKE 4종 OR — MySQL 계열과 PostgreSQL 계열의 인증 실패 문구를 모두 커버하는 목록이다.
  - `"19-rds-audit-privilege-and-ddl-24h"` — `regexp_like(lower(message), '(create|alter|drop|grant|revoke)')` — DDL과 DCL 키워드. GRANT/REVOKE는 DB 내 권한 상승의 직접 증거다.
  - `"20-rds-audit-data-mutations-24h"` — `(insert|update|delete|truncate)` — DML 변경 흔적. 대량 DELETE/TRUNCATE는 파괴 행위의 신호다.

### L85–155 · resource "aws_glue_catalog_table" "rds_audit_logs"

EKS 테이블과 사실상 동일한 골격이다 — `classification = "text"`, year/month/day/hour 4단 integer 프로젝션(2026–2036), `storage.location.template`은 `cloudwatch/rds-audit/…`, 컬럼은 `message` string 하나, RegexSerDe `"^(.*)$"`(라인 전체 캡처). 같은 패턴이 두 파일에서 반복되는 것 자체가 "원문 테이블"이 이 루트의 정형화된 선택지임을 보여준다.

### L157–167 · resource "aws_athena_named_query" "rds_audit" (for_each)

맵 4항목 → named query 4개. 표준 골격.

### L169–177 · output 2종

`athena_rds_audit_table_name` / `rds_audit_logs_s3_location` — 테이블 이름과 S3 경로.

---

## log-archive/firehose-monitoring.tf (143줄)

**수집 파이프라인 자체를 감시하는** 파일이다. 로그가 안 쌓이는 장애는 로그로는 발견할 수 없으므로 별도 감시가 필수다. 상단 주석(L1–8)이 구조를 요약한다 — Firehose 실패는 서비스가 소유한 CloudWatch 로그 그룹(오류 로그)에 기록되므로 그것을 메트릭으로 변환해 알람을 걸고, 하드 오류뿐 아니라 배달 적체·스로틀링에도 알람을 건다. 그리고 **알람 이벤트는 Workload 계정의 기존 SNS → Discord 파이프라인으로 전달**한다 — Log 계정에 웹훅 시크릿을 복제하지 않기 위해서다(시크릿 사본이 늘수록 유출면이 넓어진다).

### L10–12 · locals

`firehose_delivery_freshness_alarm_seconds = 900` — 배달 신선도 알람 임계값. **Firehose 버퍼 주기(300초)의 3배**로, 정상 버퍼링 지연(최대 5분)과 실제 적체를 구분하는 여유다. log-archive.tf의 buffering_interval 해설에서 예고한 그 짝이다.

### L14–30 · resource "aws_cloudwatch_log_metric_filter" "firehose_delivery_errors" (for_each)

`for_each = local.cloudwatch_log_delivery_sources` — **소스 4개 × 필터 1 = 4개.** 이 파일의 for_each 리소스 4종이 전부 이 집합을 돌므로, 소스 한 줄 추가 시 이 파일에서만 리소스 4개가 자동 증가한다(루트 개요의 "9개 자동 생성" 중 4개가 여기다).

- `log_group_name = aws_cloudwatch_log_group.cloudwatch_log_archive_firehose[each.key].name` — log-archive.tf가 만든 Firehose 오류 로그 그룹을 소스별로 참조.
- `pattern = "ERROR"` — 오류 로그 라인의 단순 문자열 매치. Firehose 오류 로그 형식이 안정적이라 이 정도로 충분하다.
- `metric_transformation` — 커스텀 네임스페이스 `Gochuchamchi/LogArchive`에 `FirehoseDeliveryErrors` 메트릭, `value = "1"`(매치 라인당 1 카운트), `dimensions.Source = each.key` — **소스명을 차원으로** 실어 알람도 소스별로 갈린다.

### L32–49 · resource "aws_cloudwatch_metric_alarm" "firehose_delivery_errors" (for_each)

**P2 알람 — 하드 오류.** 위 커스텀 메트릭이 5분(`period = 300`) 합계(`statistic = "Sum"`)로 1 이상(`threshold = 1`, GreaterThanOrEqualToThreshold)이면 1회 평가(`evaluation_periods = 1`) 만에 발화한다 — 오류는 한 건도 즉시 조사 대상이라는 설정이다. `alarm_description`이 심각도(P2)와 대응 행동("중앙 로그 보존 누락 여부를 즉시 조사할 것")을 담는다 — 알람 설명을 runbook 한 줄로 쓰는 관례. `treat_missing_data = "notBreaching"` — 오류가 없으면 메트릭 필터가 데이터를 아예 안 만드는데, 그 침묵을 정상으로 해석한다(이 설정이 없으면 무소식이 INSUFFICIENT_DATA로 떠서 노이즈가 된다).

### L51–68 · resource "aws_cloudwatch_metric_alarm" "firehose_delivery_freshness" (for_each)

**P3 알람 — 배달 적체.** AWS 관리 메트릭 `AWS/Firehose`의 `DeliveryToS3.DataFreshness` — **Firehose 안에서 가장 오래 기다리는 미전달 레코드의 나이(초)**다. `statistic = "Maximum"`, `threshold = 900`, `evaluation_periods = 2` — 5분 창 두 번 연속(총 10분) 초과해야 발화한다. 오류 알람(1회)보다 느슨한 것은 일시적 지연이 자연 회복되는 경우가 많아서다. `dimensions.DeliveryStreamName`으로 소스별 스트림을 특정한다. S3 배달이 조용히 멈추는 장애(권한 회수, KMS 정책 변경 등)는 오류 로그 없이 freshness만 늘어나는 형태로 나타나므로, 오류 알람과 상호 보완이다.

### L70–87 · resource "aws_cloudwatch_metric_alarm" "firehose_throttled_records" (for_each)

**P3 알람 — 입구 유실 위험.** `ThrottledRecords` — Firehose가 처리량 한도로 밀어낸(거부한) 레코드 수. 5분 합계 1 이상이면 발화. 스로틀링된 레코드는 발신 측(CloudWatch Logs 구독)이 재시도하지만 재시도마저 밀리면 로그가 소실될 수 있어, "일부 로그가 수집되지 않을 수 있음"이라는 설명 그대로 수집 완전성의 조기 경보다.

세 알람 모두 `alarm_actions`가 없다는 점이 특징이다 — 통지는 SNS 직결이 아니라 아래 EventBridge 전달로 처리한다.

### L91–101 · data "aws_iam_policy_document" "firehose_alarm_forwarder_assume_role"

L89–90 주석 — "알림 허브는 Workload 계정에 있다. Log 계정의 Firehose 알람 상태 전이만 default event bus를 통해 그쪽으로 전달한다." 이 문서는 전달용 역할의 신뢰 정책 — `events.amazonaws.com`(EventBridge)이 AssumeRole 가능. **크로스 계정 이벤트 버스 타깃은 IAM 역할이 필수**다(같은 계정 타깃은 리소스 정책으로 충분하지만, 계정 경계를 넘을 때는 역할로 서명한다).

### L103–108 · resource "aws_iam_role" "firehose_alarm_forwarder"

이름 `gochuchamchi-firehose-alarm-forwarder`. EventBridge가 쓸 전달 역할 본체다.

### L110–116 · data "aws_iam_policy_document" "firehose_alarm_forwarder"

권한 정책 — `events:PutEvents`를 **Workload 계정의 default event bus ARN 하나**(`arn:aws:events:<리전>:<워크로드>:event-bus/default`)에만 허용. 이 역할이 할 수 있는 일은 "그 버스에 이벤트 넣기"가 전부다. 수신이 성립하려면 Workload 쪽 default 버스의 리소스 정책이 Log 계정의 PutEvents를 허용하고, 버스에 도착한 알람 이벤트를 SNS → Discord로 라우팅하는 규칙이 있어야 한다 — 그 절반은 Workload 런타임 루트의 알림 스택이 맡는 크로스 루트 분업이다.

### L118–122 · resource "aws_iam_role_policy" "firehose_alarm_forwarder"

위 문서를 인라인 부착.

### L124–136 · resource "aws_cloudwatch_event_rule" "firehose_alarm_state_change"

전달할 이벤트를 고르는 규칙. `event_pattern` — `source = aws.cloudwatch`, `detail-type = "CloudWatch Alarm State Change"`(알람 상태 전이는 EventBridge에 자동 발행된다 — 알람에 액션을 안 단 이유), detail 조건 둘: `alarmName = [{ prefix = "gochuchamchi-firehose-" }]` — **이름 접두사 매칭**으로 이 파일의 알람 12개(3종 × 4소스)를 전부 잡는다. 소스가 늘어 알람이 추가돼도 규칙은 그대로다 — 이름 규약이 여기서도 설정을 대신한다. `state.value = ["ALARM", "OK"]` — 발화뿐 아니라 **회복(OK)도 전달**해 Discord에서 상황 종료를 알 수 있게 한다.

### L138–143 · resource "aws_cloudwatch_event_target" "firehose_alarm_workload_event_bus"

규칙의 타깃 — `arn`은 Workload default 버스(ARN 문자열 조립 — remote state 없이 계정 ID·리전으로 결정적 조립하는 프로젝트 패턴), `role_arn`은 위 전달 역할, `target_id = "ForwardToWorkloadAlertHub"`. 이로써 Log 계정은 웹훅 시크릿 없이 알림 채널을 얻는다 — **시크릿은 한 계정에만, 이벤트는 버스로** 라는 분리다.

---

## log-archive/cloudwatch-monitoring-account.tf (69줄)

Log 계정을 CloudWatch **크로스 계정 관측(Observability) 모니터링 계정**으로 만드는 OAM(Observability Access Manager) sink 2개와 그 정책이다. 상단 주석(L1–7)이 범위 결정을 명시한다 — **메트릭만 공유한다.** WAF·애플리케이션 원시 로그는 이미 불변 중앙 S3에 도착해 Athena로 조사하므로, 로그까지 OAM으로 이중 공유하면 비용과 운영 복잡도만 는다. 같은 데이터를 두 경로로 받지 않는다는 원칙이다. 이 파일 덕에 Workload 대시보드·알람이 보는 메트릭을 Log 계정 콘솔에서도 조회할 수 있다.

### L9–29 · locals — 공유 자원 타입과 sink 정책

- `oam_shared_resource_types = ["AWS::CloudWatch::Metric"]` — 공유 허용 타입 목록. OAM은 메트릭 외에 로그 그룹·X-Ray 트레이스도 공유할 수 있지만 **메트릭 하나로 못박는다.**
- `oam_sink_policy` (L12–28) — sink에 붙일 리소스 정책의 jsonencode. 문 `AllowWorkloadMetricsLink`: principal은 **Workload 계정 루트**(`arn:aws:iam::<워크로드>:root` — 계정 위임 관례 표기), actions는 `oam:CreateLink`/`oam:UpdateLink` — "이 sink로 링크를 걸어도 된다"는 허가다. 핵심은 condition — `"ForAllValues:StringEquals" { "oam:ResourceTypes" = [메트릭] }`. `oam:ResourceTypes`는 링크 생성 요청에 담기는 **다중값 키**라서 집합 한정자가 필요하다: ForAllValues는 "요청의 모든 값이 허용 목록 안에 있어야 통과"라는 뜻이므로, Workload가 로그 그룹을 슬쩍 끼운 링크를 만들려 하면 그 요청 전체가 거부된다. **정책 문서 자체가 "메트릭 전용" 계약서**인 셈이다. 두 리전 sink가 같은 정책을 공유하도록 locals에 둔다.

### L31–37 · resource "aws_oam_sink" "security_monitoring_seoul"

서울 sink. sink는 모니터링 계정 쪽 수신 창구로, **리전 단위 리소스이며 계정·리전당 하나만** 만들 수 있다. 이름 `gochuchamchi-security-monitoring-seoul`, 태그에 `Component = "security-monitoring"`.

### L39–42 · resource "aws_oam_sink_policy" "security_monitoring_seoul"

서울 sink에 위 정책을 부착한다. `sink_identifier = aws_oam_sink.security_monitoring_seoul.id`. Destination과 destination policy의 관계처럼, 창구와 창구 인가가 별도 리소스로 갈린 구조다.

### L44–52 · resource "aws_oam_sink" "security_monitoring_us_east_1"

`provider = aws.us_east_1` — **버지니아 sink.** OAM 링크는 같은 리전의 sink로만 걸 수 있는데, CloudFront·WAF 메트릭은 us-east-1에 발행되므로 그쪽 메트릭을 받으려면 버지니아에도 sink가 필요하다. providers.tf의 us_east_1 alias가 쓰이는 두 번째 지점이다(첫째는 WAF Destination).

### L54–59 · resource "aws_oam_sink_policy" "security_monitoring_us_east_1"

버지니아 sink에 같은 정책(`local.oam_sink_policy`) 부착. 리전만 다르고 계약 내용은 동일하다.

### L61–69 · output 2종

`oam_sink_arn_seoul` / `oam_sink_arn_us_east_1` — sink ARN 2개. **Workload 쪽이 `aws_oam_link`를 만들 때 `sink_identifier`로 넣어야 하는 값**이다(description이 그 용도를 명시한다). 링크는 소스 계정(Workload)에서 만드는 리소스이므로, 여기서도 "Log 계정이 sink를 먼저 apply해야 Workload 링크가 생성된다"는 Destination과 같은 순서 제약이 성립한다.

---

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| providers.tf | 49 | 6 | 전 블록 해설 |
| backend.tf | 13 | 1 | 전 블록 해설 |
| variables.tf | 87 | 9 | 전 블록 해설 |
| account-guard.tf | 10 | 1 | 전 블록 해설 |
| kms-logs.tf | 125 | 4 | 전 블록 해설 |
| log-archive.tf | 710 | 30 | 전 블록 해설 |
| cloudtrail.tf | 17 | 2 | 전 블록 해설 |
| athena.tf | 374 | 18 | 전 블록 해설 |
| alb-access-logs.tf | 330 | 15 | 전 블록 해설 |
| application-logs-analytics.tf | 386 | 6 | 전 블록 해설 |
| eks-control-plane-analytics.tf | 197 | 5 | 전 블록 해설 |
| waf-logs-analytics.tf | 194 | 6 | 전 블록 해설 |
| flow-logs-analytics.tf | 182 | 5 | 전 블록 해설 |
| rds-audit-analytics.tf | 177 | 5 | 전 블록 해설 |
| firehose-monitoring.tf | 143 | 11 | 전 블록 해설 |
| cloudwatch-monitoring-account.tf | 69 | 7 | 전 블록 해설 |
| **합계** | **3,063** | **131** | **16/16 파일** |


---

# log-archive (2) — SIEM 탐지·알림·대시보드 (Log 계정)

이 다섯 파일은 Log 계정에 이미 깔려 있는 로그 수집·분석 기반(Firehose→S3→Glue/Athena, 다른 섹션에서 해설) 위에 얹은 **자체 SIEM**이다. 데이터 흐름은 한 줄로 요약된다: **Workload의 로그가 S3에 쌓인다 → `security-events-view.tf`가 이질적인 로그 테이블들을 공통 8필드 스키마의 Athena 뷰로 정규화한다 → `siem-detection-rules.tf`의 SQL 상관 룰 10개가 그 뷰(일부는 원본 테이블)를 조회해 "후보"를 뽑는다 → `siem-detector.tf`의 Lambda가 EventBridge 스케줄(기본 1시간)로 룰 전부를 실행하고, DynamoDB로 중복을 억제하고, 후보에 Groq LLM 판정을 붙인 뒤 SNS로 발행한다 → `siem-alerts.tf`의 SNS 토픽이 이메일과 Discord(전용 렌더링 Lambda)로 팬아웃하고, 실패분은 DLQ+알람으로 자기 감시한다.** `security-dashboard.tf`는 이 로그 경로와 별개로, CloudWatch 지표(OAM 크로스계정 공유)를 모아 "지금 뭔가 벌어지고 있나"를 한 장으로 보여주는 관제 화면이다.

설계의 중심 사상은 두 가지다. 첫째, **결정론적 SQL 룰을 앞에, LLM 판정을 뒤에** 둔다. 하루 수십만 건의 원시 로그는 룰이 수십 건의 후보로 줄이고(볼륨·비용을 여기서 잡는다), 모델은 후보가 있을 때만 룰당 1회 호출돼 "이게 정상 자동화인가 공격인가"의 정밀도만 담당한다. 순서가 뒤집히면 토큰 비용이 트래픽에 비례해 개인 프로젝트 규모에서 성립하지 않는다는 계산이 주석에 명시돼 있다. 그래서 룰 임계값은 전부 **재현율(recall) 우선으로 낮게** 잡혀 있고, 소음 제거는 판정 계층의 일로 정의된다. 둘째, **"조용한 고장"을 구조적으로 없앤다.** SIEM에서 가장 위험한 상태는 "알림이 없는 것"과 "탐지가 멈춘 것"이 구분되지 않는 상태라는 문제의식이 파일 전반에 깔려 있다 — 탐지 Lambda는 실행마다 `DetectionRunSuccess` 지표를 찍고 두 주기 연속 누락 시 알람이 울리며, Discord 전달 실패는 DLQ에 쌓여 알람으로 되돌아오고, 그 알람의 최종 수신자는 외부 의존이 없는 SNS 이메일 구독이다.

비용 방어도 다층이다: 탐지용 뷰는 2일·축소 소스로 좁혀 스캔량을 잡고, Athena 워크그룹의 쿼리당 1 GiB 상한(athena.tf, 다른 섹션)이 위쪽 뚜껑이 되고, Groq 판정에는 일일 호출 상한이 한 겹 더 걸린다. 해설 순서는 데이터가 흐르는 순서를 따른다: 정규화 뷰 → 탐지 룰 → 탐지 엔진 → 알림 경로 → 대시보드.

---

## log-archive/security-events-view.tf (445줄)

여러 로그 테이블을 공통 스키마 하나로 합치는 **정규화 계층**이다. SIEM 제품이 파는 것의 본질이 이 정규화라는 관점 아래, Athena 뷰 두 장(`security_events` 조사용 / `security_events_recent` 탐지용)을 Terraform locals의 템플릿 조립으로 생성한다. Terraform이 Athena 뷰를 직접 만들 수 없다는 제약을 "CREATE OR REPLACE VIEW 문장을 담은 저장 쿼리(named query)를 배포하고, 실행은 콘솔 1회 또는 detector Lambda의 매 실행 앞머리에서" 하는 방식으로 우회한다. 이 파일의 진짜 주제는 스키마 통일과 **비용 설계**(뷰 정의 안에 시간창과 파티션 프루닝을 박아 넣는 것) 두 가지다.

### L1–64 · 파일 헤더 주석 — 정규화·비용·뷰 2장 구조의 설계 근거

이 파일에서 가장 정보량이 많은 블록이다. 요지를 풀면 다음과 같다.

- **왜 정규화인가**: "출발지 IP" 하나가 cloudtrail=`sourceipaddress` / flow=`srcaddr` / waf=`httprequest.clientip` / alb=`client_ip` / app=`clientip`로 테이블마다 다르다. "이 IP가 어디어디 나타났나"를 물으려면 쿼리 4~5개를 손으로 써야 하고, 그 마찰이 관제를 못 하게 만든다. 멘토 조언("먼저 어떤 필드를 볼지 정의하라")을 근거로, 조사에서 실제로 피벗하는 축 8개만 남겼다: `event_time / source_type / source_ip / actor / action / target / outcome / detail`.
- **비용 설계가 핵심**: 워크그룹에 쿼리당 1 GiB 스캔 상한이 걸려 있는데, 테이블들을 그냥 UNION ALL 하면 파티션 프루닝이 안 돼 즉시 상한에 걸린다. 그래서 시간창을 **뷰 정의 안에** 넣고 각 분기가 자기 테이블의 네이티브 파티션 컬럼으로 직접 필터한다. 호출자가 날짜 조건을 잊어도 요금이 새지 않는 구조다. 프루닝은 파티션 컬럼에 대한 "단순 비교"에서만 동작하므로, `concat(year,month,day)` 같은 계산식 대신 y/m/d 등식 트리플을 날짜 수만큼 OR로 나열하는 관용구를 쓴다.
- **뷰가 두 장인 이유**: 조사(사람, 하루 몇 번, 넓게 7일·전 소스)와 탐지(Lambda, 매시간, 좁게 2일)는 요구가 정반대다. 탐지가 7일짜리 뷰를 시간마다 훑으면 스캔량이 7배가 되고 1 GiB 상한에 걸려 **탐지가 조용히 실패한다** — 헤더 표현으로 "SIEM에서 제일 나쁜 고장"이다.
- **탐지용에서 vpc_flow를 뺀 이유** 두 가지: (1) 원시 용량이 압도적으로 커 시간당 스캔의 대부분을 혼자 차지한다. (2) flow 레코드에는 인증 주체가 없고 srcaddr도 대부분 내부 ENI라 상관 판단에 기여하는 정보가 거의 없다. flow가 실제로 필요한 룰(데이터 반출)은 원본 테이블을 직접 조회한다.
- **탐지용 창이 2일인 이유**: 파티션 단위가 하루라 프루닝 최소 단위도 하루다. 1일이면 UTC 자정 직후 룰의 lookback이 어제 파티션을 가리키는데 뷰에 그 파티션이 없어 구멍이 난다. (주석은 lookback을 "기본 60분"이라 쓰는데 실제 `siem_rule_lookback_minutes` 기본값은 75분이다 — 결론에 영향 없는 문서 드리프트다.)
- **뷰 생성 방법**: Glue VIRTUAL_VIEW를 Terraform으로 우겨넣는 방법은 base64 인코딩된 Presto 메타데이터를 손으로 관리해야 해 엔진 버전 변경 시 조용히 깨진다. 대신 저장 쿼리로 두고, **detector Lambda가 매 실행 앞머리에서 두 뷰의 CREATE OR REPLACE를 자동 실행**한다(DDL은 스캔 0바이트라 무료). "사람이 잊어서 탐지가 죽는" 경로를 없앤 것이고, 이 파일을 고치면 apply 후 한 시간 안에 뷰가 자동으로 최신화된다.

함정 하나를 짚어 두면, 헤더는 "5개 로그 테이블"·"5개 소스 전부"라고 쓰지만 아래 실제 정의(L110–120)에는 rds·eks가 추가돼 조사용 뷰는 **7개 소스**다. 주석이 초기 5개 시절에 쓰인 뒤 갱신되지 않은 흔적이다(L411의 검증 쿼리 주석도 동일).

### L66–79 · variable "security_events_window_days"

조사용 뷰의 시간창(일). `default = 7` — 사람이 사고를 되짚을 때 필요한 넓이와 스캔 비용의 타협점이다. 값이 뷰 정의에 박히므로 **이 변수가 곧 조사 쿼리 1회의 스캔량 상한을 결정**하고, 늘리면 y/m/d 테이블의 OR 절이 길어지며 스캔량도 비례해 는다. `validation`은 1~31로 제한하는데, 에러 메시지가 운영 지침을 겸한다: 그 이상 과거는 통합 뷰가 아니라 소스별 저장 쿼리로 보라는 것이다.

### L81–95 · variable "security_events_detection_window_days"

탐지용 뷰의 시간창. `default = 2`. 스케줄 탐지가 매 실행 이만큼을 스캔하므로 **SIEM 운영비를 사실상 이 값이 정한다**. `validation`이 하한을 2로 못 박은 것이 중요하다 — 1일이면 위에서 설명한 UTC 자정 경계 탐지 누락이 생기기 때문에 아예 입력 단계에서 막았다. 상한 7은 "그 이상이면 시간당 스캔 비용이 조사용 뷰를 넘어선다"는 역전 방지선이다.

### L98–159 · locals — 뷰 이름·목록·치환 값

- `security_events_view_name`/`security_events_detection_view_name` (L99–100): 뷰 이름 문자열을 한 곳에 고정한다. 탐지 룰 파일(`siem-detection-rules.tf` L177)이 후자를 참조하므로, 이름 변경이 한 지점에서 전파된다.
- `security_events_views` (L110–120): `뷰 이름 => { days, sources }` 맵. **여기에 한 줄 추가하면 뷰가 하나 더 생기는** 확장점이다. 두 뷰가 아래 같은 분기 템플릿을 재사용하므로 "조사와 탐지의 정규화 규칙이 어긋나 판단이 갈리는 사고"가 구조적으로 불가능하다는 것이 주석의 핵심 주장이다. 조사용은 7소스 전부, 탐지용은 `vpc_flow`와 `eks`를 뺀 5소스다. vpc_flow 제외는 이 파일 헤더가, eks 제외는 룰 파일(L179–182 주석: audit 양이 커 시간당 스캔 상한 위험, EKS 룰이 원본을 직접 파티션 프루닝해 조회)이 설명한다.
- `security_events_template_vars` (L139–159): 뷰별 치환 값. `db`·`region`·테이블 이름 7종은 뷰에 따라 변하지 않지만 전부 템플릿 변수로 통일했다 — 한 heredoc 안에 즉시 치환과 지연 치환이 섞이면 읽는 사람이 헷갈린다는 이유다. 시간창 표현이 두 갈래인 것이 이 블록의 요점이다:
  - `date_floor` (L152): 날짜형 파티션 프로젝션(cloudtrail/vpc_flow/alb)용. `projection.type=date, format=yyyy/MM/dd`라서 `event_date >= date_format(current_date - INTERVAL 'N' DAY, ...)` 범위 비교가 그대로 프루닝된다.
  - `ymd_window` (L154–157): 정수형 프로젝션(waf/application, rds/eks도 동일)용. year/month/day가 제로패딩 문자열 컬럼이라 범위 비교로는 프루닝이 안 되므로, `range(cfg.days)`를 돌며 `(year=.. AND month=.. AND day=..)` 등식 트리플을 날짜 수만큼 OR로 나열한다. `current_timestamp`가 쿼리 시점에 평가되므로 뷰는 계속 "최근 N일"로 굴러간다.
  - 두 방식의 커버 범위는 하루 어긋난다(`date_floor`는 `>=`라 N+1일, ymd는 정확히 N일). 주석은 이를 알고도 두는데, 어느 쪽이든 lookback보다 넉넉해 무해하고 **맞추려고 식을 비틀면 프루닝이 깨지기** 때문이다.

### L161–361 · locals — 소스별 SELECT 분기 템플릿 (`security_events_branch_templates`)

7개 소스 각각을 공통 8필드로 사상하는 SQL 조각들이다. 템플릿 앞의 규약 주석(L161–180)이 세 가지를 못 박는다. 첫째, 조각 안의 `$${...}`는 Terraform이 아니라 아래 `templatestring()`이 치환한다(heredoc에서 `$$`는 리터럴 `$`) — 뷰마다 시간창이 달라 **두 단계 렌더링**이 필요하기 때문이다. 둘째, UNION ALL은 위치 기준이라 타입이 어긋나면 즉시 실패하므로 시간은 전부 `CAST(... AS timestamp)`로 통일한다. `from_iso8601_timestamp`는 timestamp WITH TIME ZONE을, `from_unixtime`은 WITHOUT을 돌려주는 차이가 있고, Athena 세션 타임존이 UTC라 파티션 경로(UTC 기준)와도 맞는다. **이 뷰를 조회하는 쪽도 `CAST(current_timestamp AS timestamp)`로 비교해야 한다**는 요구가 룰 계약 ③으로 이어진다. 셋째, 시간 파싱은 전부 `try()`로 감싼다 — 레코드 하나가 깨졌다고 관제 화면이 통째로 안 뜨면 안 된다. 소스에 없는 개념은 `CAST(NULL AS varchar)`로 자리만 맞춘다.

#### cloudtrail (L184–198) — 누가 어떤 AWS API를 불렀나

`actor`는 `COALESCE(useridentity.arn, username, principalid)`로 셋 중 있는 값을 쓰고, `action`은 `concat(eventsource, ':', eventname)` — 룰의 액션 정규식("iam.amazonaws.com:CreateAccessKey" 형태 매칭)이 이 포맷에 의존한다. `outcome`은 `errorcode` 유무로 success/failure를 가르고, `detail`에 errorcode+errormessage를 합쳐 넣되 `NULLIF(..., ' ')`로 "둘 다 비어 공백 한 칸만 남는" 경우를 NULL로 정리한다. WHERE의 `region = '$${region}'`은 성능이 아니라 **정합성 조건이다**: region이 injected 프로젝션이라 등식 조건이 없으면 쿼리 자체가 실패한다.

#### vpc_flow (L202–215) — 어떤 ENI가 어디로 통신했나

주체 개념이 없어 `actor`에 `interface_id`(ENI)를 넣는다. `action`은 `flow:proto6` 같은 프로토콜 표기, `target`은 `dstaddr:dstport`, `outcome`은 ACCEPT→success / REJECT→blocked / 그 외 unknown. `detail`이 `bytes=.. packets=..` **문자열**이라는 점이 뒤에서 중요해진다 — 데이터 반출 룰이 이 뷰 대신 원본 테이블을 직접 보는 이유(bytes를 집계할 수 없음)가 여기서 생긴다. 조사용 뷰에만 포함된다.

#### waf (L219–233) — 엣지에서 무엇을 허용/차단했나

`timestamp`가 밀리초 epoch이라 `/ 1000.0`으로 초 단위로 바꿔 `from_unixtime`에 넣는다. 인증 주체가 없어 `actor`는 NULL 자리 맞춤. `action`은 `메서드 URI`, `outcome`은 ALLOW→success / BLOCK→blocked / 그 밖의 WAF 액션(COUNT, CAPTCHA 등)은 `lower()`로 그대로 흘린다. `detail`에 종결 룰 ID와 국가 코드를 담아 "무슨 룰이 왜 막았나"를 한 줄로 보이게 했다. 시간창은 `ymd_window`.

#### alb (L236–252) — WAF를 통과한 요청이 실제로 어떻게 처리됐나

`outcome`을 `elb_status_code`로 계층화한다: 500대→failure, 400대→blocked, 그 외→success. `detail`에 elb_status와 target_status를 나란히 둬 "ALB가 낸 오류인가 타깃이 낸 오류인가"를 구분할 수 있다. 파티션 컬럼 이름이 `"day"`(예약어 충돌 방지 따옴표)이고 날짜형 프로젝션이라 `date_floor` 비교를 쓴다.

#### application (L258–290) — 앱이 스스로 남긴 보안 이벤트

이 분기가 가장 방어적이다. 파이프라인 사정에 따라 값이 상위 컬럼(`p.timestamp` 등)에 올 수도, Firehose 처리 구조체(`p.log_processed.*`)에 올 수도 있어 **모든 필드를 COALESCE 이중 경로**로 읽는다(기존 `application_normalized_event_select` 관용구와 동일하다는 주석). `actor`는 principal→actorusername 순, `outcome`은 앱이 명시한 outcome 필드를 우선하고 없으면 statuscode(500대 failure / 400대 blocked)로 폴백한다. `detail`에 eventtype·reasoncode·exceptiontype을 합쳐, 룰 2(인증 실패 폭증)가 앱 계층의 `blocked/failure`를 뽑을 때 맥락이 따라가게 했다.

#### rds (L302–326) — 누가 DB에 접속해 무슨 작업을 했나

원문이 파싱 안 된 `message` 한 컬럼(MariaDB SERVER_AUDIT 플러그인의 CSV 한 줄: `timestamp,serverhost,username,clienthost,connid,queryid,operation,db,object,retcode`)이라 뷰에서 직접 파싱한다. 앞쪽 6개 필드는 값에 콤마가 없어 `split_part`로 안전하고, 9번째 object(쿼리 텍스트)에 콤마가 섞일 수 있으나 **사용하는 필드(1·3·4·7·8)는 전부 그 앞**이라 어긋나지 않는다는 위치 논증이 주석에 있다. retcode는 위치가 밀릴 수 있어 `regexp_extract(message, ',([0-9]+)\s*$', 1)`로 **줄 끝에서 직접** 집는다. `outcome`은 retcode=0→success / 숫자면→failure / 못 집으면 unknown. `operation=CONNECT`+retcode≠0 이 곧 인증 실패(access denied)라는 매핑이 룰 5·6의 전제다. `action`은 `CONNECT db명` 같은 `UPPER(op) db` 형태로 조립된다.

#### eks (L333–360) — 누가 K8s API에 무슨 동작을 했나

`message`에서 JSON을 `json_extract_scalar`로 뽑는다. `try(json_extract_scalar(message, '$.kind')) = 'Event'` 필터로 audit 이벤트만 남긴다 — api/authenticator 평문 로그는 kind가 없어 자동 제외된다. `source_ip`는 `sourceIPs` 배열의 첫 요소(대개 kubectl 호출자 IP 또는 내부 노드 IP), `actor`는 `user.username`, `action`은 `verb resource/subresource`(예: `create pods/exec`), `target`은 `namespace:name`. `outcome`은 responseStatus.code 403→blocked(인가 거부), 그 밖 4xx/5xx→failure. 조사용 뷰에만 포함된다.

### L363–379 · locals — 최종 뷰 SQL 조립 (`security_events_view_sql`)

뷰별로 `CREATE OR REPLACE VIEW "db"."뷰이름" AS` 머리말 뒤에, 그 뷰의 `sources` 목록에 든 분기만 `templatestring(분기템플릿, 뷰별치환값)`으로 렌더링해 `UNION ALL`로 잇는다. 같은 분기 템플릿이 창 크기만 다른 치환 값으로 두 번 쓰이는 구조라서, 두 뷰의 정규화 로직이 갈라질 수 없다는 보장이 코드 형태로 실현된 지점이다.

### L390–403 · resource "aws_athena_named_query" "create_security_events_view"

조립된 뷰 SQL을 저장 쿼리로 배포한다. `for_each`가 뷰 SQL 맵을 돌고, `name`은 조사용이면 `00-create-security-events-view`, 탐지용이면 `00a-...` — 저장 쿼리 목록에서 맨 위에 정렬되도록 00 접두를 쓴다(조사 쿼리가 00~16, 룰이 20번대를 쓰는 전체 네이밍 체계의 일부). `description`이 운영 지침을 겸한다: 조사용은 "CREATE OR REPLACE라 재실행 무해", 탐지용은 "Lambda가 매 실행 자동으로 돌리므로 손으로 실행할 필요 없다". `database`·`workgroup`은 중앙 로그 DB와 1 GiB 상한 워크그룹을 가리킨다. **이 named query의 ID가 detector의 rules.json manifest(`views` 배열)로 들어가**, Lambda가 매 실행 앞에서 SQL을 읽어 실행하는 연결 고리가 된다.

### L405–425 · resource "aws_athena_named_query" "verify_security_events_view"

`00b-verify-...` 검증 쿼리. 조사용 뷰를 `source_type`별로 GROUP BY 해 events/distinct_ips/oldest/newest를 뽑는다. 용도는 "뷰가 살아 있는가"와 "**어떤 소스가 실제로 데이터를 내고 있는가**"의 동시 확인이다 — 특정 source_type이 0건이면 뷰 문제가 아니라 그 로그 파이프라인이 안 도는 것이니 소스를 먼저 보라는 트리아지 순서가 주석에 있다. 매일 destroy/apply 하는 환경이라 그날 트래픽이 없으면 ALB/앱 로그가 정당하게 0일 수 있다는 운영 각주도 붙어 있다.

### L432–445 · outputs 3종

`security_events_view_name`(사용 전 00 쿼리 1회 실행 안내 포함), `security_events_view_window_days`(창 밖 로그는 소스별 쿼리로), `security_events_detection_view_name`(Lambda가 매 실행 재생성). output description이 전부 "다음에 무엇을 해야 하는가"를 담는 운영 문서 역할을 한다.

---

## log-archive/siem-detection-rules.tf (698줄)

탐지 룰 10개의 **단일 원본**이다. 룰은 `locals.siem_rules` 맵에 SQL heredoc으로 정의되고, `aws_athena_named_query`로 배포된다. detector Lambda는 이 named query의 ID로 SQL을 읽어 실행하므로, 콘솔에서 사람이 튜닝하며 돌려 보는 쿼리와 매시간 자동 실행되는 쿼리가 **같은 문자열임이 보장**된다. 임계값은 전부 variable로 뽑아 apply만으로 조정 가능하고, 룰 추가는 맵에 항목 하나를 더하는 것으로 끝난다.

### L1–46 · 파일 헤더 주석 — 룰의 역할 정의와 계약

- **위치**: 수집 → 정규화(security-events-view.tf) → **탐지(이 파일)** → 실행(siem-detector.tf) → 알림(siem-alerts.tf).
- **룰의 역할은 "정확한 탐지"가 아니라 "후보 생성"**: 뒤에 Groq 판정이 붙으므로 임계값을 재현율 우선으로 낮게 잡는다. 깔때기 구조(원시 하루 수십만 건 → 룰이 후보 수십 건으로 → 판정 → 알림)에서 볼륨은 룰이 잡고, 판정 호출량은 후보 수에 비례해 무료 티어로 감당된다. 순서가 뒤집히면 비용이 성립하지 않는다.
- **판정이 있어도 룰이 SQL이어야 하는 이유 4가지**: ① 재현성 — "그때 왜 안 울렸나"에 조건을 읽어 답할 수 있다. 모델이 좌우하는 것은 정밀도(무엇을 알릴지)뿐이고 재현율은 결정론적으로 남는다. ② 감사 — 룰 변경이 git diff로 남아 임계값의 이력이 추적된다. ③ 비용 — 상시 동작 층에 종량 API를 걸지 않는다. ④ 프롬프트 인젝션 — 공격자가 값을 정할 수 있는 문자열(User-Agent, 버킷 이름)이 룰에 들어와도 SQL 조건문은 그걸 지시로 읽지 않는다. 모델에는 룰이 집계한 결과표만 간다.
- **룰 계약 3가지** (detector가 전제로 동작): ① 첫 컬럼은 반드시 `alert_key` — 중복 억제 단위이자 "무엇을 하나의 사건으로 볼 것인가"를 룰이 정하는 자리다(판정 프롬프트·Discord 표에서는 자동 제외). ② 조회 대상은 탐지용 뷰 또는 원본 테이블 — 조사용 뷰를 쓰면 스캔량이 몇 배가 된다. ③ 시간창은 룰 SQL이 스스로 건다 — 호출자가 잊어도 새지 않아야 하며, `current_timestamp`가 WITH TIME ZONE이라 `CAST(... AS timestamp)` 없이 뷰의 event_time과 비교하면 타입 오류가 난다.

### L48–63 · variable "siem_rule_lookback_minutes"

룰 1회 실행이 들여다보는 시간 범위. `default = 75` = 스케줄 rate(1 hour) + 15분 여유. 여유분의 근거는 **로그 배달 지연**이다(CloudTrail 최대 15분, ALB 5분, Firehose 버퍼). 주기와 lookback이 겹치는 구간에서 같은 사건이 다시 잡히는 것은 DynamoDB 중복 억제가 처리하므로, "겹쳐서 손해 볼 일은 없고 모자라면 탐지에 구멍이 난다"는 비대칭이 설계 원리다. validation 15~1440.

### L65–82 · variable "siem_auth_failure_threshold"

인증/인가 실패 폭증 룰(그리고 룰 5·8이 재사용)의 임계값. `default = 8` — (출발지 IP × 주체) 조합의 실패가 lookback 안에 8건을 넘으면 **후보**로 올린다(알림 확정 아님). 낮게 잡은 논리가 명확하다: 배포 직후의 정상 권한 오류가 걸리는 것은 의도된 것이고 그걸 거르는 게 판정의 일이다. 반대로 값을 올리면 느린 크리덴셜 스터핑을 **구조적으로**(판정으로도 복구 불가하게) 못 잡는다. validation 하한 3의 에러 메시지도 실질적이다 — 그 이하는 후보가 너무 많아 판정 호출 상한을 태운다.

### L84–101 · variable "siem_cross_layer_denied_threshold"

룰 1에서 CloudTrail 계층이 끼지 않았을 때 요구하는 거부 건수. `default = 5`. 이 변수의 존재 이유가 곧 룰 1의 핵심 보정이다: **WAF와 ALB는 같은 요청을 두 번 기록**하므로 "2개 계층 출현"만으로는 모든 정상 트래픽이 걸린다. 외부 IP가 CloudTrail(AWS API)까지 닿았다면 계층 수만으로 이상하지만, 아니라면 거부가 이만큼 쌓여야 후보다.

### L103–120 · variable "siem_egress_bytes_threshold"

데이터 반출 룰 임계값(바이트). `default = 268435456`(256 MiB). 이 룰이 오탐이 가장 많음(ECR 풀, OS 업데이트, S3 전송이 전부 "내부→외부 대량 아웃바운드")을 알면서도 낮게 잡은 이유는 판정 계층의 존재다. 운영 지침이 값보다 중요하다: 정상 목적지가 파악되면 **임계값을 올리지 말고 `siem_egress_ignore_dst_regex`로 빼라** — 진짜 반출은 조용히 조금씩 나가기도 해서 임계값을 올리면 그쪽을 통째로 못 본다. validation ≥1 MiB.

### L122–130 · variable "siem_egress_ignore_dst_regex"

반출 룰의 목적지 제외 정규식. `default = ""`(제외 없음). 운영하며 확인된 정상 대역(예: ECR/S3 엔드포인트)을 넣는 화이트리스트 자리다. 빈 값 처리 방식은 L228–232의 clause locals가 담당한다.

### L132–147 · variable "siem_trusted_automation_principals"

룰 3(권한 상승·감사 무력화)에서 제외할 주체 ARN 정규식 목록. `default = []`. terraform apply 자체가 KMS 키 정책·버킷 정책·IAM을 계속 건드리므로 비워 두면 apply 하는 날마다 알림이 쏟아진다. 다만 경고가 핵심이다: **여기 넣는 순간 그 주체의 권한 변경은 영원히 안 보인다.** 변경 경로가 코드 리뷰로 따로 감사되는 IaC 파이프라인 역할만 넣고, 사람 계정은 절대 넣지 말 것 — 탈취되면 그게 바로 이 룰이 잡아야 할 사건이다.

### L149–161 · variable "siem_db_expected_principals"

RDS에서 "정상"으로 보는 DB 접속 주체 정규식 조각 목록. `default = ["admin", "gochuchamchi_app_iam", "mariadb\\.sys", "mysql\\.sys", "rdsadmin"]` — 배스천 운영 계정, 앱 IAM 계정, 엔진 내부 계정이다. 이 변수는 룰 6의 허용 목록이면서 동시에 **IAM 토큰 전환(DB 비밀번호 제거 작업)의 상시 검증 축**이다: 구 비밀번호 계정 `gochuchamchi_app`이 목록에 없으므로 그 접속이 한 건이라도 잡히면 "비밀번호 계정이 되살아나고 있다"는 신호가 된다. 수동 스크립트 `verify-db-iam-only.ps1`이 보던 것을 자동 상시화한 것이다.

### L163–172 · variable "siem_app_upload_burst_threshold"

앱 상품 등록(`POST /shop/register`) 폭증 임계값. `default = 10`. 근거는 애플리케이션의 알려진 약점이다: 상품 이미지 업로드가 확장자·Content-Type 검증이 약해(spring S3Service), 신뢰 도메인(CloudFront)에 임의 HTML/SVG를 뿌리는 통로가 될 수 있다. 그 남용을 빈도로 잡고, 정상 판매자의 다건 등록은 판정이 거른다.

### L175–237 · locals — 조회 대상·공통 SQL 조각

- `siem_detection_view` / `siem_flow_table` / `siem_eks_table` (L177–182): 룰이 조회할 세 대상의 완전 수식 이름(`"db"."table"`). EKS audit를 탐지용 통합 뷰에 넣지 않는 이유(양이 커 스캔 상한 위험)와 대안(EKS 룰이 원본을 직접 조회하되 `eks_control_plane_recent_partition` — 다른 파일에 정의된 오늘+어제 파티션 조건 — 으로 프루닝)이 여기 주석에 있다.
- `siem_recent_window` (L186): 뷰 조회 공통 시간 조건 `event_time >= CAST(current_timestamp AS timestamp) - INTERVAL 'N' MINUTE`. CAST가 빠지면 타입 불일치로 실패하는 함정을 한 곳에 캡슐화했다.
- `siem_private_ip_regex` (L190): RFC1918(10/8, 172.16/12, 192.168/16)+루프백+링크로컬+IPv6 ULA(fd)/링크로컬(fe80)을 묶은 정규식. 내부 통신이 여러 계층에 찍히는 것은 정상이므로 외부 출발지 룰에서 제외하는 용도다.
- `siem_privilege_escalation_regex` (L197–205): `(?i)^iam\.amazonaws\.com:(...)$` — 뷰의 `action` 포맷(`eventsource:eventname`)에 앵커드 매칭한다. 열거된 액션은 셋으로 묶인다: 자격증명 신설·탈취 계열(CreateUser/CreateAccessKey/CreateLoginProfile/UpdateLoginProfile), 정책 부여 계열(Attach{User,Role,Group}Policy / Put{User,Role,Group}Policy), 우회·해제 계열(CreatePolicyVersion/SetDefaultPolicyVersion — 기본 버전 교체로 감사를 피하는 고전 수법, UpdateAssumeRolePolicy — 신뢰 정책을 열어 남의 역할을 차지, AddUserToGroup, Delete{User,Role}PermissionsBoundary — 상한 제거).
- `siem_audit_tampering_regex` (L209–219): 증거를 지우거나 탐지를 끄는 조작을 서비스별로 열거한다 — CloudTrail(StopLogging/DeleteTrail/UpdateTrail/PutEventSelectors), GuardDuty(디텍터 삭제·수정, 필터 생성, 멤버 분리 등), Config(레코더·전달 채널 중지·삭제·수정), Security Hub(비활성화·표준 해제), KMS(DisableKey/ScheduleKeyDeletion/PutKeyPolicy — 로그 암호화 키를 죽이면 로그가 안 쌓인다), CloudWatch Logs(로그 그룹·구독 필터·보존 정책 삭제), S3(버킷 정책·버저닝·수명주기·Object Lock·로깅 조작, 버킷 삭제). 주석의 원칙: **실패한 시도도 알린다 — 시도 자체가 신호다.**
- `siem_trusted_actor_clause` / `siem_egress_ignore_clause` (L222–232): 변수 목록이 비면 **절 자체를 생성하지 않는다**. "빈 정규식은 전부 매칭"이라는 정규식 함정(빈 문자열을 `NOT regexp_like`에 넣으면 모든 행이 제외됨)을 조건부 문자열 조립으로 피한 것이다. 절이 개행(`\n`)으로 끝나므로 룰 SQL의 `${clause}ORDER BY` 접합부가 자연스럽게 줄바꿈된다.
- `siem_db_expected_principal_regex` (L236): 목록을 `^(a|b|c)$`로 합친다.

### L239–669 · locals.siem_rules — 룰 정의 10개

맵 직전 주석(L239–256)이 룰 메타필드의 계약을 정의한다. `seq`는 Athena 저장 쿼리 이름의 정렬 번호(조사 쿼리가 00~16을 쓰므로 룰은 20번대), `severity`(CRITICAL/HIGH/MEDIUM)는 Discord 색과 제목 아이콘을 정할 뿐 **자동 대응은 하지 않는다**("이 파이프라인은 알리는 것까지만 한다" — 이후 `siem_response_enabled`가 이 경계를 명시적 스위치로 넘게 되지만 기본은 여전히 false다). `title`은 알림 제목, `why`는 이 룰이 울렸을 때 무엇을 의심해야 하는지를 담아 **알림 본문과 판정 프롬프트에 동시에** 실린다 — 즉 why 문구가 곧 모델에게 주는 "룰 작성자의 의도"이고 판정 품질에 직접 영향을 준다. `always_alert = true`면 판정이 benign이어도 무조건 통보한다 — benign 판정이 알림을 없애는 구조에서 모델 오판이 곧 미탐이 되므로, "한 건이 곧 사건"인 룰에만 켠다(전부 켜면 판정이 무의미, 다 끄면 미탐이 조용해진다). 모든 룰 SQL은 `LIMIT 50`으로 끝나 한 번에 처리할 후보 수에 뚜껑을 씌운다.

#### 룰 1 — "cross-layer-ip" · 동일 IP 다계층 출현 (L259–306, seq 20, HIGH)

주석 스스로 "이 파이프라인의 존재 이유를 그대로 보여주는 룰"이라 부른다. 단일 로그만 보면 "WAF 차단 몇 건 / 앱 403 몇 건"으로 흩어져 아무도 안 보지만, 같은 외부 IP가 엣지·앱·AWS API에 동시에 나타났다면 훑어보는 중이다 — 정규화 뷰 없이는 이 질문 자체를 쿼리로 쓸 수 없다. 로직: CTE `normalized`에서 최근 창의 이벤트 중 source_ip가 실제 IP 형태(`^[0-9a-fA-F:.]+$` — CloudTrail은 AWS 서비스 호출 시 IP 자리에 `ecs.amazonaws.com` 같은 서비스명을 넣으므로 걸러야 한다)이고 사설 대역이 아닌 것만 남긴 뒤, IP별로 `count(DISTINCT source_type)`(계층 수), `layer_list`, 총 건수, `denied_count`(blocked/failure)를 집계한다. HAVING이 이 룰의 두뇌다: 계층 2개 이상이면서 (a) cloudtrail 계층이 하나라도 있으면 그 자체로 후보(외부 IP가 AWS API에 닿음), (b) 아니면 거부가 `siem_cross_layer_denied_threshold`(5) 이상 — WAF+ALB 이중 기록 오탐을 거르는 보정이다. `alert_key = 'cross-layer-ip:' + source_ip`라 같은 IP는 dedup 기간 동안 한 번만 알린다. `why`는 판정 모델에게 layer_list의 cloudtrail 유무와 denied_count 해석 기준까지 알려 준다.

#### 룰 2 — "auth-failure-burst" · 인증·인가 실패 폭증 (L308–356, seq 21, HIGH)

설계에서 뺀 것이 핵심이다: **WAF·ALB의 4xx는 일부러 뺐다** — 스캐너 한 대가 차단 수천 건을 만드는데 그건 이미 WAF가 막은 것이고, 섞으면 임계값이 무의미해진다. 남긴 것은 "인증 경계를 실제로 두드린 흔적" 둘: (a) CloudTrail의 권한 거부 계열 — `outcome='failure'`이면서 detail이 `accessdenied|unauthorized|invalidclienttokenid|signaturedoesnotmatch|notauthorized|expiredtoken`에 매칭(자격증명은 유효한데 권한이 없다 = 탈취된 키로 범위를 재는 중일 수 있다), (b) 애플리케이션 자체 기록 로그인 실패/권한 거부(`source_type='application'` AND outcome IN blocked/failure). (출발지 IP × 주체)로 묶어 임계값 8 이상이면 후보. 출력에 `sample_actions`(어떤 API들이 거부됐나, 정렬 후 5개)와 first/last_seen을 실어 판정 근거를 준다. `why`가 판별 휴리스틱을 명문화한다: actor가 자동화 역할이고 실패가 한 서비스에 몰리면 배포 직후 권한 누락, 사람 계정이거나 여러 서비스에 흩어지면 권한 탐색.

#### 룰 3 — "privilege-audit-tampering" · 권한 상승·감사 무력화 (L358–401, seq 22, CRITICAL, always_alert)

유일하게 집계하지 않고 이벤트를 한 건씩 그대로 올리는 룰이다 — 건수가 적고 한 건이 곧 사건이기 때문이다. CloudTrail 이벤트 중 action이 권한 상승 정규식 또는 감사 무력화 정규식에 매칭되면 전부 후보이고, `CASE`로 `category`(audit-tampering / privilege-escalation)를 붙여 어느 쪽인지 구분하게 했다. **실패한 시도도 올린다** — "CloudTrail을 끄려다 SCP에 막혔다"는 성공만큼 중요한 신호다. `always_alert = true`의 인라인 근거(L372–373): 이 룰이 놓치는 한 건이 곧 사고이고, "계획된 apply였는가"는 로그만 봐서는 모델도 사람도 확정할 수 없다 — 그래서 why에도 "정상으로 단정하지 말고 actor에게 직접 확인하라"가 들어간다. 유일한 튜닝 지점은 IaC: `siem_trusted_actor_clause`가 신뢰 자동화 주체를 빼 준다. `alert_key = actor|action|target` 조합이라 같은 apply가 여러 리소스를 건드리면 리소스별로 한 건씩 온다.

#### 룰 4 — "data-egress" · 외부로의 대량 아웃바운드 (L403–445, seq 23, MEDIUM)

유일하게 통합 뷰가 아니라 **원본 `vpc_flow_logs` 테이블을 직접** 본다. 이유 둘: bytes 합계가 필요한데 뷰에서는 그 값이 detail 문자열 안이라 집계 불가하고, flow는 원시 용량이 가장 커 탐지용 뷰에서 뺐다 — parquet이라 필요한 컬럼만 읽히므로 직접 읽는 편이 훨씬 싸다. WHERE의 3단 필터를 구분해 읽어야 한다: `region = ...`은 injected 프로젝션이라 필수 등식, `event_date >= 어제`는 파티션 프루닝(하루 단위), `"start" >= to_unixtime(current_timestamp) - lookback*60`이 실제 시간창이다(start/end는 epoch 정수). 방향 필터는 srcaddr가 사설 대역이고 dstaddr가 사설 대역이 아닌 ACCEPT 트래픽 — 즉 내부→외부 허용 통신만 남긴다. (내부 출발지→외부 목적지) 쌍으로 합산해 256 MiB를 넘으면 후보. 출력의 `dst_ports`(최대 10개)가 판정의 핵심 근거다 — why에 명문화된 휴리스틱: 443 단일 + AWS 대역이면 정상 쪽, 비표준 포트·모르는 대역이면 srcaddr 인스턴스의 프로세스를 확인. `alert_key = 'egress:src->dst'`.

#### 룰 5 — "db-auth-failure" · DB 인증 실패 폭증 (L447–479, seq 24, HIGH)

RDS 감사(`source_type='rds'`)의 `CONNECT` 실패만 본다. 룰 2의 앱 로그인 실패와 계층이 다르다 — 여긴 "DB 엔진이 직접 거부한" 접속이다. `action LIKE 'CONNECT%'`(뷰의 action이 `CONNECT db명` 형태라 전방 일치) AND `outcome='failure'`를 (출발지 × DB 유저)로 묶어 임계 8 이상이면 후보. IAM 토큰 만료·리전 오설정 같은 정상 사유도 걸리지만 그 판별은 판정의 일이다. why의 판별 기준: actor가 `gochuchamchi_app_iam`이고 배포 직후면 IAM 토큰 발급 경로 문제 가능성, 낯선 유저명이거나 한 IP에서 여러 유저명이 나오면 유효 계정 탐색. `require_secure_transport=1`이라 비 TLS 접속 시도도 여기서 실패로 잡힌다는 각주가 있다.

#### 룰 6 — "db-unexpected-principal" · 예상 밖 DB 계정 접속 (L481–513, seq 25, CRITICAL, always_alert)

허용 목록(`siem_db_expected_principals`)을 벗어난 유저의 **성공** 접속을 집계 없이 한 건씩 올린다 — 한 건이 곧 사건이다. 조건: rds + `CONNECT%` + `outcome='success'` + `NOT regexp_like(actor, 허용정규식)`. 이 룰의 이중 역할이 프로젝트 서사와 직결된다: 일반적 의미의 "계정 신설·탈취 탐지"이면서, 동시에 DB 비밀번호 제거(IAM 인증 전환) 작업의 회귀 감시다 — actor가 구 비밀번호 계정 `gochuchamchi_app`이면 전환이 되돌아가고 있다는 신호. why는 트리아지 첫 수순("배스천에서 사람이 수동 작업 중이었는지 먼저 확인")까지 준다. `alert_key = actor|source_ip`.

#### 룰 7 — "eks-pod-exec" · 컨테이너 셸 접근 (L515–553, seq 26, CRITICAL, always_alert)

EKS audit **원본 테이블**을 직접 본다(통합 뷰 미포함 — 용량). `kind='Event'` + `verb='create'` + `objectRef.subresource IN ('exec','attach')` — kubectl exec/attach는 pods의 exec 서브리소스에 대한 create 요청으로 기록된다는 K8s audit 구조를 그대로 쓴 조건이다. 파티션은 `eks_control_plane_recent_partition`(오늘+어제)으로 프루닝하고, 시간창은 `requestReceivedTimestamp` 파싱값으로 별도 필터한다. 이 클러스터는 배포를 GitOps로만 하므로 사람이 파드에 들어갈 일이 정상 운영에 거의 없다 — 그래서 한 건씩 always_alert다. **403으로 거부된 시도도 올린다**(code 컬럼 포함) — 침해 주체가 권한을 재는 신호다. `alert_key = username|namespace/pod` 조합이라 같은 사람이 같은 파드에 반복 exec 해도 dedup 기간엔 한 번만 알린다.

#### 룰 8 — "eks-forbidden-burst" · K8s 인가 거부 폭증 (L555–596, seq 27, HIGH)

같은 주체/출발지에서 K8s API 403이 몰리면 권한 탐색이다. `WITH audit AS (...)`로 JSON 파싱을 먼저 끝내고 바깥 쿼리에서 `code='403'` 필터+GROUP BY를 하는 2단 구조 — 파싱 표현식을 GROUP BY에 반복하지 않기 위한 정리다(파티션 프루닝 조건은 CTE 안에 있어 프루닝은 유지된다). 임계값은 룰 2와 같은 `siem_auth_failure_threshold`(8)를 재사용한다. 출력의 `resources`(거부당한 리소스 종류, 최대 8개)가 판정 축이다: secrets·rolebindings 같은 민감 리소스가 섞이면 권한 상승 시도, 한 리소스에 몰리면 배포 설정 오류 가능성 — why에 그대로 들어 있다.

#### 룰 9 — "app-admin-path-probe" · 관리자 경로 무단 접근 (L598–632, seq 28, HIGH)

앱이 인가 거부한 요청 중 관리자 경로만 특정한다: `source_type='application'` + `outcome='blocked'` + action이 `(?i)/admin(/|$| )` 매칭(경로 중간의 `/administrator` 같은 우연 매칭을 줄이려 뒤 경계를 `/`·끝·공백으로 제한 — action이 "METHOD URI" 형태라 공백 경계가 유효하다). 룰 2가 앱 거부를 임계 8로 집계하는 것과 달리 **HAVING count(*) >= 3**의 낮은 하드코딩 임계를 따로 쓴다 — 근거는 SecurityConfig상 `/admin/**`은 ADMIN/SUPERADMIN 전용이라 일반 유저가 이 경로를 볼 일 자체가 없으므로 한두 건도 의미가 있다는 것이다. why의 구분: actor가 로그인 계정이면 세션 탈취 또는 내부자 시도, 여러 경로를 훑으면(sample_actions) 자동화 스캔.

#### 룰 10 — "app-upload-burst" · 상품 등록(업로드) 폭증 (L634–667, seq 29, MEDIUM)

한 주체의 짧은 시간 대량 상품 등록을 업로드 통로 남용으로 본다. 조건: application + `outcome='success'` + action이 `(?i)POST\s+\S*/shop/register` 매칭(성공한 등록만 — 거부된 것은 다른 룰의 영역). actor(+source_ip)별 집계로 임계 10 초과 시 후보. 위협 모델은 변수 해설과 동일하다: S3Service가 확장자·MIME을 검증하지 않아, 대량 등록은 신뢰 도메인에 악성 HTML/SVG(피싱)를 뿌리거나 스토리지를 소진시키는 통로일 수 있다. 정상 판매자의 재고 갱신은 판정이 걸러 준다(재현율 우선의 전형). `alert_key = 'app-upload:' + actor` — IP가 아니라 주체 단위 사건으로 정의했다.

### L672–689 · resource "aws_athena_named_query" "siem_rule"

룰 맵을 `for_each`로 돌며 저장 쿼리로 배포한다. `name = "${seq}-rule-${key}"`(예: `22-rule-privilege-audit-tampering`)라 콘솔 목록에서 조사 쿼리(00~16) 뒤 20번대에 정렬되고, `description`에 severity·title·lookback을 넣어 목록만 봐도 룰의 성격이 보인다. 헤더 주석의 선언이 이 리소스의 존재 의의다: **이 named query가 룰의 유일한 원본**이고, detector Lambda가 이 ID로 SQL을 읽어 실행하므로 콘솔에서 손으로 돌려 본 것과 매시간 자동 실행되는 것이 절대 어긋나지 않는다 — 튜닝할 때 두 곳을 고칠 일이 없다.

### L692–698 · output "siem_detection_rules"

`저장 쿼리 이름 => severity` 맵을 출력한다. apply 직후 어떤 룰이 어떤 심각도로 등록됐는지 한눈에 확인하는 용도다.

---

## log-archive/siem-detector.tf (654줄)

SIEM의 **실행 엔진**이다. `EventBridge(rate) → siem-detector Lambda → Athena(룰) → Groq(판정) → SNS` 한 줄이 전부를 요약한다. 파일의 절반이 variable인데, 이는 판정 계층(Groq)의 동작·비용·안전 스위치를 전부 코드 밖에서 조정 가능하게 만들기 위한 것이다. 나머지가 시크릿 그릇, 중복 억제 DynamoDB, 최소 권한 IAM, 배포 패키지(룰 manifest 포함), Lambda 본체, 스케줄, 자기 감시 알람이다.

### L1–20 · 파일 헤더 주석 — 비용 성립 논리와 자기 감시

비용이 성립하는 이유를 서비스별로 계산해 둔다: **Athena**는 탐지용 뷰가 2일·축소 소스로 좁혀져 1시간마다 룰을 돌려도 하루 수 GB → 월 $1 미만이고, 워크그룹의 쿼리당 1 GiB 상한이 위쪽 뚜껑이다. **Groq**는 후보가 있을 때만 룰당 1회 — 최악도 시간당 4회(주: 룰이 10개로 늘어난 현재는 시간당 최대 10회) 수준이고 일일 상한이 한 겹 더 걸리며, **원시 로그는 모델로 가지 않는다**(룰이 집계한 표만 간다). **Lambda**는 1시간 간격이라 프리티어 안이다. 이어서 자기 감시 철학: 실행마다 `DetectionRunSuccess=1`을 찍고 두 주기 연속 안 찍히면 알람 — "알림이 없는 것"과 "탐지가 멈춘 것"이 구분되지 않는 상태가 SIEM에서 가장 위험한 고장이라는 명제다.

### L22–31 · variable "siem_schedule_expression"

탐지 주기. `default = "rate(1 hour)"`. description의 비용 논리가 비직관적이라 중요하다: **주기를 줄여도 실행 1회당 스캔량은 안 준다** — 파티션 단위가 하루라서다. 즉 rate(15 minutes)로 바꾸면 탐지는 4배 빨라지지만 스캔 비용도 정확히 4배가 된다. 나머지 기본값(lookback 75분, 탐지 뷰 2일)이 이 주기에 맞춰져 있다는 결합 관계도 명시한다.

### L33–37 · variable "siem_schedule_enabled"

`default = true`. 긴급 정지 스위치 — 리소스는 남기고 실행만 멈춘다(EventBridge 룰의 `state`로 연결). destroy 없이 탐지를 끄는 최소 침습 수단이다.

### L39–52 · variable "siem_alert_dedup_hours"

같은 `alert_key`를 다시 알리지 않는 기간. `default = 6`. 룰이 매 주기 같은 대상을 반복해 잡는 구조라 이게 없으면 한 사건으로 알림이 수십 번 온다. 트레이드오프가 정직하게 적혀 있다: 짧으면 알림 반복, 길면 상황이 악화돼도 조용하다. validation 1~72시간.

### L54–58 · variable "siem_max_rows_in_alert"

알림 본문과 판정 프롬프트에 싣는 최대 행 수. `default = 10`. 늘리면 판정 입력 토큰이 비례해 는다 — 비용 손잡이임을 명시한다. Lambda 환경변수에서 `MAX_ROWS_IN_ALERT`와 `GROQ_MAX_ROWS` 둘 다에 같은 값이 들어가, 사람이 보는 표와 모델이 보는 표가 같다.

### L62–69 · variable "siem_judge_enabled"

Groq 판정 계층 전체 스위치. `default = true`. false면 룰이 잡은 후보가 전부 그대로 알림이 된다 — **탐지는 그대로 동작하고 소음만 는다.** Groq 계정 문제 시 급히 떼어내는 격리 스위치로, 판정 계층 장애가 탐지 계층을 못 죽이게 하는 설계다.

### L71–98 · variable "siem_groq_model"

`default = "openai/gpt-oss-120b"`. description이 사실상 모델 선정 ADR이다. 2026-08-12 기준 Groq 생산 모델 4종 비교표(가격 $/M 입력·출력, 처리 속도)를 박제하고 결론을 적는다: 120b가 llama-3.3-70b보다 **싸고 빠르고 크다** — 모든 축 우위라 고민할 여지가 없고, 게다가 Llama 3.3의 공식 지원 언어에 한국어가 없는데 이 판정은 한국어로 답해야 한다. 20b와의 차이는 월 $1 미만이라 비용으로 내릴 이유가 약하다. 경고 두 개가 실전적이다: ① **도구(웹 검색·코드 실행)가 붙은 시스템 금지** — 판정 입력에 공격자가 값을 정하는 문자열(버킷 이름, User-Agent, 역할 이름)이 들어가므로, 도구가 붙으면 프롬프트 인젝션이 오판을 넘어 실제 외부 요청으로 증폭된다. 도구 없는 순수 추론 모델만 쓴다. ② 모델 목록은 수시로 바뀌므로 apply 전 `siem/check-groq.py`로 확인 — 없는 모델이면 판정이 전부 "판정 없음"으로 떨어지는데 알림은 계속 나와 알아채기 어렵다. JSON 구조화 출력(`response_format`) 지원이 필수 요건이다.

### L100–104 · variable "siem_groq_endpoint"

`default = "https://api.groq.com/openai/v1/chat/completions"`. OpenAI 호환 엔드포인트라 다른 호환 게이트웨이로 갈아끼울 수 있는 이식성 변수다.

### L106–110 · variable "siem_groq_timeout_seconds"

판정 호출 1건 타임아웃. `default = 20`. 넘기면 그 룰은 "판정 없음"으로 통보된다 — 판정 실패가 알림 자체를 막지 않는다는 실패 격리 원칙의 한 예다.

### L112–124 · variable "siem_groq_max_tokens"

판정 응답 최대 출력 토큰. `default = 4000`. 실제 겪은 버그가 근거다: gpt-oss·qwen3 계열은 **추론 모델**이라 최종 JSON 앞에 사고 과정 토큰을 먼저 생성하는데, 예산이 빠듯하면(실제 700으로 잡았다가) JSON을 시작하기도 전에 소진돼 400 `json_validate_failed`로 떨어진다. "상한이지 지출이 아니다 — 실제 생성 토큰만 과금되므로 넉넉히 둔다"는 문장이 값 선정 원리다.

### L126–144 · variable "siem_groq_reasoning_effort"

추론 깊이. `default = "low"`. 사고 과정 토큰도 **출력 단가로 과금**되므로 이 값이 곧 판정 비용이다. 이 판정은 표 몇 줄을 보고 정상 자동화인지 가르는 일이라 깊은 추론이 필요 없고, low면 응답 시간도 같이 준다. 빈 문자열(`""`)이면 파라미터를 아예 안 보낸다 — 이 파라미터를 모르는 모델이 400을 낼 때의 탈출구. validation은 ""/low/medium/high만 허용.

### L146–154 · variable "siem_judge_daily_call_limit"

하루 판정 호출 상한. `default = 300`. 무료 티어 한도를 넘겨 429를 맞기 전에 **우리가 먼저 멈추는** 능동 제한이다. 상한에 걸려도 탐지와 알림은 계속되고 판정(설명)만 빠진다 — 역시 판정 계층 실패의 격리. 카운터는 아래 DynamoDB 테이블의 `judge-quota#<날짜>` 항목이다.

### L156–166 · variable "siem_response_enabled"

urgent 판정을 Workload 계정 자동대응(WAF 24시간 차단)으로 넘길지. `default = false`. 이 파이프라인의 원래 경계가 "알리는 것까지"이므로, 그 경계를 넘는 스위치는 **명시적으로** 켜야 한다는 설계다. 켜도 조건이 좁다 — severity CRITICAL/HIGH + verdict=malicious + confidence ≥ `siem_response_min_confidence` + 공인 source_ip. 그리고 실제 차단은 Workload 격리 Lambda의 `waf_response_enabled`가 **다시** 게이트한다(이중 스위치: 발신 측과 수신 측이 각자 꺼짐이 기본).

### L168–177 · variable "siem_response_min_confidence"

자동대응으로 넘기기 위한 malicious 판정 최소 확신도. `default = 0.8`, validation 0.5~1.0(0.5 미만은 아예 못 넣게). 낮추면 오탐 대응(멀쩡한 IP 차단)이 는다.

### L179–192 · variable "siem_judge_benign_min_confidence"

benign 판정으로 **알림을 생략**하려면 필요한 최소 확신도. `default = 0.7`. 이 변수의 양 끝이 시스템 성격을 정의한다: 0에 가까울수록 조용해지지만 모델 오판이 곧 미탐이 되고, 1이면 판정이 알림을 없애지 못하고 설명만 붙는 가장 보수적인 모드가 된다. always_alert 룰에는 애초에 적용되지 않는다.

### L194–205 · variable "siem_judge_strict_masking"

`default = false`. 켜면 IAM 역할 이름·버킷 이름 같은 리소스 이름까지 가명화해 Groq에 보낸다. 계정 ID·내부 IP·이메일은 이 값과 무관하게 **항상** 가려진다(기본 마스킹 층이 따로 있다는 뜻). 기본이 false인 이유가 명확하다: "이 역할이 CI 자동화인가 사람인가"가 판정의 핵심 근거인데 이름을 가리면 그 판단이 불가능해진다 — 즉 정확도와 기밀성의 트레이드오프이고, 리소스 이름 규칙에 비밀이 들어가는 환경에서만 켜라고 못 박는다.

### L208–230 · resource "aws_secretsmanager_secret" "siem_groq_api_key"

Groq API 키의 **그릇만** Terraform이 만들고 값은 사람이 넣는다. 근거: variable로 받으면 tfstate에 평문으로 남는다 — Discord 웹훅과 같은 원칙("시크릿 값은 인프라와 생애주기가 다르다"). 주석에 apply 후 1회 실행할 `aws secretsmanager put-secret-value` PowerShell 명령이 그대로 있다. `recovery_window_in_days = 7`(삭제 유예), 값 미주입 시에도 **탐지는 정상 동작**하고 모든 알림에 "판정 없음"이 붙을 뿐이라는 점이 이 시스템의 의존성 방향(판정은 장식, 탐지가 본체)을 보여준다.

### L233–265 · resource "aws_dynamodb_table" "siem_alert_state"

중복 억제와 판정 호출 상한을 **한 테이블에서 키 접두사로** 겸한다: `<rule_id>#<alert_key>`(이미 알린 대상인가) / `judge-quota#<YYYY-MM-DD>`(오늘 판정 호출 횟수). `billing_mode = "PAY_PER_REQUEST"` — 시간당 수십 건 수준이라 프로비저닝이 낭비다. `hash_key = "alert_key"` 단일 키(정렬 키 불필요 — 조회가 항상 정확한 키 단위). `ttl`은 `expires_at` 속성으로 오래된 항목을 자동 청소하되, 주석의 함정이 중요하다: **TTL 삭제는 최대 48시간 지연될 수 있어 "항목이 남아 있다"만으로 억제 여부를 판단하면 안 된다** — Lambda가 `alerted_at` 비교를 조건식에 같이 걸어 처리한다(TTL은 청소용, 판정은 타임스탬프로). `point_in_time_recovery`는 명시적으로 꺼져 있고 이유가 인라인 주석에 있다: 이 상태는 유실돼도 알림이 한 번 더 오는 정도라 복구 대상이 아니다.

### L268–286 · resource "aws_iam_role" "siem_detector" + basic execution 연결

Lambda 실행 역할. 이름이 `${local.siem_name_prefix}-detector-lambda` = `gochuchamchi-siem-detector-lambda`인데, 헤더 주석이 강한 결합을 경고한다: **역할 이름이 `gochuchamchi-`로 시작해야** KMS 키 정책의 AllowProjectRoles(kms-logs.tf)에 걸려 로그 객체를 복호화할 수 있다. 이름을 바꾸면 Athena가 원본을 못 읽어 모든 룰이 실패한다 — IAM 정책(아래 kms:Decrypt)과 키 정책 양쪽이 다 열려야 KMS가 통하는 구조의 함정이다. `assume_role_policy`는 siem-alerts.tf에 정의된 공용 `siem_lambda_assume_role` 문서(lambda.amazonaws.com 신뢰)를 재사용한다. AWSLambdaBasicExecutionRole 관리형 정책으로 CloudWatch Logs 기록 권한을 붙인다.

### L288–427 · data "aws_iam_policy_document" "siem_detector" — 최소 권한 정책 10개 statement

Lambda가 하는 일 하나당 statement 하나로 대응되는, 이 파이프라인의 동작 명세서다.

- **RunDetectionQueries** (L290–308): Athena 실행 계열 + `GetNamedQuery`/`ListNamedQueries` 등 저장 쿼리 읽기. 인라인 주석이 구조를 설명한다 — 룰 SQL은 저장 쿼리에서 읽으므로 **Lambda 재배포 없이 룰을 고칠 수 있다**. 리소스는 워크그룹 ARN 하나로 한정.
- **ReadCatalogAndManageViews** (L313–334): Glue 읽기에 더해 Create/Update/DeleteTable이 있는 이유 — `CREATE OR REPLACE VIEW`는 Glue에 VIRTUAL_VIEW 테이블을 **쓰는** 동작이다(뷰 자동 재생성의 대가). 범위는 catalog/해당 database/그 밑 테이블로 제한.
- **ReadCentralLogs** (L337–351): 중앙 로그 버킷은 GetObject/ListBucket/GetBucketLocation **읽기 전용** — "쓰기 권한은 주지 않는다"가 소제목이다.
- **WriteQueryResults** (L354–370): Athena 결과 버킷에만 Put/AbortMultipartUpload 포함 쓰기 허용. 읽기 버킷과 쓰기 버킷을 분리해 침해 시 로그 원본 변조를 차단한다.
- **DecryptCentralLogs** (L373–378): 로그 KMS 키에 Decrypt/DescribeKey. 위 역할 이름 규칙과 함께 양방향 허용을 완성한다.
- **TrackAlertState** (L381–386): DynamoDB PutItem/UpdateItem/GetItem 세 개만 — Scan/Query가 없다(키 단위 접근만 하는 코드와 일치).
- **PublishAlerts** (L389–394): SNS 토픽 하나에 Publish.
- **ReadGroqApiKey** (L397–402): 해당 시크릿 하나에 GetSecretValue.
- **PublishDetectionMetrics** (L406–417): `cloudwatch:PutMetricData`는 리소스 단위 제한이 불가능한 API라 `resources=["*"]`가 불가피하고, 대신 `cloudwatch:namespace` StringEquals 조건으로 `Gochuchamchi/SIEM`에만 쓰게 좁힌다 — "*"를 조건으로 구제하는 표준 패턴이다.
- **DispatchResponseToWorkload** (L421–426, 2026-08-13 추가): 자동대응용 크로스계정 `events:PutEvents`. 대상을 Workload 계정의 default 이벤트 버스 **하나**로 좁혔다. 수신 측 버스의 리소스 정책(다른 루트에서 관리)이 함께 열려야 실제로 통한다.

### L429–433 · resource "aws_iam_role_policy" "siem_detector"

위 정책 문서를 인라인 정책으로 역할에 부착한다. 역할 전용 정책이라 관리형으로 만들 이유가 없다.

### L436–467 · locals — 지표 네임스페이스와 rules.json manifest

`siem_metric_namespace = "Gochuchamchi/SIEM"` — 지표·알람·IAM 조건이 공유하는 단일 문자열. `siem_rules_manifest`가 이 파일의 요체다: Lambda가 읽을 `rules.json`의 내용으로, `views`(매 실행 앞에서 재생성할 뷰 생성 named query ID 목록 — 조사용·탐지용 둘 다)와 `rules`(룰별 id/name/severity/title/why/always_alert/query_id)를 담는다. **manifest를 환경변수가 아니라 zip 안에 넣는 이유**(L436–446 주석): Lambda 환경변수는 전체 합계 4 KB 제한인데 룰의 why가 한글이라 UTF-8 3바이트/자다 — 룰이 몇 개만 늘어도 조용히 상한을 넘어 배포가 깨진다. 패키지 안에 두면 제약이 없고, 룰이 바뀌면 zip 해시가 바뀌어 Lambda가 자동 갱신된다. named query ID는 apply 시점에야 정해지므로 plan에서 archive가 "known after apply"로 남는 것이 정상이라는 각주도 있다.

### L469–494 · data "archive_file" "siem_detector" — 배포 패키지 (+ Lambda 코드의 역할 요약)

zip에 네 파일이 들어간다: `detector_function.py`(핸들러), `judge.py`(판정 모듈), `context.md`, `rules.json`(위 manifest의 jsonencode). `context.md`의 인라인 주석이 유지보수 전략을 선언한다: **판정 정확도의 대부분이 이 문서에서 나오며, 인프라가 바뀌면 룰이 아니라 이 문서를 고친다** — 인프라 지식(어떤 역할이 자동화인지, 어떤 트래픽이 정상인지)을 프롬프트 컨텍스트 문서로 외부화한 것이다.

Python 코드 자체는 이 문서의 해설 범위가 아니지만, Terraform 쪽 계약에서 흐름이 재구성된다: detector_function은 매 실행마다 ① rules.json의 `views` ID로 두 뷰의 CREATE OR REPLACE를 먼저 실행하고(스캔 0바이트), ② `rules`의 query_id로 룰 SQL을 읽어 워크그룹에서 실행·대기(쿼리당 상한 240초)하고, ③ 결과 행의 `alert_key`를 DynamoDB에서 `alerted_at` 조건식으로 검사해 dedup_hours 안에 알린 사건을 거르고, ④ 남은 후보가 있으면 judge.py가 일일 상한(`judge-quota#날짜`)을 확인한 뒤 Secrets Manager의 키로 Groq를 룰당 1회 호출한다 — 이때 계정 ID·내부 IP·이메일은 항상 마스킹되고, 룰의 why와 context.md가 프롬프트에 실린다. ⑤ 판정이 benign(확신도 ≥ 기준)이고 always_alert가 아니면 알림을 생략하고, 아니면 판정 요약을 붙여 SNS에 발행하며, urgent 조건이 맞고 RESPONSE_ENABLED면 Workload 버스로 PutEvents 한다. ⑥ 실행 내내 `RuleHits / JudgeVerdict / ScannedBytes / EstimatedCostUsd / DetectionRunSuccess` 지표(출력 L651–654의 description에 열거됨)를 네임스페이스에 찍는다.

### L497–562 · resource "aws_lambda_function" "siem_detector"

- `handler = "detector_function.lambda_handler"`, `runtime = "python3.12"`, `filename`/`source_code_hash`는 archive_file 산출물 — 해시가 바뀌면(코드든 rules.json이든) 자동 재배포된다.
- `timeout = 480`: 쿼리 대기(최대 240초)+판정(룰당 최대 20초) 합보다 넉넉하게. 줄이면 Lambda가 중간에 잘려 **지표도 알림도 남지 않는 가장 조용한 형태의 고장**이 된다는 인라인 경고가 값의 근거다. `memory_size = 256` — 표 몇십 행 처리라 최소급으로 충분.
- `reserved_concurrent_executions = 1`: 두 주기가 겹쳐 도는 것을 막는다. 겹치면 같은 후보를 두 번 판정해 호출 상한만 태운다. 동시성 1이 곧 분산 락 역할이다.
- `environment.variables`: 코드와 인프라의 전체 계약이 여기 있다. 배선 계열(ATHENA_WORKGROUP/DATABASE, ALERT_TOPIC_ARN, DEDUP_TABLE_NAME), 동작 파라미터(DEDUP_HOURS, LOOKBACK_MINUTES, MAX_ROWS_IN_ALERT, 하드코딩된 QUERY_TIMEOUT_SECONDS="240", METRIC_NAMESPACE), 판정 계열(JUDGE_ENABLED/DAILY_CALL_LIMIT/BENIGN_MIN_CONFIDENCE/STRICT_MASKING), 자동대응 계열(RESPONSE_ENABLED/EVENT_BUS_ARN/MIN_CONFIDENCE — 버스 ARN은 항상 넣되 스위치가 게이트), Groq 계열(SECRET_ARN/KEY, ENDPOINT, MODEL, TIMEOUT, MAX_ROWS, MAX_TOKENS, REASONING_EFFORT). 숫자·불리언은 전부 `tostring()` — Lambda 환경변수는 문자열만 허용된다.
- `depends_on`으로 로그 권한과 인라인 정책 부착을 명시 — 정책보다 함수가 먼저 떠 초기 실행이 권한 오류로 실패하는 레이스를 막는다.

### L564–571 · resource "aws_cloudwatch_log_group" "siem_detector"

로그 그룹을 **명시 생성**한다. Lambda가 암묵 생성하게 두면 보존기간이 "무기한"이라 요금이 계속 는다 — `retention_in_days = 30`으로 못 박는 표준 위생 패턴이다.

### L574–600 · 스케줄 — event rule / target / permission

`aws_cloudwatch_event_rule`이 `schedule_expression = var.siem_schedule_expression`, `state = var.siem_schedule_enabled ? "ENABLED" : "DISABLED"`로 변수 두 개를 그대로 반영하고, `aws_cloudwatch_event_target`이 룰과 Lambda를 잇고, `aws_lambda_permission`이 events.amazonaws.com 주체에게 이 룰 ARN(`source_arn`)에서만 InvokeFunction을 허용한다 — 다른 EventBridge 룰이 이 Lambda를 호출할 수 없게 하는 표준 3종 세트다.

### L603–634 · resource "aws_cloudwatch_metric_alarm" "siem_detector_not_running"

자기 감시의 핵심. `DetectionRunSuccess`(Sum)를 `period=3600`으로 보고 `evaluation_periods=2`, `threshold=1`, `LessThanThreshold` — 두 주기 연속 1이 안 찍히면 ALARM. 결정적 인자는 `treat_missing_data = "breaching"`이다: **지표가 없는 것이 바로 우리가 찾는 고장**(Lambda가 아예 안 돌았거나 중간에 죽음)이므로, 기본값(missing 무시)으로 두면 이 알람의 존재 의의가 사라진다. `alarm_description`에 트리아지 경로(Lambda 로그 그룹 경로, EventBridge 룰 상태 확인)를 박아 알림 자체가 런북이 되게 했다. `alarm_actions`와 `ok_actions` 모두 SIEM SNS 토픽 — 관제 공백의 시작과 끝을 다 통보한다. 룰 쿼리 실패에는 별도 알람이 없는데, Lambda가 직접 운영 알림을 발행하기 때문이다.

### L637–654 · outputs 3종

`siem_detector_function_name`(수동 실행 명령 예시 포함), `siem_groq_api_key_secret_name`(apply 후 키 주입 안내 — 없어도 탐지·알림은 동작), `siem_metric_namespace`(지표 5종 열거). 셋 다 description이 다음 행동을 지시하는 운영 문서다.

---

## log-archive/siem-alerts.tf (314줄)

탐지 결과가 사람에게 닿는 **알림 경로**다: SNS 토픽 하나를 팬아웃 지점으로 두고, 이메일 구독(코드 0줄로 확보되는 무의존 채널)과 Discord 렌더링 Lambda 구독을 단다. Discord 전달 실패는 SNS 재시도 → DLQ → DLQ 알람 → 같은 토픽 → 이메일로 되돌아오는 자기 감시 루프를 이룬다. SIEM 파일들이 공유하는 `siem_name_prefix`·`siem_tags` locals의 정의처이기도 하다.

### L1–23 · 파일 헤더 주석 — 왜 Log 계정 전용 경로인가

Workload 계정에 이미 있는 SNS 알림 허브를 재사용하지 않는 이유 두 가지: ① providers.tf의 전제("다른 계정에서 이 계정 관리자 역할을 AssumeRole하는 신뢰 경로를 만들지 않는다")의 연장으로, Log→Workload publish도 계정 경계를 넘는 상시 권한이고 **로그를 모아 두는 계정에서 밖으로 나가는 경로를 늘리는 건 이 계정의 존재 이유와 어긋난다.** ② 채널 오염 — Workload 허브에는 배포 알람·드리프트·GuardDuty가 흐르는데 상관 탐지 결과가 거기 묻히면 만든 의미가 없다(핸드오프 문서의 "보안 전용 채널 분리 권장" 인용). 대가는 Discord 렌더러가 두 벌이 되는 것인데, 받는 메시지 형식이 달라 공통화해도 분기만 는다는 판단이다. 자기 감시 루프의 종착점 경고도 여기 있다: **이메일 구독이 0개면 루프의 최종 수신자가 없다** — 최소 1개 주입 권장.

### L25–39 · variable "siem_alert_emails"

`default = []`. 개인 이메일을 코드에 하드코딩하지 않기 위해 환경변수(`$env:TF_VAR_siem_alert_emails = '["..."]'`)로 주입한다. apply 후 각 수신자가 확인 메일의 Confirm subscription을 눌러야 활성화되고 3일 내 미승인 시 만료된다는 SNS 이메일 구독의 운영 특성이 description에 있다. validation이 `alltrue([... can(regex(이메일 형식))])`로 전 항목을 검사한다.

### L42–51 · locals — SIEM 공통 이름·태그

`siem_name_prefix = "gochuchamchi-siem"` — 다섯 파일의 모든 리소스 이름이 여기서 파생된다(detector 역할 이름의 KMS 키 정책 결합도 이 접두사 덕에 성립). `siem_tags`는 log-archive 공통 태그에 `Component = "siem"`을 얹어, 비용·리소스 조회에서 SIEM 구성요소만 골라낼 수 있게 한다.

### L54–81 · resource "aws_secretsmanager_secret" "siem_discord_webhook"

Discord 웹훅 URL의 그릇. Groq 키와 같은 원칙(값은 tfstate에 남기지 않는다 — 과거 PAT 사고에서 학습한 "시크릿 값은 인프라와 생애주기가 다르다"를 인용)이고, 주입 명령이 주석에 있다. 값을 안 넣으면 Discord Lambda가 런타임에 실패 → SNS 재시도 → DLQ → 알람 → 이메일 — **"설정을 빠뜨린 것"조차 알림으로 돌아온다.** `recovery_window_in_days = 7`의 타협 논리가 구체적이다: 0이면 destroy 시 즉시 삭제돼 웹훅 값이 증발하고, 크면 같은 이름 재생성이 "삭제 예약됨" 오류로 막힌다.

### L84–121 · SNS 토픽 + 토픽 정책

`aws_sns_topic.siem_alerts` — 탐지 결과의 단일 팬아웃 지점. 토픽 정책 주석이 IAM 원리를 정확히 짚는다: detector Lambda의 발행은 **같은 계정이라 IAM 정책과 리소스 정책의 합집합**으로 허용되므로 토픽 정책에 넣을 필요가 없고, 여기서는 CloudWatch 알람만 열어 준다 — 알람은 서비스 주체(cloudwatch.amazonaws.com)로 발행하므로 리소스 정책이 필수다. `aws:SourceAccount` 조건으로 이 계정의 알람만 허용해 confused deputy(다른 계정 알람이 이 토픽으로 발행)를 막는다.

### L124–134 · resource "aws_sns_topic_subscription" "siem_email"

`for_each = toset(var.siem_alert_emails)`로 이메일별 구독을 만든다. 섹션 제목이 이 채널의 존재 이유다: "코드 0줄로 확보하는 채널이자 자기 감시 루프의 최종 수신자" — Lambda·시크릿·외부 서비스 어디에도 의존하지 않아, 다른 모든 것이 죽었을 때 남는 채널이다.

### L137–158 · Discord Lambda 패키지 + 공용 assume role 문서

`archive_file.siem_discord`가 `siem/discord_function.py` 한 파일을 zip으로 만들고, `data.aws_iam_policy_document.siem_lambda_assume_role`(lambda.amazonaws.com 신뢰)이 여기 정의돼 **detector의 역할(siem-detector.tf L278)도 이 문서를 재사용**한다 — 파일 간 참조 방향이 alerts→detector가 아니라 detector→alerts인 이유다.

### L160–185 · Discord Lambda의 역할·권한

역할 + AWSLambdaBasicExecutionRole + 웹훅 시크릿 **하나**에 대한 GetSecretValue 인라인 정책. 렌더러가 가진 권한의 전부다 — SNS가 밀어주는 이벤트를 받아 웹훅으로 POST만 하면 되므로 다른 권한이 없는 것이 정상이고, 침해돼도 할 수 있는 일이 웹훅 읽기뿐이다.

### L187–214 · resource "aws_lambda_function" "siem_discord"

discord_function.py의 역할: SNS 메시지(탐지 결과 JSON 또는 CloudWatch 알람 이벤트)를 받아 Discord 임베드로 렌더링해 웹훅으로 전송한다 — severity가 색과 아이콘을 정하고, 룰 결과 표에서 alert_key 컬럼은 빠진다(룰 파일 계약 ①). `timeout = 15`, `memory_size = 128` — HTTP POST 한 번이라 최소 사양. 환경변수는 시크릿 ARN과 JSON 키 이름 둘뿐이다. `depends_on`으로 권한 부착을 선행시킨다.

### L216–234 · SNS 구독 + redrive + Lambda 권한

`aws_sns_topic_subscription.siem_discord`가 토픽→Lambda를 잇고, `redrive_policy`로 DLQ를 지정한다 — SNS의 Lambda 전달 재시도(3회)까지 전부 실패한 메시지를 DLQ로 보낸다. 인라인 주석: **이게 없으면 Discord 장애 시 탐지 결과가 흔적 없이 사라진다.** `aws_lambda_permission`은 sns.amazonaws.com 주체를 이 토픽 ARN으로 한정해 InvokeFunction을 허용한다.

### L237–274 · DLQ + 큐 정책

`aws_sqs_queue.siem_alerts_dlq` — `message_retention_seconds = 1209600`(SQS 최대 14일): 원인 조사 시간을 벌기 위한 최대치다. 큐 정책은 sns.amazonaws.com의 SendMessage를 `aws:SourceArn = SIEM 토픽` 조건으로만 허용 — 이 토픽의 실패분만 들어올 수 있다.

### L276–299 · resource "aws_cloudwatch_metric_alarm" "siem_alerts_dlq_messages"

`AWS/SQS ApproximateNumberOfMessagesVisible`(해당 큐 dimension)을 Maximum/300초/1회 평가로 보고 1 이상이면 ALARM — DLQ에 뭐라도 쌓이면 즉시. detector 알람과 반대로 `treat_missing_data = "notBreaching"`인 이유가 대비된다: 메시지가 없으면 SQS는 지표 자체를 안 찍으므로 미수신=정상으로 읽어야 한다(detector 쪽은 미수신=고장). `alarm_description`이 트리아지 순서를 지시한다: 웹훅 시크릿 값 주입 여부 → Lambda 로그 → Discord 웹훅 상태. `alarm_actions`가 **같은 SIEM 토픽**이라 루프가 닫힌다 — Discord가 죽어 있어도 이메일 구독자에게는 SNS가 직접 전달한다.

### L302–314 · outputs 2종

`siem_alerts_topic_arn`, `siem_discord_webhook_secret_name`(apply 후 웹훅 주입 안내). 후자의 description 역시 "값을 넣어야 전달된다"는 다음 행동 지시다.

---

## log-archive/security-dashboard.tf (188줄)

CloudWatch 대시보드 한 장으로 "지금 뭔가 벌어지고 있나(is something happening?)"만 답하고, IP·URI·사용자 단위의 상세 조사는 Athena로 넘긴다는 역할 분담이 헤더에 명시된 파일이다(이 파일만 주석이 영어다). 지표는 대부분 Workload 계정 것을 **CloudWatch OAM(크로스계정 관측) 공유**로 당겨 온다 — 각 metric 정의의 `accountId = local.workload_account_id`가 그 표시이고, `depends_on`의 OAM sink 정책(다른 파일에서 관리)이 그 전제다. 위젯은 텍스트 2 + 지표 6 = 8개다.

### L1–6 · 파일 헤더 주석

대시보드의 계약: 개요는 여기, 조사는 Athena. 대시보드가 "로그 벽"이 되지 않게 한다는 절제 원칙이다.

### L8–169 · locals — 대시보드 이름과 위젯 8개

`security_dashboard_name = "gochuchamchi-security-overview"`. `security_dashboard_widgets`는 CloudWatch 대시보드 JSON의 widgets 배열을 HCL로 쓴 것이다 — 각 위젯의 `x/y/width/height`는 24칸 그리드 좌표이고, 이 파일은 위에서 아래로 트리아지 순서(엣지 차단 → 앱 실패 → 보안 이벤트 → 가용성 → 로그 배달 건전성)대로 배치했다.

- **위젯 1 — 제목 텍스트** (L13–21, 0,0 전폭×2): 대시보드 사용법 한 줄 — WAF 차단, 앱 실패, 보안 이벤트, 로그 배달 건전성을 순서대로 보고, 상세는 Athena로.
- **위젯 2 — 현재 보안 신호 singleValue** (L22–44, 전폭×4): 최근 1시간의 요약 숫자 6개를 `view="singleValue"`+`sparkline=true`로 보여준다. WAF `BlockedRequests`(WebACL=gochuchamchi-edge-waf, Rule=ALL)는 `region="us-east-1"` 오버라이드가 붙는데, CloudFront 스코프 WAF의 지표가 us-east-1에만 쌓이기 때문이다. 나머지 5개는 Workload의 커스텀 네임스페이스 `Gochuchamchi/ApplicationSecurity`의 Http4xxCount/Http5xxCount/LoginFailureCount/AccessDeniedCount/HighSecurityEventCount — 앱이 스스로 찍는 보안 지표다. `period=300`, `stat="Sum"`.
- **위젯 3 — WAF 룰별 차단 timeSeries** (L45–65, 좌반×6): 같은 BlockedRequests를 Rule 차원으로 쪼갠다 — ALL / rate-limit / sqli / known-bad-inputs. 위젯 전체 `region = "us-east-1"`. 어떤 룰이 막고 있는지가 공격 유형의 1차 분류가 된다.
- **위젯 4 — 앱까지 도달한 4xx/5xx** (L66–84, 우반×6): ALB 타깃 4xx/5xx는 `SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} :aws.AccountId=<workload> MetricName="..."', 'Sum', 300))` 식 SEARCH 표현식으로 집계한다. 차원값(LB/TG 이름)을 하드코딩하지 않는 것이 요점인데, 이 프로젝트는 런타임 루트가 ALB를 매일 daily-up/down으로 생성·파괴해 차원값이 계속 바뀌므로 이름 패턴 검색이 아니면 위젯이 금방 죽는다(코드에 사유 주석은 없으나 프로젝트 구조상 이것이 SEARCH를 쓴 이유로 보인다). `:aws.AccountId=` 필터가 OAM으로 섞여 들어온 여러 계정 지표 중 Workload 것만 고른다. 앱 자체 집계 4xx/5xx를 나란히 둬 "ALB가 본 것"과 "앱이 본 것"을 대조한다.
- **위젯 5 — 앱 인증·인가 이벤트 timeSeries** (L86–105, 좌반×6): LoginFailureCount/AccessDeniedCount/HighSecurityEventCount의 시계열 — 위젯 2의 숫자가 튀었을 때 언제부터였는지 보는 화면이다.
- **위젯 6 — 가용성·지연** (L106–126, 우반×6): SEARCH로 `UnHealthyHostCount`(Maximum)와 `TargetResponseTime`(p95, `yAxis="right"`)을 겹친다. 좌축 Targets/우축 Seconds로 라벨링(`yAxis` 블록, 둘 다 min 0) — 보안 대시보드에 가용성이 있는 이유는 공격의 최종 증상이 대개 가용성 저하로 나타나기 때문이다.
- **위젯 7 — 중앙 로그 배달 파이프라인 건전성** (L127–157, 전폭×6): `local.cloudwatch_log_delivery_sources`(다른 파일에 정의된 소스 집합)를 `sort(tolist(...))`로 순서 고정해 for 식으로 돌며, Firehose 스트림(`gochuchamchi-<source>-log-archive`)별 `DeliveryToS3.DataFreshness`(Maximum, 좌축)와 `ThrottledRecords`(Sum, 우축)를 나열한다. `annotations.horizontal`의 900초(15분) 빨간 기준선이 핵심이다 — freshness가 이 선을 넘으면 로그가 S3에 늦게 닿고 있다는 뜻이고, **이 위젯이 죽으면 위의 모든 탐지가 낡은 데이터를 보고 있는 것**이므로 SIEM 전체의 전제를 감시하는 위젯이다.
- **위젯 8 — 조사 안내 텍스트** (L158–167, 전폭×3): Athena 쿼리 에디터 콘솔 딥링크와 함께 저장 쿼리 09~16, 그중 시작점 3개(12-application-security-failures, 13-application-high-critical-events, 16-waf-allow-application-failure-correlation)를 지정한다. 대시보드에서 조사로 넘어가는 손잡이를 화면 안에 박아 둔 것이다.

### L171–183 · resource "aws_cloudwatch_dashboard" "security_overview"

`dashboard_body = jsonencode({...})`로 위 locals를 직렬화한다. `start = "-PT1H"` — 열면 기본 최근 1시간(위젯 2의 "last hour" 제목과 일치), `periodOverride = "inherit"` — 사용자가 기간을 바꿔도 위젯별 period 설정을 존중한다. `depends_on = [aws_oam_sink_policy.security_monitoring_seoul, ..._us_east_1]`이 실질적 의존이다: 크로스계정 지표는 OAM sink(서울 리전 + WAF용 us-east-1 두 개)가 먼저 서 있어야 흐르므로, 순서가 어긋나면 대시보드는 만들어지되 빈 그래프가 된다.

### L185–188 · output "security_dashboard_name"

대시보드 이름 출력 — 콘솔에서 찾아 들어가는 손잡이다.

---

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| security-events-view.tf | 445 | 9 (소스 분기 7종 소제목 포함) | 전체 — 변수 2, locals 3덩이, named query 2, output 3 |
| siem-detection-rules.tf | 698 | 13 (+룰 소제목 10) | 전체 — 변수 8, locals 공통 조각, 룰 10개 개별 해설, named query, output |
| siem-detector.tf | 654 | 28 | 전체 — 변수 15, 시크릿, DynamoDB, IAM(정책 statement 10), locals/manifest, 패키지+Lambda 코드 요약, Lambda, 로그 그룹, 스케줄 3종, 알람, output 3 |
| siem-alerts.tf | 314 | 13 | 전체 — 변수, locals, 시크릿, SNS+정책, 구독 2경로, Discord Lambda 일식, DLQ+정책, 알람, output 2 |
| security-dashboard.tf | 188 | 4 (+위젯 소제목 8) | 전체 — locals(위젯 8개 개별 해설), 대시보드 리소스, output |


---

# account-baseline — Workload 계정 상시 보안 베이스라인

account-baseline은 Workload 계정(828885965304)에 상주하는 **상시 보안 베이스라인 계층**이다. 이 프로젝트의 Workload 계정은 매일 daily-up/daily-down으로 VPC·EKS·RDS 같은 런타임 스택(terraform/ 루트)을 통째로 만들었다 부수는데, 이 루트의 34개 리소스는 그 파괴 주기에서 **의도적으로 제외**된다. providers.tf 상단 주석이 이 계층의 소속 기준을 한 문장으로 정리한다 — "지워도 돈이 안 아끼는데, 지우면 apply가 실패하는 것". 즉 (1) 계정·리전당 하나만 존재하는 싱글턴(GuardDuty detector, Config recorder, Security Hub, Inspector2 enabler, ECR 레지스트리 스캔 설정), (2) destroy가 실패하거나 느린 것(Inspector2의 5분 타임아웃 tainted 문제), (3) 재구축 자체가 비용인 것(Config는 apply 한 사이클에 구성 항목 수천 건을 기록), 그리고 전부 사용량 과금이라 유휴 비용이 사실상 0인 것들이다.

내용물은 크게 다섯 갈래다. **탐지·감사**(AWS Config 레코더 + 전용 S3 버킷, GuardDuty detector와 기능별 feature, Security Hub 표준 구독, IAM Access Analyzer), **계정 하드닝**(EBS 기본 암호화·스냅샷 공개 차단·S3 계정 퍼블릭 차단, MFA 강제 그룹, Region Guard Deny 정책), **접속 감사**(SSM Session Manager 전사 로깅 — 이 환경은 SSH 키페어가 어디에도 없어 이것이 유일한 접속 증적이다), **비용 방어**(Budgets 2단계 알림 + Cost Anomaly Detection), **크로스 계정 관측 연결**(CloudWatch OAM Link로 메트릭을 Log 계정 564186750363의 모니터링 계정으로 공유)이다. 참고로 CloudTrail이 이 루트에 없는 이유는 2026-08-10 조직 로그 분리 이후 Log 계정의 org trail이 이 계정 이벤트까지 기록하기 때문이다 — 여기 trail을 또 두면 두 번째 사본이라 과금만 는다.

전체 3계정 구조에서의 위치는 providers.tf 주석의 계층표 그대로다: management(조직·SCP·SSO) / log-archive(로그 중앙 수집, Log 계정) / persistent(ECR·서명 KMS·시크릿, Workload 계정 상시) / **account-baseline(여기, Workload 계정 상시)** / terraform(런타임, 일일 파괴). 참조 방향은 항상 terraform → account-baseline → (ARN 조립) → log-archive 한 방향이며, 역방향 참조를 만들지 않는 것이 규율이다 — 역방향이 생기면 일일 운영이 이 계층을 다시 건드리게 되어 분리한 의미가 사라진다. 한 가지 주의: GuardDuty finding의 **통보·자동대응 배선**(EventBridge → Discord/격리 Lambda)은 이 루트가 아니라 cloudwatch-notifications 루트에 있다. 여기는 detector를 켜는 쪽이다.

---

## account-baseline/account-guard.tf (10줄)

파일 전체가 리소스 하나짜리 **실행 계정 가드레일**이다. 이 프로젝트는 AWS 프로파일 3개(management/log/workload)를 오가며 작업하기 때문에, "잘못된 프로파일로 잘못된 루트를 apply하는" 사고가 구조적으로 가능하다. 이 파일은 그 사고를 plan 단계에서 즉사시키는 안전핀이다.

### L1–10 · resource "terraform_data" "account_guard"

`terraform_data`는 AWS에 아무것도 만들지 않는 Terraform 내장 더미 리소스다(옛 `null_resource`의 공식 후계). 실제 클라우드 리소스가 아니라 **lifecycle precondition을 걸 자리**로만 쓴다.

- `input = data.aws_caller_identity.current.account_id` — 현재 자격증명의 계정 ID를 리소스 입력으로 잡는다. input이 바뀌면 리소스가 교체되지만, 여기서 실질 역할은 precondition 평가를 위해 data 소스와의 의존을 만드는 것이다.
- `lifecycle.precondition` — `condition = data.aws_caller_identity.current.account_id == "828885965304"`. plan/apply 시점에 STS `GetCallerIdentity`로 확인한 계정이 Workload 계정이 아니면 여기서 즉시 실패한다. `error_message`가 한국어로 "account-baseline/은 Workload 계정 828885965304에서만 실행할 수 있습니다"라고 원인을 바로 알려준다.

함정·특이사항: backend.tf의 `profile = "workload-admin"`이 1차 방어지만, 프로파일 이름은 로컬 설정일 뿐이라 다른 계정을 가리키도록 잘못 구성될 수 있다. 이 가드는 **프로파일 이름이 아니라 실제 STS 응답**을 검사하므로 더 강한 2차 방어다. 같은 패턴이 다른 루트에도 있는데(각자 자기 계정 ID로), 루트마다 하드코딩된 계정 ID가 다르다는 점이 곧 "이 루트는 어느 계정 소속인가"의 선언이기도 하다.

---

## account-baseline/account-hardening.tf (46줄)

계정/리전 수준 하드닝 싱글턴 3종 — EBS 기본 암호화, EBS 스냅샷 공개 차단, S3 계정 퍼블릭 차단. 파일 머리 주석(2026-08-10 v8 병합)에 따르면 원래 main 브랜치의 terraform/ebs-encryption.tf와 terraform/s3.tf에 있던 것을 이 계층으로 이식했다. 이식 사유가 이 루트의 분류 기준을 그대로 보여준다: 셋 다 계정/리전 싱글턴이라 지워도 비용이 안 줄면서, 매일 destroy되는 계층에 있으면 "매일 껐다 켜는 무의미한 사이클"이 된다 — CloudTrail·GuardDuty와 같은 부류라는 판단이다.

### L21–23 · resource "aws_ebs_encryption_by_default" "this"

현재 리전(ap-northeast-2)에서 **새로 생성되는** EBS 볼륨과 스냅샷 복사본을 기본 암호화하는 리전 수준 스위치다.

- `enabled = true` — 인자는 이것 하나뿐이다. 별도 `aws_ebs_default_kms_key` 리소스를 만들지 않았으므로 AWS 관리형 기본 키(`alias/aws/ebs`)가 사용된다. 주석이 명시하듯 **기존** 볼륨·스냅샷의 암호화 상태는 소급 변경되지 않는다.

특이사항: EKS 노드의 루트 볼륨처럼 daily-up 때마다 새로 만들어지는 EBS가 전부 이 설정의 수혜자다. 런타임 스택 쪽에서 볼륨마다 `encrypted = true`를 깜빡해도 계정 레벨에서 잡아주는 seatbelt 역할이며, Security Hub FSBP의 EC2.7(EBS 기본 암호화 활성화 여부) 컨트롤을 PASS로 만드는 근거이기도 하다.

### L27–29 · resource "aws_ebs_snapshot_block_public_access" "this"

EBS 스냅샷의 **공개 공유**를 리전 수준에서 차단한다.

- `state = "block-all-sharing"` — 두 가지 모드 중 강한 쪽이다. `block-new-sharing`은 신규 공개만 막지만, `block-all-sharing`은 **기존에 이미 공개된 스냅샷까지** 접근을 차단한다. 특정 AWS 계정 대상의 비공개 공유는 계속 허용되므로 운영상 불편은 없다. 공개 스냅샷은 AMI/디스크에 박힌 시크릿 유출의 고전적 경로라, 쓸 일이 전혀 없는 이 프로젝트에서는 전면 차단이 당연한 선택이다.

### L41–46 · resource "aws_s3_account_public_access_block" "this"

버킷 단위가 아니라 **계정 단위** S3 퍼블릭 액세스 차단이다. 현재와 미래의 모든 버킷에, 전 리전에 걸쳐 적용된다.

- `block_public_acls = true` — 퍼블릭 ACL이 붙는 PutObject/PutBucketAcl 호출을 거부.
- `ignore_public_acls = true` — 이미 붙어 있는 퍼블릭 ACL을 무시(무효화).
- `block_public_policy = true` — 퍼블릭 접근을 허용하는 버킷 정책 부착을 거부.
- `restrict_public_buckets = true` — 퍼블릭 정책이 있는 버킷이라도 접근 주체를 해당 계정과 AWS 서비스로 제한.

주석의 설계 판단 두 가지가 중요하다. 첫째, 이미지 버킷은 CloudFront **OAC**(SourceArn 조건이 걸린 서비스 프린시펄) 정책이라 AWS가 "퍼블릭 정책"으로 분류하지 않는다 → 이 계정 차단과 충돌하지 않는다. 즉 "CloudFront를 통해서만 이미지 제공, S3 직접 접근 불가" 구조와 계정 전면 차단이 공존한다. 둘째, main 브랜치 시절 있던 depends_on(이미지 버킷 정책 선행)은 "퍼블릭 정책이 남아 있는 계정에서 차단을 켜는" 마이그레이션 순서 방어였는데, 매일 새로 짓는 현 구조에서는 불필요해 제거했다. 단 **최초 apply 시점**에는 구(舊) 퍼블릭 정책이 계정에 살아 있으면 안 된다 — 메인 스택이 v8 s3.tf(OAC 정책)로 apply된 뒤에 적용하라는 순서 조건이 주석으로 남아 있다.

---

## account-baseline/aws-config.tf (236줄)

AWS Config의 저장소(전용 S3 버킷 + 버킷 정책)와 본체(recorder/delivery channel 모듈 호출)를 담는 파일이다. 머리 주석이 역할을 CloudTrail과 대비해 정의한다 — CloudTrail이 "누가 무엇을 했는가"(API 호출 이력)를 남긴다면, AWS Config는 "리소스가 지금 어떤 상태이고 언제 어떻게 바뀌었는가"(구성 스냅샷·변경 이력)를 남긴다. Security Hub 보안 표준 대부분이 이 Config 기록을 근거로 평가하므로 security-hub.tf보다 먼저 적용되어야 한다(module.security_hub 쪽 depends_on이 이를 강제).

이 파일에서 가장 해설 가치가 높은 것은 **"왜 전용 버킷인가"**다. 2026-08-03의 실제 장애 기록: 원래는 중앙 로그 버킷에 prefix로 넣으려 했으나, 그 버킷의 불변성 통제(DenyObjectDeletion, DenyPolicyTampering, Object Lock COMPLIANCE)가 Config의 전달 검사(PutDeliveryChannel writability check)와 충돌해 `InsufficientDeliveryPolicyException`이 반복됐다. 역할 정책 ACL 조건 완화 → KMS 키 지정/권한 부여 → 버킷 정책에 Config 허용 3문구 추가까지 시도해도 해소되지 않았고, 통제를 더 열면 불변성 장치 자체가 약해지는 딜레마에 빠졌다. 결론은 **데이터 등급 분리**: CloudTrail/FlowLogs는 포렌식 증거(불변 보관 필수)지만 Config 이력은 재구성 가능한 구성 스냅샷이다. 등급이 다른 데이터를 같은 통제에 묶지 않고 버킷을 분리하는 것이 표준 구성으로의 회귀라고 판단했다. 주석 스스로 면접 포인트를 명시한다: "과도한 하드닝이 정당한 서비스 동작을 막는 것을 실제로 겪고, 데이터 등급별로 통제 수준을 분리했다".

### L25–27 · locals (aws_config_s3_key_prefix)

`aws_config_s3_key_prefix = "config"` 하나. 버킷 안 경로 접두사를 한 곳에서 정의해, 아래 버킷 정책의 PutObject resource 경로(L164)와 모듈 입력 `s3_key_prefix`(L198)가 반드시 같은 값을 쓰도록 묶는다. 두 곳이 어긋나면 Config의 전달 경로와 버킷 정책 허용 경로가 불일치해 전달이 거부되므로, 이 local이 그 어긋남을 원천 차단한다. 최종 저장 경로는 `s3://gochuchamchi-aws-config-<계정ID>/config/AWSLogs/<계정ID>/Config/`.

### L32–42 · resource "aws_s3_bucket" "aws_config"

Config 전용 버킷 본체다.

- `bucket = "gochuchamchi-aws-config-${data.aws_caller_identity.current.account_id}"` — S3 버킷명은 글로벌 유일해야 하므로 계정 ID를 접미사로 붙이는 표준 관례다.
- `force_destroy = true` — destroy 시 객체가 남아 있어도 버킷을 비우고 지운다. 구성 이력은 "재구성 가능한 데이터"라는 등급 판단이 여기서도 일관되게 적용된다(포렌식 등급인 로그 버킷이라면 절대 켜지 않을 옵션). 주석대로 destroy/apply 재구축 주기에 맞춘 자동 비우기다.
- `tags = merge(local.cloudwatch_log_archive_tags, {...})` — kms-logs.tf의 공통 태그(local)에 `Name`, `Component = "aws-config"`를 덧붙인다.

### L44–50 · resource "aws_s3_bucket_public_access_block" "aws_config"

버킷 4종 퍼블릭 차단 전부 true. account-hardening.tf의 계정 수준 차단이 이미 있지만, 버킷 레벨에도 명시하는 것은 (1) 계정 설정과 무관하게 버킷 단독으로도 안전하게 하는 심층 방어이고 (2) Security Hub S3 관련 컨트롤(S3.8 등)이 버킷 레벨 설정을 직접 검사하기 때문이다.

### L52–64 · resource "aws_s3_bucket_server_side_encryption_configuration" "aws_config"

버킷 기본 암호화를 SSE-KMS + 프로젝트 CMK로 강제한다.

- `sse_algorithm = "aws:kms"`, `kms_master_key_id = aws_kms_key.logs.arn` — "전 구간 CMK 원칙"에 따라 kms-logs.tf의 로그 CMK를 재사용한다. 주석이 근거를 짚는다: 그 키의 키 정책이 config 서비스(AllowConfigService)와 `gochuchamchi-*` 역할(AllowProjectRoles)을 이미 허용하고 있어 별도 키를 만들 필요가 없다.
- `bucket_key_enabled = true` — S3 Bucket Key. 객체마다 KMS API를 부르는 대신 버킷 수준 데이터 키를 재사용해 KMS 호출 비용을 크게 줄인다. Config처럼 객체를 잘게 자주 쓰는 워크로드에서 특히 효과적이다.

이 리소스는 모듈 호출부의 depends_on(L214)에 들어간다 — 암호화 설정이 잡히기 전에 delivery channel이 만들어지면 전달 테스트가 CMK 없이 진행되어 어긋날 수 있기 때문이다.

### L66–86 · resource "aws_s3_bucket_lifecycle_configuration" "aws_config"

보존 비용 관리 규칙 하나(`expire-config-history`, `status = "Enabled"`).

- `filter { prefix = "" }` — 버킷 전체 대상. provider v4+에서 filter 블록 자체는 필수라 빈 prefix로 전체를 지정한다.
- `transition { days = 30, storage_class = "STANDARD_IA" }` — 30일 지난 이력은 조회 빈도가 낮으니 Infrequent Access로 내려 저장 단가를 낮춘다.
- `expiration { days = 365 }` — 1년 후 완전 삭제. 로그 버킷과 달리 불변 보관 의무가 없는 데이터 등급이므로 만료가 허용된다.

### L90–179 · data "aws_iam_policy_document" "aws_config_bucket"

버킷 정책 본문. AWS 문서의 Config 표준 버킷 정책 3문 + TLS 강제 1문으로 구성되고, 주석이 강조하듯 중앙 로그 버킷에 있는 DenyObjectDeletion/DenyPolicyTampering을 **일부러 넣지 않는다**(분리 사유의 실천).

- **L91–112 `DenyInsecureTransport`** — `effect = "Deny"`, principal `*`, `actions = ["s3:*"]`, 버킷과 객체 전체 resource에 대해 `aws:SecureTransport = "false"` 조건. 평문 HTTP 접근 전면 거부다. Security Hub S3.5(SSL 요구) 컨트롤의 검사 항목이기도 하다.
- **L114–131 `AWSConfigBucketPermissionsCheck`** — `config.amazonaws.com` 서비스 프린시펄에 버킷 ARN 대상 `s3:GetBucketAcl` 허용. Config가 전달 채널을 설정·검증할 때 버킷 ACL을 확인하는 표준 절차다.
- **L133–150 `AWSConfigBucketExistenceCheck`** — 같은 프린시펄에 `s3:ListBucket` 허용. 버킷 존재/접근성 확인용.
- **L152–178 `AWSConfigBucketDelivery`** — 실제 기록 쓰기. `s3:PutObject`를 **정확한 경로**(`<버킷ARN>/config/AWSLogs/<계정ID>/Config/*`)로만 허용한다. 경로에 local과 계정 ID를 보간해 다른 경로로의 쓰기를 배제한다.
- 세 Allow문 모두 `condition { test = "StringEquals", variable = "aws:SourceAccount", values = [계정ID] }` — **confused deputy 방지**다. config.amazonaws.com은 모든 AWS 고객이 공유하는 서비스 프린시펄이므로, 이 조건이 없으면 타 계정의 Config가 이 버킷에 접근을 시도하는 경로가 이론상 열린다. SourceAccount 조건이 "우리 계정의 Config가 시킨 요청"만 통과시킨다.
- Delivery문의 두 번째 조건 `StringEqualsIfExists`/`s3:x-amz-acl = bucket-owner-full-control` — **IfExists가 핵심**이다. ACL 헤더가 오면 bucket-owner-full-control이어야 하고, 안 오면(ACL 비활성 버킷 대응) 그냥 통과. 왜 StringEquals가 아닌지는 모듈 쪽 s3_delivery 정책 주석(2026-08-03 장애)에 상세히 남아 있다 — 아래 module/aws-config/main.tf L64–121 해설 참조.

### L181–186 · resource "aws_s3_bucket_policy" "aws_config"

위 정책 문서를 버킷에 부착한다. `depends_on = [aws_s3_bucket_public_access_block.aws_config]` — 퍼블릭 액세스 블록과 버킷 정책을 동시에 적용하면 S3 API 쪽에서 경합(정책 평가 중 블록 설정 변경)으로 간헐 실패하는 알려진 문제가 있어, 블록을 먼저 확정시키는 순서 강제다.

### L191–216 · module "aws_config"

Config 본체(IAM 역할 + recorder + delivery channel)를 만드는 로컬 모듈 호출이다. `source = "./module/aws-config"`.

- `name_prefix = "gochuchamchi"` — 모듈이 만드는 역할/레코더/채널 이름의 접두사.
- `s3_bucket_name` / `s3_bucket_arn` — 위에서 만든 전용 버킷을 이름과 ARN 두 형태로 전달. 모듈 내부에서 이름은 delivery channel에, ARN은 IAM 정책 resource에 쓰이므로 둘 다 필요하다.
- `s3_key_prefix = local.aws_config_s3_key_prefix` — 버킷 정책의 허용 경로와 동일한 "config".
- `kms_key_arn = aws_kms_key.logs.arn` — 주석 그대로 "버킷이 이 CMK로 강제 암호화되므로 Config에도 알려주고 역할에 키 권한 부여". 모듈 내부에서 delivery channel의 `s3_kms_key_arn`과 역할의 KMS 사용 정책 두 군데에 쓰인다.
- `include_global_resource_types = true` — IAM User/Role/Policy 같은 **글로벌 리소스도 기록**. Security Hub의 IAM 관련 컨트롤(IAM.3 액세스 키 로테이션, IAM.21 와일드카드 정책 등)이 Config의 IAM 리소스 기록을 평가 근거로 요구하기 때문에 필수다.
- `snapshot_delivery_frequency = var.aws_config_snapshot_delivery_frequency` — 루트 변수(기본 Six_Hours)를 그대로 전달.
- `tags = local.cloudwatch_log_archive_tags` — 공통 태그 전파.
- `depends_on = [aws_s3_bucket_policy.aws_config, aws_s3_bucket_server_side_encryption_configuration.aws_config]` — 버킷 정책·암호화가 먼저 잡힌 뒤 delivery channel이 생성되어야 Config의 전달 테스트(PutObject)가 통과한다. 주석은 이것이 CloudTrail 버킷과 동일한 이유라고 적는다. 이 depends_on이 없으면 최초 apply에서 정책 부착 전에 채널 생성이 시도되어 InsufficientDeliveryPolicyException 재현 가능성이 있다.

### L223–226 · output "aws_config_recorder_name"

모듈 출력을 루트로 재노출. 검증 스크립트나 CLI(`aws configservice describe-configuration-recorder-status`)에서 레코더 이름을 바로 쓰기 위함이다.

### L228–231 · output "aws_config_role_arn"

Config가 assume하는 IAM Role ARN. 권한 문제 디버깅 시 출발점이 된다.

### L233–236 · output "aws_config_s3_location"

이력/스냅샷이 쌓이는 S3 기본 경로(`s3://.../config/AWSLogs/<계정ID>/Config/`). 모듈의 `s3_delivery_path` 출력을 그대로 통과시킨다.

---

## account-baseline/backend.tf (16줄)

이 루트의 state 저장 위치 선언이다. ../terraform, ../persistent와 동일 패턴이고 key만 다르다.

### L3–16 · terraform { backend "s3" }

- `bucket = "gochuchamchi-tfstate-828885965304"` — Workload 계정의 tfstate 전용 버킷. 계정 ID 접미사로 글로벌 유일성 확보.
- `key = "account-baseline/terraform.tfstate"` — 루트별로 key를 나눠 한 버킷에 여러 루트의 state를 공존시킨다. 루트 간 state 격리가 곧 blast radius 격리다.
- `region = "ap-northeast-2"`, `profile = "workload-admin"` — backend 블록은 변수를 쓸 수 없어(초기화가 변수 평가보다 먼저) 하드코딩이 불가피하다. 실행 계정 검증은 account-guard.tf가 보완한다.
- `encrypt = true` + `kms_key_id = "arn:aws:kms:...:alias/gochuchamchi-tfstate"` — 2026-08-13 주석이 함정을 기록한다: `encrypt = true`만 두면 Terraform이 **AES256을 명시적으로 보내** 버킷의 기본 암호화(SSE-KMS)를 요청 단위로 덮어쓴다. tfstate까지 CMK로 암호화하려면 kms_key_id를 backend에 직접 명시해야 한다(상세는 ../terraform/backend.tf 주석 참조).
- `use_lockfile = true` — Terraform 1.10+의 S3 네이티브 잠금. DynamoDB 잠금 테이블 없이 S3 조건부 쓰기(`.tflock` 객체)로 동시 apply를 막는다. 학생 프로젝트에서 DynamoDB 테이블 하나를 줄이는 실리적 선택이다.

---

## account-baseline/cloudwatch-monitoring-link.tf (72줄)

CloudWatch 크로스 계정 관측(Observability Access Manager, OAM)의 **Workload 쪽 절반**이다. Log 계정(564186750363)이 모니터링 계정으로서 sink를 열어두면, 소스 계정인 Workload가 link를 만들어 메트릭을 공유한다. 파일 머리 주석이 이 파일의 소속 근거를 밝힌다: OAM link는 계정 레벨·사실상 무비용 리소스라 daily teardown에서 살아남아야 하고, 원본 로그는 기존 Firehose/S3 아카이브 경로로 계속 흐른다(이 link는 메트릭 전용이다).

### L9–13 · provider "aws" (alias = "us_east_1")

`alias = "us_east_1"`, `region = "us-east-1"`, `profile = var.aws_profile`. OAM link는 리전 리소스인데 WAFv2 메트릭은 CloudFront에 붙은 WebACL이 **us-east-1**에 메트릭을 내므로, 그 리전에 link를 하나 더 만들기 위한 보조 프로바이더다. 프로파일은 동일하게 workload-admin — 리전만 다르고 계정은 같다.

### L15–27 · resource "aws_oam_link" "security_monitoring_seoul"

서울(기본 프로바이더) 리전의 link.

- `label_template = "$AccountName"` — 모니터링 계정 콘솔에서 이 소스 계정 데이터에 붙는 라벨. 계정 ID 대신 사람이 읽는 계정 이름으로 표시된다.
- `resource_types = ["AWS::CloudWatch::Metric"]` — **메트릭만** 공유. 로그 그룹(AWS::Logs::LogGroup)이나 X-Ray 트레이스는 공유하지 않는다 — 로그는 이미 Firehose/S3 경로로 중앙 수집 중이므로 이중 전송을 피한 것이다.
- `sink_identifier = var.log_archive_oam_sink_arn_seoul` — Log 계정 쪽 sink ARN. 루트 간 output 참조 대신 변수 주입인 이유는 "참조 방향은 한 방향" 원칙(providers.tf) 때문 — 다른 계정 state를 backend로 직접 읽지 않고 ARN을 손으로 조립·주입하고, 대신 아래 variable의 validation으로 형식을 강제한다.
- `link_configuration.metric_configuration.filter = "Namespace IN ('AWS/ApplicationELB', 'Gochuchamchi/ApplicationSecurity')"` — 공유 네임스페이스 화이트리스트. ALB 표준 메트릭과 애플리케이션 보안 커스텀 메트릭만 넘긴다. 전 네임스페이스 공유는 노이즈와 (초과분) 비용을 늘리므로 보안 모니터링에 필요한 것만 고른 것이다.
- `tags = local.security_monitoring_link_tags`.

### L29–43 · resource "aws_oam_link" "security_monitoring_us_east_1"

- `provider = aws.us_east_1` — 위 alias 프로바이더로 us-east-1에 생성.
- filter가 `"Namespace = 'AWS/WAFV2'"` — CloudFront 연동 WAF의 메트릭(차단/허용 요청 수 등)이 us-east-1에만 존재하므로, 이 리전 link는 WAFV2 하나만 공유한다. 서울 link와 sink도 다르다(`var.log_archive_oam_sink_arn_us_east_1`) — OAM sink 자체가 리전 리소스라 Log 계정도 리전마다 sink를 하나씩 두기 때문이다.
- 나머지 인자(`label_template`, `resource_types`, tags)는 서울 link와 동일.

### L45–52 · locals (security_monitoring_link_tags)

두 link가 공유하는 태그 맵(Project/Environment/ManagedBy/`Component = "security-monitoring-link"`). kms-logs.tf의 공통 태그와 별개로 정의한 것은 Component 값으로 리소스 군을 식별하기 위함이다.

### L54–62 · variable "log_archive_oam_sink_arn_seoul"

- `type = string`, 기본값 없음 — apply 시 주입 필수.
- `validation`: `can(regex("^arn:aws:oam:ap-northeast-2:564186750363:sink/", ...))` — **리전과 계정 ID까지 정규식에 박아** 검증한다. 엉뚱한 계정이나 리전의 sink ARN을 넣으면 plan에서 "The Seoul OAM sink must belong to Log account 564186750363 in ap-northeast-2."로 실패한다. 크로스 계정 값을 변수로 받는 루트에서 오입력을 막는 이 프로젝트의 반복 패턴이다.

### L64–72 · variable "log_archive_oam_sink_arn_us_east_1"

같은 구조로 `^arn:aws:oam:us-east-1:564186750363:sink/`를 강제한다. 리전별 변수를 둘로 나눠 서울 sink를 us-east-1 link에 잘못 꽂는 실수까지 타입 수준에서 차단한다.

---

## account-baseline/cost-monitoring.tf (101줄)

학생 팀 프로젝트에서 사실상 가장 중요한 방어선인 **비용 모니터링** 2종이다. 머리 주석의 구도: (1) AWS Budgets — 월 예산 대비 실사용 80% 도달/월말 예측 100% 초과 시 이메일(예산 2개까지 무료, 여기는 1개만 사용), (2) Cost Anomaly Detection — "평소 패턴 대비 갑자기 튀는 지출"을 ML로 감지(무료). 예산은 총액 기준이라 느리게 반응하지만 이상 감지는 특정 서비스 급증(NAT 처리량 폭증, 실수로 켜둔 리소스)을 바로 잡는다는 상호보완 관계다. Budgets/Cost Explorer는 글로벌 서비스(us-east-1 엔드포인트)지만 프로바이더가 알아서 처리하므로 별도 alias가 필요 없다는 주석도 있다.

### L18–27 · variable "cost_alert_email"

- `type = string`, **default 없음** — "하드코딩 금지 원칙(2026-08-04)"에 따라 개인 이메일을 코드/커밋 이력에 남기지 않기 위해 `$env:TF_VAR_cost_alert_email` 환경변수 주입을 강제한다. 이 루트에서 default 없는 변수는 이것과 OAM sink ARN들뿐이다.
- `validation`: 이메일 형식 정규식(`^[^@\s]+@[^@\s]+\.[^@\s]+$`). 오타 이메일로 알림이 증발하는 사고를 plan 단계에서 잡는다.

### L29–33 · variable "monthly_budget_usd"

`default = "350"` (USD). Budgets API가 금액을 문자열로 받으므로 `type = string`이다. 설명이 성격을 정확히 짚는다 — 이 값은 지출 상한이 아니라 **알림 기준**이다(AWS Budgets는 지출을 막지 못한다). "풀 구성 실측 후 조정할 것"이라는 운영 메모 포함.

### L38–62 · resource "aws_budgets_budget" "monthly"

- `name = "gochuchamchi-monthly"`, `budget_type = "COST"`(비용 기준; USAGE 등 다른 타입도 있다), `limit_amount = var.monthly_budget_usd`, `limit_unit = "USD"`, `time_unit = "MONTHLY"`(매월 리셋).
- 첫 번째 `notification` (L46–52): `notification_type = "ACTUAL"`, `threshold = 80`, `threshold_type = "PERCENTAGE"`, `comparison_operator = "GREATER_THAN"` — **이미 쓴 돈**이 예산의 80%($280)를 넘으면 이메일. 주석 표현으로 "확정 신호"다.
- 두 번째 `notification` (L55–61): `notification_type = "FORECASTED"`, `threshold = 100` — AWS가 이번 달 지출 추세로 계산한 **월말 예측치**가 예산 100%를 넘으면 이메일. 주석대로 "미리 경고 — 실질적으로 더 유용"하다. 월초에 비싼 리소스를 켜두면 실사용 80%보다 예측 100%가 훨씬 먼저 발화한다.
- 두 notification 모두 `subscriber_email_addresses = [var.cost_alert_email]`.

### L67–71 · resource "aws_ce_anomaly_monitor" "services"

- `monitor_type = "DIMENSIONAL"` + `monitor_dimension = "SERVICE"` — AWS 관리 차원(서비스) 기준 모니터. 주석대로 **서비스별로 각각 지출 베이스라인을 학습**해서, 총액은 정상 범위여도 특정 서비스 하나가 급증하면 이상으로 판정한다. 커스텀 Cost Category 기반(CUSTOM) 대신 가장 단순하고 무료인 구성이다.

### L73–96 · resource "aws_ce_anomaly_subscription" "email"

이상 감지 결과를 받아볼 구독이다.

- `frequency = "DAILY"` — 여기 붙은 주석이 실측 기록이다: AWS 제약상 IMMEDIATE는 **SNSTopic 구독자만** 지원하고, EMAIL 구독자는 DAILY/WEEKLY만 가능하다. IMMEDIATE + EMAIL 조합은 CreateAnomalySubscription이 400으로 거부한다("Immediate frequencies only support SNSTopic subscriptions", 2026-08-04 확인). 즉시 알림이 필요해지면 SNS 토픽을 만들어 subscriber를 SNS로 바꾸라는 이관 경로까지 남겼다.
- `monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]` — 위 모니터에 연결.
- `subscriber { type = "EMAIL", address = var.cost_alert_email }`.
- `threshold_expression` (L89–95): `ANOMALY_TOTAL_IMPACT_ABSOLUTE`가 `GREATER_THAN_OR_EQUAL` `"5"` — 이상 지출의 **예상 초과 금액이 $5 이상**일 때만 알림. 소액 흔들림까지 매일 메일로 오면 알림 피로로 진짜 경보를 놓치게 되므로 노이즈 컷을 건 것이다.

### L98–101 · output "budget_name"

생성된 예산 이름. Billing 콘솔 → Budgets에서 눈으로 확인할 때의 검색 키다.

---

## account-baseline/ecr-scanning.tf (36줄)

ECR 이미지 취약점 스캔의 **계정 단위 설정** 2종이다. 머리 주석의 소속 정리가 명확하다: 저장소 실체와 CI push 권한은 ../persistent가 갖고, 여기 둘은 "계정에 하나만 존재하는 스캔 설정"이라 baseline 소속이다. 특히 `aws_inspector2_enabler`는 destroy가 프로바이더 기본 5분 타임아웃을 넘겨 실패하고 state에 tainted로 남아 다음 apply가 비활성화→재생성을 반복하는 문제(8/4 §5.2)가 있었다 — **일일 destroy 경로에서 빼내는 것**이 baseline으로 옮긴 첫 번째 이유라고 주석이 못 박는다. 이 파일이 이 루트의 존재 이유를 가장 잘 보여주는 사례다.

### L12–21 · resource "aws_inspector2_enabler" "this"

Amazon Inspector v2(취약점 스캔 서비스)를 계정에 활성화한다.

- `account_ids = [data.aws_caller_identity.current.account_id]` — 자기 계정만. Organizations 위임 관리 구성이라면 멤버 계정 목록이 오는 자리다.
- `resource_types = ["ECR", "EC2"]` — ECR 이미지 스캔과 EC2 인스턴스(EKS 노드 포함) 스캔을 켠다. LAMBDA는 제외 — 이 프로젝트에 상시 Lambda 워크로드 스캔 수요가 없다.
- `timeouts { create/update/delete = "15m" }` — 위 8/4 장애의 직접 처방. 기본 5분으로는 Inspector 비활성화가 제시간에 안 끝나 tainted가 남았으므로 세 방향 모두 15분으로 늘렸다. baseline 이관(운영적 회피)과 타임아웃 연장(기술적 해결)의 이중 방어다.

### L24–36 · resource "aws_ecr_registry_scanning_configuration" "this"

레지스트리(계정의 ECR 전체) 스캔 설정을 Inspector 기반으로 승격한다.

- `scan_type = "ENHANCED"` — BASIC(무료 Clair 기반, push 시 1회)이 아니라 Inspector 연동 ENHANCED. OS 패키지에 더해 언어 패키지(Java/Python/Node 의존성)까지 보고, 새 CVE 공개 시 **기존 이미지 재평가**(continuous scanning)가 된다.
- `rule { scan_frequency = "SCAN_ON_PUSH", repository_filter { filter = "*", filter_type = "WILDCARD" } }` — 모든 저장소에 push 시 스캔. CONTINUOUS_SCAN 대신 SCAN_ON_PUSH를 고른 것은 비용 절제다(ENHANCED에서는 push 스캔만으로도 신규 CVE 재평가가 일정 기간 제공된다).
- `depends_on = [aws_inspector2_enabler.this]` — ENHANCED는 Inspector가 켜져 있어야 설정 가능하므로 명시적 순서 강제. 스캔 결과는 Inspector → Security Hub 연동으로 Security Hub 콘솔에도 모인다.

---

## account-baseline/guardduty.tf (88줄)

계정 레벨 **위협 탐지** 계층이다. 머리 주석의 맥락: CloudTrail(기록)·AWS Config(구성 감사)·Security Hub(점검)는 있었는데 이상 행위를 **능동 탐지**하는 계층만 비어 있어 2026-08-04 백로그 B6로 도입했고, 8/3 full-HA 브랜치의 기능 확장을 병합했다. 활성화하면 Security Hub와 자동 연동되어 finding이 Security Hub 콘솔로도 흘러 들어간다(별도 subscription 불필요). 탐지 소스별 의미도 주석에 정리돼 있다 — CloudTrail 관리 이벤트(탈취 키의 타 리전 인스턴스 생성 시도: Region Guard가 막고 GuardDuty가 시도를 탐지하는 **이중 구조**), VPC Flow Logs/DNS 로그(포트 스캔, C2 통신, 코인 채굴 도메인 조회 — GuardDuty는 flow-logs.tf와 무관하게 자체 수집분을 보며, S3 저장분은 finding 후 Athena 원본 추적용), EKS 감사 로그(익명 접근, 특권 파드, kube-system 침투). 비용은 30일 무료 후 이 규모(노드 2대)면 월 $1~5 수준. 다시 강조하면 finding의 통보·자동대응은 cloudwatch-notifications 루트 담당이고, 여기는 detector와 feature를 켜는 쪽이다.

### L24–29 · resource "aws_guardduty_detector" "this"

리전당 하나뿐인 GuardDuty detector.

- `enable = true`.
- `finding_publishing_frequency = "FIFTEEN_MINUTES"` — **기존(업데이트된) finding**을 EventBridge로 내보내는 주기를 기본 6시간에서 최소값 15분으로 당겼다. cloudwatch-notifications의 자동대응(격리 Lambda)이 EventBridge 이벤트를 입력으로 받으므로, 이 값이 곧 대응 지연의 상한이다. 신규 finding은 주기와 무관하게 약 5분 내 전달되지만, 재발 finding까지 빨리 받으려면 이 설정이 필요하다.

### L36–40 · resource "aws_guardduty_detector_feature" "eks_audit_logs"

`detector_id = aws_guardduty_detector.this.id`, `name = "EKS_AUDIT_LOGS"`, `status = "ENABLED"`. 프로바이더 v6 방식(구 `datasources` 블록 대신 feature 리소스 분리)의 첫 번째다. EKS 감사 로그 분석 — 클러스터 침투 탐지의 핵심이다. 주석의 포인트: main.tf(런타임 스택)에서 control plane audit 로그가 켜져 있지만, GuardDuty는 CloudWatch를 거치지 않고 **EKS에서 직접 스트림을 받아** 분석하므로 추가 로그 비용이 없다.

### L44–48 · resource "aws_guardduty_detector_feature" "s3_data_events"

`name = "S3_DATA_EVENTS"`. 이미지 버킷/로그 버킷에 대한 비정상 접근(대량 다운로드, 퍼블릭화 시도) 탐지. CloudTrail S3 데이터 이벤트를 따로 켜면 과금이 상당한데, GuardDuty의 이 feature는 데이터 이벤트를 별도로 켜지 않아도 동작한다는 것이 채택 이유다.

### L52–56 · resource "aws_guardduty_detector_feature" "ebs_malware"

`name = "EBS_MALWARE_PROTECTION"`. 다른 finding이 떴을 때 해당 인스턴스의 EBS 스냅샷을 떠서 말웨어를 검사하는 **사후 트리거형** 기능이다. 상시 과금이 아니라 스캔 발생 시 GB당 과금이라 켜두는 비용 부담이 없다.

### L72–83 · resource "aws_guardduty_detector_feature" "runtime_monitoring"

- `count = var.enable_guardduty_runtime_monitoring ? 1 : 0` — 유일하게 **변수로 게이트된 feature**, 기본 OFF. 노드에 GuardDuty 에이전트(DaemonSet)를 깔아 프로세스/네트워크 시스콜 수준까지 탐지하는데, t3.small 2대에는 파드당 ~64Mi+의 메모리 부담이 있어 꺼둔 것이다.
- `additional_configuration { name = "EKS_ADDON_MANAGEMENT", status = "ENABLED" }` — 켜는 경우 GuardDuty가 에이전트 애드온을 직접 설치·관리하게 한다(수동 Helm 설치 불필요).
- 2026-08-13 주석이 자동대응 연동 설계를 상세히 기록한다: 켜면 파드/컨테이너 수준 런타임 finding이 추가되고 그 finding은 `kubernetesWorkloadDetails`(네임스페이스/파드)를 담는다. 대응 경로는 severity 기반(guardduty_isolate_min_severity=7)이라 **별도 배선 없이** 격리 Lambda로 흐르고, EC2·키 대상이 아닌 파드 finding은 cloudwatch-notifications/isolation_function.py의 `isolate_pod`(deny-all NetworkPolicy)로 처리된다. 즉 이 스위치가 "#5 파드 격리 대응"의 **주 입력원**이다 — 켜야 그 경로가 실제로 도는 finding을 받는다. EKS_AUDIT_LOGS도 kube API 이상 finding을 일부 내지만, 역쉘·크립토마이너 같은 런타임 침해는 이 에이전트라야 잡는다. 켤 때는 노드 메모리를 확인하고, 파드 격리 실행은 여전히 workload 쪽 `pod_response_enabled`가 게이트한다는 운영 조건까지 명시돼 있다.

### L85–88 · output "guardduty_detector_id"

detector ID. description에 검증 명령(`aws guardduty list-findings --detector-id <이 값>`)을 박아 output 자체가 런북 역할을 한다.

---

## account-baseline/iam-security.tf (174줄)

IAM 보안 잔여 항목(격차분석 §2.9, 계획 D03~D04) 3종 — Access Analyzer, MFA 강제 그룹, Region Guard. 이 파일 머리 주석의 ⚠️⚠️ 경고가 이 루트 전체에서 가장 무거운 운영 교훈이다: **그룹 멤버십의 기본값은 "비어 있음"이고, 반드시 비워둔 채 유지 조건을 이해하고 넣어야 한다.** 07/29에 Terraform 작업 계정이 explicit deny 그룹(3pro)에 들어가 있어 `terraform plan` 전체가 AccessDenied로 마비된 실제 사고가 있었다(docs/architecture.md §4.2). 이 그룹의 두 정책 모두 explicit Deny를 포함하므로 — MFA 강제: CLI 액세스 키는 MFA 세션이 아니라서 Terraform 실행 계정을 넣는 순간 모든 apply가 죽는다("콘솔 전용 사용자"만 넣을 것). Region Guard: `var.allowed_regions` 밖 리전 작업이 전부 막힌다.

### L24–32 · resource "aws_accessanalyzer_analyzer" "account"

- `analyzer_name = "gochuchamchi-account-analyzer"`, `type = "ACCOUNT"` — 계정 범위 분석기(Organizations 범위가 아님 — 이 루트는 단일 계정 관할이다). 계정 **밖**(외부 주체)에서 접근 가능한 리소스 정책 — S3 버킷 정책, KMS 키 정책, IAM 역할 신뢰 정책 등 — 을 상시 분석한다.
- 주석의 운영 노트: 이미지 버킷의 public read는 **의도적 유지 항목**이라 finding이 하나 뜨는 것이 정상이며, 콘솔에서 archive 처리하고 사유를 남기라고 안내한다. "finding 0건"이 아니라 "설명 가능한 finding만 존재"가 목표 상태라는 성숙한 기준이다.

### L37–39 · resource "aws_iam_group" "console_admins"

`name = "gochuchamchi-console-admins"`. 콘솔 로그인 사용자용 관리자 그룹의 껍데기. 정책 부착과 멤버십은 아래 리소스들이 나눠 맡는다.

### L43–98 · resource "aws_iam_group_policy" "force_mfa"

그룹 인라인 정책 `force-mfa`. AWS 표준 self-service MFA 강제 패턴이다 — MFA 없이 로그인하면 "자기 MFA 등록"에 필요한 액션만 허용하고 나머지는 전부 거부해, 사용자가 스스로 MFA를 켜기 전엔 아무것도 못 하게 만든다. `jsonencode`로 3문 구성:

- **`AllowViewAccountInfo`** (L50–58): `iam:GetAccountPasswordPolicy`, `iam:ListVirtualMFADevices`를 `Resource = "*"`로 허용. MFA 등록 화면 렌더링에 필요한 최소 조회다.
- **`AllowManageOwnMFA`** (L59–75): `iam:CreateVirtualMFADevice`/`DeleteVirtualMFADevice`/`EnableMFADevice`/`ResyncMFADevice`/`ListMFADevices`/`GetUser`/`ChangePassword`를 **자기 자신에게만** 허용. Resource가 `arn:aws:iam::<계정>:mfa/$${aws:username}`과 `user/$${aws:username}` — Terraform에서 `$${...}`는 보간 이스케이프로, 최종 JSON에는 IAM 정책 변수 `${aws:username}`이 그대로 남아 "요청자 본인" 리소스로 평가된다. 남의 MFA를 만지는 것은 불가능하다.
- **`DenyAllExceptListedIfNoMFA`** (L76–95): 핵심 잠금. `Effect = "Deny"` + `NotAction`(MFA 등록·동기화·비밀번호 변경·`sts:GetSessionToken` 등 부트스트랩 액션 목록) + `Resource = "*"`, 조건 `BoolIfExists: aws:MultiFactorAuthPresent = "false"`. 즉 MFA 세션이 아니면 목록 밖 전 액션 거부다. `BoolIfExists`인 이유: 키가 아예 없는 요청(일부 서비스 경유 호출 등)도 "false 취급"해 거부에 포함시키기 위해서다. 그리고 이것이 바로 위 경고의 근원이다 — **CLI 액세스 키 요청에는 MultiFactorAuthPresent가 없으므로** 이 Deny에 걸리고, explicit Deny는 AdministratorAccess로도 못 뚫는다.

### L100–103 · resource "aws_iam_group_policy_attachment" "console_admins_admin"

그룹에 AWS 관리형 `arn:aws:iam::aws:policy/AdministratorAccess` 부착. 위 force_mfa와 합치면 "MFA 켜기 전엔 아무것도 못 하고, 켜면 관리자"가 된다. Deny는 Allow보다 항상 우선하므로 두 정책의 공존이 안전하게 성립한다.

### L106–112 · resource "aws_iam_group_membership" "console_admins"

- `count = length(var.console_admin_users) > 0 ? 1 : 0` — 기본 `[]`이면 멤버십 리소스 자체가 생성되지 않는다. 그룹·정책(구조)과 멤버십(운영 판단)을 분리해, 사람을 넣는 행위를 명시적 변수 주입으로만 가능하게 한 것이다. 주석이 다시 경고한다 — Terraform 실행 계정을 절대 넣지 말 것.
- `name`은 멤버십 리소스 식별용, `users = var.console_admin_users`.

### L121–151 · resource "aws_iam_policy" "region_guard"

허용 리전 밖 API 호출을 막는 고객 관리형 정책 `gochuchamchi-region-guard`. 단일 계정 시절 설계라 Organizations SCP를 못 쓰고 IAM explicit Deny로 대신한 것이다(3계정 전환 후에도 Workload 계정 내부 심층 방어로 유지).

- 단일문 `DenyOutsideAllowedRegions`: `Effect = "Deny"`, `Resource = "*"`, 조건 `StringNotEquals: aws:RequestedRegion = var.allowed_regions`(서울+도쿄DR) — 허용 목록 밖 리전으로 향하는 요청 전부 거부.
- `NotAction` 예외 목록이 실무 핵심이다: `iam:*`, `sts:*`, `s3:*`, `route53:*`, `cloudfront:*`, `wafv2:*`, `acm:*`, `support:*`, `health:*`, `budgets:*`, `ce:*` — 글로벌 서비스는 RequestedRegion이 us-east-1 등으로 잡혀 오탐 차단되기 때문에 빼야 한다. 주석이 구체적 실패 모드를 적어뒀다: 특히 acm/cloudfront/wafv2를 빼지 않으면 **us-east-1 인증서 발급(edge.tf)이 막혀 D13(엣지 구성)이 통째로 멈춘다**(격차분석 §2.1 경고 그대로).

### L156–159 · resource "aws_iam_group_policy_attachment" "console_admins_region_guard"

Region Guard를 **그룹에만** 부착한다. L153–155 주석이 이유를 못 박는다: Terraform 실행 계정에 직접 붙이고 싶으면 허용 리전 목록의 충분성(도쿄 DR, us-east-1 글로벌 예외)을 확인한 뒤 **콘솔에서 수동으로** 붙일 것 — 코드로 실행 계정에 Deny를 붙였다가 잘못되면 **그 Deny를 풀 apply조차 못 돌린다**. 자기 발등을 찍으면 회복 경로까지 막히는 self-lockout을 코드 경계 밖으로 밀어낸 설계다.

### L166–169 · output "access_analyzer_arn"

Access Analyzer ARN 노출. 검증 스크립트에서 finding 조회 시 사용한다.

### L171–174 · output "region_guard_policy_arn"

Region Guard 정책 ARN. 콘솔에서 다른 주체에 수동 부착할 때 복사해 갈 값이다.

---

## account-baseline/kms-logs.tf (117줄)

Config 버킷 전용 CMK다. 머리 주석이 축소의 역사를 기록한다: 원래 이 키는 중앙 로그 버킷(CloudTrail/Firehose/Flow Logs) 겸용이었으나, 2026-08-10 조직 로그 분리로 로그 저장·분석 전체가 Log 계정(../log-archive, 564186750363)으로 이관되면서 이 계정에 남은 용도는 aws-config.tf의 Config 버킷 암호화뿐이다. CloudTrail도 이 계정에는 없다(로그 계정 org trail이 조직 전체 기록). 용도별 키 2개 분리 원칙은 유지된다 — logs: Config 버킷 전용(이 파일) / data: RDS·EFS 등 워크로드 데이터(../terraform/kms.tf). 로그 계정에는 별도의 logs 키가 따로 있다(log-archive/kms-logs.tf).

### L15–23 · locals (cloudwatch_log_archive_tags)

공통 태그 맵(Project/Environment/ManagedBy/`Component = "central-log-archive"`). aws-config.tf가 버킷·모듈 태그로 함께 쓴다. Component 값이 현재 용도(Config 전용)와 어긋나 보이는데, 주석이 "이름은 이관 전 관례 유지"라고 명시한다 — 이름을 바꾸면 태그 변경 diff가 나므로 관례를 유지한 실용적 선택이다.

### L25–36 · resource "aws_kms_key" "logs"

- `description = "gochuchamchi AWS Config 버킷 암호화"` — 축소된 현재 용도를 정확히 반영.
- `enable_key_rotation = true` — 연 1회 자동 백킹 키 로테이션. Security Hub KMS.4 컨트롤의 검사 항목이다.
- `deletion_window_in_days = 7` — 삭제 예약 대기 기간 최소값. 주석대로 실습 환경이라 7일, 운영 전환 시 30일 권장. 짧을수록 실수 삭제의 복구 창이 좁아지는 대신 재구축 사이클이 빨라진다.
- `policy = data.aws_iam_policy_document.kms_logs.json` — 아래 키 정책 문서 부착.
- tags는 공통 태그 + `Name = "gochuchamchi-logs-cmk"`.

### L38–41 · resource "aws_kms_alias" "logs"

`alias/gochuchamchi-logs` → 키 ID 연결. ARN 대신 사람이 기억 가능한 이름으로 키를 참조·검색하게 해 주고, 키를 재생성해도 alias만 재연결하면 참조가 유지된다.

### L43–107 · data "aws_iam_policy_document" "kms_logs"

키 정책 3문.

- **L46–57 `EnableIAMPolicies`** — 계정 루트(`arn:aws:iam::<계정>:root`)에 `kms:*` 허용. KMS 키 정책의 표준 첫 문장으로, 이것이 있어야 계정의 IAM 정책 기반 접근(관리자, 조회 등)이 유효해진다. 주석 경고대로 이 문구가 없으면 키가 아무도 관리 못 하는 "관리 불가" 상태가 될 수 있다(그 경우 AWS Support 티켓으로만 복구).
- **L60–80 `AllowConfigService`** — `config.amazonaws.com` 서비스 프린시펄에 `kms:GenerateDataKey*`, `kms:Decrypt` 허용 + `aws:SourceAccount = 자기 계정` 조건(confused deputy 방지). Config가 S3에 기록을 쓸 때 버킷 기본 암호화(SSE-KMS)가 이 키로 데이터 키 생성을 요구하므로 필요하다.
- **L86–106 `AllowProjectRoles`** — principal `AWS: *`에 같은 두 액션을 허용하되, 조건 `StringLike: aws:PrincipalArn = arn:aws:iam::<계정>:role/gochuchamchi-*`로 **이름 패턴 매칭**한다. 이 우회가 이 파일의 백미다. 주석의 순환 의존 설명: Config 커스텀 역할 ARN을 직접 참조하면 "버킷 암호화 → 키 → Config 역할 → Config 모듈 → 버킷 암호화 depends_on"의 순환이 생긴다(키가 모듈 출력에 의존하는데 모듈은 키로 암호화된 버킷에 의존). principal을 와일드카드로 열고 PrincipalArn 조건으로 좁히면 키 정의가 역할 존재와 무관해져 순환이 끊긴다 — 접근 범위는 이 계정의 `gochuchamchi-*` 역할로 여전히 한정된다.

### L114–117 · output "kms_logs_key_arn"

Config 버킷 암호화 CMK ARN 노출.

---

## account-baseline/providers.tf (45줄)

파일의 절반이 주석인데, 그 주석이 이 루트의 헌법이다. L1–29 주석: 소속 기준("지워도 돈이 안 아끼는데, 지우면 apply가 실패하는 것")과 세 가지 유형 — 계정당 하나만 존재(GuardDuty 디텍터/Config 레코더/Security Hub/Inspector2 enabler/ECR 레지스트리 스캔 설정), destroy가 실패하거나 느림(Inspector2 5분 타임아웃 tainted, 8/4 §5.2), 재구축이 오히려 비용(Config는 apply 한 사이클에 구성 항목 수천 건 기록). 유휴 비용은 사실상 0(전부 사용량 과금, 클러스터가 꺼져 있으면 사용량도 0)이라 일일 스케일다운 대상이 아니고 destroy하지 않는다. 2026-08-10 org 로그 분리로 CloudTrail·중앙 버킷·Firehose·Athena는 Log 계정으로 전부 이관됐다(이 계정에 trail을 또 두면 두 번째 사본 과금). 5계층 관계표(management/log-archive/persistent/account-baseline/terraform)와 참조 방향 규율(terraform → account-baseline → ARN 조립 → log-archive 한 방향, 역방향 금지 — 역방향이 생기면 일일 운영이 이 계층을 다시 건드려 분리 의미가 소멸)까지 담고 있다.

### L31–38 · terraform { required_providers }

`hashicorp/aws` `~> 6.0` — 메이저 6 안에서 마이너 업데이트만 허용. guardduty.tf의 feature 리소스 방식(v6에서 datasources 블록 deprecated)이 이 버전 제약과 짝을 이룬다.

### L40–43 · provider "aws"

기본 프로바이더. `region = var.region`(기본 ap-northeast-2), `profile = var.aws_profile`(기본 workload-admin). SSO 기반 프로파일을 변수로 받아 로컬 환경 차이를 흡수한다. us-east-1 보조 프로바이더는 cloudwatch-monitoring-link.tf에 별도로 정의돼 있다.

### L45 · data "aws_caller_identity" "current"

현재 자격증명의 계정 ID·ARN 조회. 이 루트 전역에서 쓰인다 — account-guard의 precondition, Config 버킷 이름·정책의 계정 ID 보간, KMS 키 정책, Inspector enabler, MFA 정책의 ARN 조립까지. 계정 ID를 하드코딩하지 않는 원칙의 공급원이다(예외는 검증이 목적인 account-guard의 비교값과 backend, OAM 변수 validation의 정규식).

---

## account-baseline/security-hub.tf (41줄)

Security Hub CSPM(Cloud Security Posture Management)의 루트 쪽 진입점이다. 머리 주석의 요지: AWS Config가 기록한 리소스 구성을 근거로 보안 표준(Control)을 평가하므로, module.aws_config가 Recorder를 켠 뒤에 활성화되어야 Control 평가가 정상 시작된다(depends_on). 그리고 AWS 기본 표준 자동 활성화는 끄고 활성화할 표준을 코드로 명시해 관리한다 — 콘솔 클릭이 아니라 코드가 표준 목록의 단일 진실이 되게 하는 방침이다.

### L11–26 · module "security_hub"

`source = "./module/security-hub"` 로컬 모듈 호출.

- `enable_foundational_security_best_practices = true` — AWS Foundational Security Best Practices(FSBP) v1.0.0을 기본 활성화. AWS가 자사 서비스 전반에 대해 관리하는 실무형 표준으로, 이 프로젝트 리소스 기준으로는 대략 다음을 검사한다: IAM(루트 액세스 키 부재, MFA, 90일 미사용 자격증명, 와일드카드 관리자 정책 금지), S3(퍼블릭 차단, SSL 강제, 서버 측 암호화), EC2/EBS(기본 암호화, 퍼블릭 스냅샷 금지, IMDSv2, 보안그룹 0.0.0.0/0 SSH/RDP 금지), RDS(퍼블릭 접근 금지, 암호화, 자동 백업), EKS(엔드포인트 접근, 지원 버전), ECR(스캔 활성화, 태그 불변성), KMS(로테이션), CloudTrail/Config(활성화 여부), GuardDuty 활성화 등. 이 루트의 하드닝 리소스들(account-hardening, kms 로테이션, ECR 스캔)이 상당수 컨트롤의 PASS 근거가 되도록 설계돼 있다.
- `enable_cis_aws_foundations_benchmark_v3 = var.security_hub_enable_cis_benchmark_v3` — CIS AWS Foundations Benchmark v3.0.0은 **선택**(기본 false). CIS는 제3자(Center for Internet Security) 벤치마크로 IAM 자격증명 위생·루트 계정 통제·로깅(CloudTrail/Config/Flow Logs)·모니터링(메트릭 필터+알람 다수)·네트워크 기본 통제를 항목화한 것인데, FSBP와 겹치는 항목이 많고 점검 항목당 Config 평가가 늘어 비용이 는다. 주석 그대로 "점검 항목/비용이 늘어나므로 선택"이다.
- `auto_enable_new_controls = true` — AWS가 활성 표준에 새 Control을 추가하면 자동으로 켠다. 표준 선택은 수동(코드 명시), 표준 내 컨트롤 추종은 자동이라는 2단 정책이다.
- `depends_on = [module.aws_config]` — Config recorder 선행 보장. 없으면 Security Hub가 켜져도 Config 기반 컨트롤들이 "No data" 상태로 남는다.

### L33–36 · output "security_hub_arn"

현재 리전 Security Hub ARN(모듈 출력 재노출).

### L38–41 · output "security_hub_enabled_standards"

활성화한 표준 ARN 맵. 검증 스크립트가 기대 표준 목록과 대조하는 데 쓴다.

---

## account-baseline/ssm-session-logging.tf (71줄)

SSM Session Manager 세션 **전사(全寫) 로깅**이다. 이 환경에는 SSH 경로가 아예 없다 — 노드·NAT·배스천 어디에도 키페어가 붙어 있지 않고 접속은 SSM Session Manager 하나뿐이다. 따라서 이 파일의 두 리소스가 **유일한 접속 감사 증적**이다. 문서(SSM-SessionManagerRunShell)가 전사 스트리밍을 켜고, 로그 그룹이 그 내용을 받는다.

파일 생성 경위(2026-08-12 주석)가 IaC 운영의 교과서적 사건이다: 두 리소스가 account-baseline **state와 실제 AWS에는 있는데** 어느 스택의 코드에도 선언이 없었다(전 스택 grep 0건, git 이력 0건). 그 상태에서 이 스택을 apply하면 "not in configuration" 사유로 둘 다 삭제될 상황이었다 — OAM Link를 적용하려다 세션 로깅을 지울 뻔한 것이다. 선택지였던 `terraform state rm`(state에서만 떼어내기)은 쓰지 않았다 — 실물은 살아남아도 관리 대상 밖으로 밀려나 같은 사고가 반복되기 때문이다. 대신 `terraform state show`로 읽은 실물 값을 **추측 없이 그대로** 코드로 옮겨 IaC 관리 아래로 되돌렸고, 따라서 이 파일 추가 후 plan은 두 리소스에 대해 no change여야 한다는 검증 기준까지 주석에 남겼다.

### L23–32 · resource "aws_cloudwatch_log_group" "ssm_sessions"

- `name = "/gochuchamchi/ssm-sessions"` — 세션 전사가 쌓이는 로그 그룹. 배경 지식의 그 경로다.
- `retention_in_days = 90` — 접속 감사 증적 90일 보존. 무제한(기본)으로 두지 않아 비용을 통제하되 감사 추적에 충분한 기간이다.
- tags에 `Component = "ssm-session-audit"`.

### L37–71 · resource "aws_ssm_document" "session_manager_prefs"

- `name = "SSM-SessionManagerRunShell"` — **이름이 고정인 이유**(주석): Session Manager는 세션을 열 때 계정·리전 단위로 정확히 이 이름의 문서를 찾는다. 다른 이름으로 만들면 설정이 적용되지 않고 **조용히 기본값(전사 로깅 없음)으로 돌아간다**. 에러도 없이 증적이 사라지는 최악의 실패 모드라 이 주석의 가치가 크다.
- `document_type = "Session"`, `document_format = "JSON"`, content는 `jsonencode`로 `schemaVersion = "1.0"`, `sessionType = "Standard_Stream"`.
- `inputs` 하나하나:
  - `cloudWatchStreamingEnabled = true` — 전사 스트리밍 본체. 주석 그대로 "이 값이 false가 되면 접속 감사 증적이 사라진다".
  - `cloudWatchLogGroupName = aws_cloudwatch_log_group.ssm_sessions.name` — 위 로그 그룹 참조(리소스 간 의존이 이 참조로 성립).
  - `cloudWatchEncryptionEnabled = false` — 로그 그룹 KMS 암호화 강제 안 함(state show 실물 그대로). 켜려면 로그 그룹 CMK와 인스턴스 프로파일 키 권한이 함께 필요하다.
  - `idleSessionTimeout = "20"` — 방치 세션을 20분에 끊는다. 열어 둔 셸이 그대로 남는 것을 막는 위생 설정. `maxSessionDuration = ""`(총 세션 시간 상한은 미설정).
  - `runAsEnabled = false`, `runAsDefaultUser = ""` — OS 계정 강제 전환을 쓰지 않는다. 주석의 설계 판단: "루트로 붙는 것을 막지 않는 대신, 무엇을 했는지는 전부 남긴다" — 통제보다 완전한 기록을 택했다.
  - `kmsKeyId = ""` — 세션 데이터 자체의 KMS 종단 암호화 미사용(TLS는 기본 적용).
  - `s3BucketName = ""`, `s3KeyPrefix = ""`, `s3EncryptionEnabled = true` — S3 로깅 경로는 쓰지 않는다(CloudWatch 단일 경로). s3EncryptionEnabled=true는 S3 미사용 상태의 기본값이 실물에 남아 있던 것이다.
  - `shellProfile = { linux = "", windows = "" }` — 세션 시작 시 자동 실행 스크립트 없음.

---

## account-baseline/variables.tf (62줄)

이 루트의 입력 변수 7개(파일 밖의 OAM sink 변수 2개와 cost 변수 2개는 각 기능 파일에 병치돼 있다 — 기능 단위 응집을 우선한 배치다). 머리 주석의 설계 노트: ../terraform/variables.tf에서 이 계층이 쓰는 것만 가져왔고, 두 계층이 같은 이름의 변수를 각자 갖지만 값이 갈릴 여지가 있는 것은 region/aws_profile 둘뿐이며 둘 다 default 고정이라 실무상 문제가 없다. 대신 **tfvars를 공유하지 않는다** — 계층별 독립 apply가 분리의 목적이기 때문이다.

### L8–11 · variable "region"

`default = "ap-northeast-2"`. 기본 프로바이더 리전.

### L13–17 · variable "aws_profile"

`default = "workload-admin"`. PowerShell에서 관리 중인 AWS CLI(SSO) 프로파일명. 기본·us_east_1 프로바이더가 함께 쓴다.

### L19–27 · variable "enable_guardduty_runtime_monitoring"

`type = bool`, `default = false`. heredoc description이 판단 재료를 다 담는다 — 노드 DaemonSet 에이전트로 프로세스/시스콜 수준 탐지가 추가되지만 t3.small 2대에는 메모리 부담이 있어 기본 OFF, EKS 감사 로그/CloudTrail/FlowLogs 기반 탐지는 이 값과 무관하게 동작. guardduty.tf의 count 게이트 입력이다.

### L29–33 · variable "security_hub_enable_cis_benchmark_v3"

`type = bool`, `default = false`. CIS v3.0.0 표준 추가 활성화 스위치. security-hub.tf를 거쳐 모듈의 for_each 구성에 반영된다.

### L35–50 · variable "aws_config_snapshot_delivery_frequency"

`default = "Six_Hours"`. Config 전체 스냅샷의 S3 전달 주기 — 짧을수록 S3 객체 수와 비용이 는다는 트레이드오프를 description에 명시. `validation`이 AWS가 지원하는 5개 값(One_Hour/Three_Hours/Six_Hours/Twelve_Hours/TwentyFour_Hours)의 `contains` 화이트리스트로 오타를 plan에서 잡는다. 모듈 쪽 같은 이름 변수에도 동일 validation이 있어 이중 검증이다.

### L52–56 · variable "allowed_regions"

`type = list(string)`, `default = ["ap-northeast-2", "ap-northeast-1"]` — 서울 워크로드 + 도쿄 DR. Region Guard Deny 조건(`StringNotEquals: aws:RequestedRegion`)의 허용 목록이며, 글로벌 서비스는 정책의 NotAction으로 별도 제외된다는 관계를 description이 상기시킨다.

### L58–62 · variable "console_admin_users"

`type = list(string)`, `default = []`. MFA 강제 그룹에 넣을 IAM 사용자 목록 — "콘솔 전용 사용자만"이라는 조건이 description에 박혀 있다. 기본 빈 목록이면 iam-security.tf의 멤버십 리소스가 아예 생성되지 않는다(07/29 사고 재발 방지 장치의 변수 쪽 절반).

---

## account-baseline/module/aws-config/main.tf (181줄)

AWS Config 본체를 만드는 재사용 모듈이다. 구성은 4단: IAM 역할(신뢰 정책 + AWS 관리형 정책 + S3/KMS 전달 인라인 정책) → configuration recorder → delivery channel → recorder status(시작). Config는 이 순서 제약이 엄격한 서비스라(채널 없이 레코더를 시작할 수 없고, 레코더 없이 채널을 만들 수 없다) depends_on 체인이 촘촘하다.

### L1–2 · data "aws_caller_identity" "current" / data "aws_partition" "current"

모듈 자체적으로 계정 ID와 파티션(`aws`/`aws-cn`/`aws-us-gov`)을 조회한다. 루트에서 넘겨받지 않고 자급하는 이유는 모듈의 독립성 — 어떤 루트에 붙여도 자기 실행 컨텍스트를 스스로 안다. 파티션 data는 관리형 정책 ARN과 SourceArn 조립에 쓰여 GovCloud 등에서도 깨지지 않는 이식성을 준다.

### L4–11 · locals (normalized_s3_key_prefix, config_s3_object_prefix)

- `normalized_s3_key_prefix = trim(var.s3_key_prefix, "/")` — 입력이 `"config"`든 `"/config/"`든 슬래시를 벗겨 정규화. 경로 이중 슬래시 버그의 예방이다.
- `config_s3_object_prefix` — prefix가 빈 문자열이면 `AWSLogs/<계정ID>/Config`, 있으면 `<prefix>/AWSLogs/<계정ID>/Config`를 삼항으로 조립. Config 서비스가 실제로 객체를 쓰는 고정 경로 구조를 그대로 코드화한 것으로, 아래 s3_delivery 정책의 PutObject resource와 출력 `s3_delivery_path`가 이 local을 공유해 정책 경로와 실제 경로의 불일치를 구조적으로 막는다.

### L15–41 · data "aws_iam_policy_document" "assume_role"

Config 역할의 신뢰 정책(`AllowAWSConfigAssumeRole`).

- principal `config.amazonaws.com` 서비스, action `sts:AssumeRole`.
- `condition StringEquals: aws:SourceAccount = <계정ID>` — 타 계정의 Config가 이 역할을 assume하는 confused deputy 차단.
- `condition ArnLike: aws:SourceArn = arn:<파티션>:config:*:<계정ID>:*` — 호출 주체가 이 계정의 Config 리소스임을 ARN 수준에서 한 번 더 조인다. 리전 자리만 `*`(Config는 리전 서비스라 어느 리전의 레코더든 허용). SourceAccount+SourceArn 이중 조건은 AWS 권장 강화 패턴이다.

### L43–55 · resource "aws_iam_role" "this"

`name = "${var.name_prefix}-aws-config"`(→ gochuchamchi-aws-config), 위 신뢰 정책 부착, description 명시, `tags = merge(var.tags, { Name, Component = "aws-config" })` — 루트 공통 태그에 모듈 자체 태그를 얹는 표준 병합.

### L57–60 · resource "aws_iam_role_policy_attachment" "config_role"

AWS 관리형 `service-role/AWS_ConfigRole` 부착. 모든 지원 리소스 타입에 대한 **읽기(Describe/List/Get)** 권한 묶음으로, 레코더가 계정 리소스 구성을 조회하는 데 필요한 권한을 AWS가 리소스 타입 추가에 맞춰 관리해 준다. 파티션 data로 ARN을 조립해 이식성 유지. 단, 이 관리형 정책에는 S3 쓰기·KMS 권한이 없어서 다음 인라인 정책이 따로 필요하다.

### L64–121 · data "aws_iam_policy_document" "s3_delivery"

역할이 S3에 전달(쓰기)할 때 쓰는 인라인 정책 문서다. 이 모듈에서 장애 이력이 가장 짙게 밴 블록이다.

- **L65–76 `CheckConfigDeliveryBucket`** — 버킷 ARN에 `s3:GetBucketAcl`/`GetBucketLocation`/`ListBucket`. Config가 전달 전 버킷 검증(writability check)에 쓰는 조회 세트다.
- **L78–100 `WriteConfigHistory`** — `s3:PutObject`를 `<버킷ARN>/<config_s3_object_prefix>/*` 정확한 경로로만 허용. 조건이 `StringEqualsIfExists: s3:x-amz-acl = bucket-owner-full-control`인데, L88–94 주석이 2026-08-03 실장애의 인과를 복기한다: 중앙 로그 버킷은 BucketOwnerEnforced(ACL 비활성)라서 AWS Config가 "ACL 비활성 버킷"을 감지하면 **x-amz-acl 헤더를 아예 안 보낸다**. 기존 `StringEquals`(헤더 필수)로는 헤더 없는 PutObject가 조건 불일치로 거부되어 InsufficientDeliveryPolicyException이 났다. IfExists = 헤더가 있으면 bucket-owner-full-control이어야 하고, 없으면(ACL 비활성 버킷) 그냥 허용 — 버킷의 ACL 모드가 무엇이든 동작하는 형태다. 현재 전용 버킷 체제에서도 이 견고화가 유지된다.
- **L105–120 dynamic "statement" (UseBucketCmk)** — `for_each = var.kms_key_arn == null ? [] : [var.kms_key_arn]`로 **키가 지정된 경우에만** 생성되는 조건부 문장. `kms:GenerateDataKey*`/`Decrypt`/`DescribeKey`를 해당 키 ARN에 허용한다. L102–104 주석의 인과: 대상 버킷이 CMK 기본 암호화면 S3가 객체 암호화 시 **이 역할 자격으로** KMS를 호출한다 → 역할에 키 권한이 없으면 PutObject가 KMS 단계에서 거부되고, 그 실패가 InsufficientDeliveryPolicyException으로 **표면화**된다(2026-08-03 확인). 에러 이름만 보면 S3 정책 문제로 보이는데 실제 원인은 KMS였다는, 디버깅 관점에서 값진 기록이다. 키 정책(kms-logs.tf AllowProjectRoles)과 이 역할 정책이 양쪽에서 만나야 KMS 접근이 성립한다.

### L123–127 · resource "aws_iam_role_policy" "s3_delivery"

위 문서를 인라인 정책 `<prefix>-aws-config-s3-delivery`로 역할에 부착.

### L131–152 · resource "aws_config_configuration_recorder" "this"

- `name = "${var.name_prefix}-configuration-recorder"`, `role_arn = aws_iam_role.this.arn`.
- `recording_group`: `all_supported = true` + `recording_strategy { use_only = "ALL_SUPPORTED_RESOURCE_TYPES" }` — 현재와 **미래에 추가될** 지원 리소스 타입 전부 기록. 타입을 고르는 화이트리스트 방식 대신 전량 기록을 명시했다. `include_global_resource_types = var.include_global_resource_types` — IAM 등 글로벌 리소스 포함 여부(루트가 true 전달; Security Hub IAM 컨트롤의 데이터 근거).
- `recording_mode { recording_frequency = "CONTINUOUS" }` — 변경 즉시 기록. DAILY(일별 요약) 대안 대비 항목당 과금이 늘지만 변경 이력의 시간 해상도를 지킨다.
- `depends_on = [aws_iam_role_policy_attachment.config_role, aws_iam_role_policy.s3_delivery]` — 권한이 완성되기 전 레코더가 생기면 초기 기록·전달 검증이 실패할 수 있어 정책 부착 완료를 선행 조건으로 박았다.

### L156–171 · resource "aws_config_delivery_channel" "this"

- `s3_bucket_name = var.s3_bucket_name`, `s3_key_prefix = local.normalized_s3_key_prefix == "" ? null : local.normalized_s3_key_prefix` — 빈 문자열 대신 null을 보내는 이유는 API가 빈 문자열 prefix를 유효값으로 취급하지 않기 때문(속성 생략과 빈 값의 구분).
- `s3_kms_key_arn = var.kms_key_arn` — CMK 암호화 버킷이면 키를 채널에도 명시. 주석이 인용하는 실제 에러 메시지("provided kms key is 'null'")의 해소책이다. 역할 권한(UseBucketCmk)과 채널 선언 두 곳 모두 필요하다.
- `snapshot_delivery_properties { delivery_frequency = var.snapshot_delivery_frequency }` — 전체 스냅샷 전달 주기(루트 기본 Six_Hours).
- `depends_on = [recorder, s3_delivery 정책]` — Config API 제약상 채널 생성에 레코더 선존재가 필요하고, 채널 생성 시 실행되는 전달 검사(writability check)가 통과하려면 S3/KMS 권한도 먼저 있어야 한다.

### L175–181 · resource "aws_config_configuration_recorder_status" "this"

- `name = aws_config_configuration_recorder.this.name`, `is_enabled = true` — 레코더를 실제로 **시작**한다. AWS Config는 "레코더 정의"와 "레코더 시작"이 별개 API라 Terraform 리소스도 분리돼 있다.
- `depends_on = [aws_config_delivery_channel.this]` — 주석 그대로 "Delivery Channel이 만들어진 뒤 Recorder를 시작해야 함". 채널 없이 시작하면 NoAvailableDeliveryChannelException으로 실패한다. 이로써 역할→레코더→채널→시작의 전체 체인이 완성된다.

## account-baseline/module/aws-config/variables.tf (70줄)

### L1–10 · variable "name_prefix"

`default = "gochuchamchi"`. validation이 `^[A-Za-z0-9-]+$` + 길이 45자 이하 — IAM 역할명(64자 한도)에 `-aws-config` 등 접미사가 붙어도 한도를 넘지 않도록 여유를 잡은 제한이다.

### L12–20 · variable "s3_bucket_name"

필수(기본값 없음). validation `length(trimspace(...)) > 0` — 공백만 있는 문자열까지 걸러낸다. delivery channel의 대상 버킷 이름.

### L22–30 · variable "s3_bucket_arn"

필수. validation `^arn:[^:]+:s3:::[^/]+$` — 버킷 ARN 형식만 허용하고, `/`가 포함된 객체 경로 ARN이 들어오는 것을 배제한다(파티션 자리를 `[^:]+`로 열어 GovCloud도 허용). IAM 정책 resource 조립에 쓰인다.

### L32–36 · variable "s3_key_prefix"

`default = "config"`. 버킷 내 경로 접두사 — 모듈 locals에서 trim 정규화를 거친다.

### L38–42 · variable "include_global_resource_types"

`type = bool`, `default = true`. IAM 사용자·그룹·역할·정책 등 글로벌 리소스 기록 여부. recorder의 recording_group으로 직결된다.

### L44–59 · variable "snapshot_delivery_frequency"

`default = "Six_Hours"` + 루트 변수와 동일한 5개 값 contains validation. 루트-모듈 이중 검증 구조다.

### L61–65 · variable "tags"

`type = map(string)`, `default = {}`. IAM Role 태그에 병합될 공통 태그.

### L67–70 · variable "kms_key_arn"

`default = null` — null이면 KMS 관련 문장·인자가 아예 생성되지 않는 옵셔널 설계(dynamic statement의 for_each 게이트). description이 이 변수의 존재 이유를 압축한다: 지정하면 delivery channel에 명시하고 Config 역할에 키 사용 권한을 부여한다 — CMK 강제 암호화 버킷에서 필수(2026-08-03 InsufficientDeliveryPolicyException의 원인).

## account-baseline/module/aws-config/outputs.tf (23줄)

### L1–4 · output "configuration_recorder_name"

레코더 이름 — 루트 output과 CLI 상태 확인(`describe-configuration-recorder-status`)용.

### L6–9 · output "delivery_channel_name"

채널 이름. 루트에서는 재노출하지 않지만 모듈 인터페이스로 제공.

### L11–14 · output "iam_role_arn"

Config 역할 ARN — 루트 `aws_config_role_arn`의 원천.

### L16–19 · output "s3_delivery_path"

`s3://<버킷>/<config_s3_object_prefix>/` 형태의 실제 저장 경로. locals를 재사용해 정책과 항상 일치하는 경로를 노출한다.

### L21–23 · output "recorder_enabled"

recorder_status의 `is_enabled` 값. 검증 스크립트가 "켜져 있는가"를 output만으로 확인할 수 있게 한다.

## account-baseline/module/aws-config/versions.tf (9줄)

### L1–9 · terraform { required_version, required_providers }

`required_version = ">= 1.5.0"`(precondition 등 최신 문법 하한), aws `~> 6.0` — 루트 providers.tf와 동일 제약을 모듈에도 명시. 모듈은 프로바이더를 상속하지만, 버전 요구를 자체 선언해야 다른 루트에 재사용될 때도 제약이 따라간다.

---

## account-baseline/module/security-hub/main.tf (42줄)

Security Hub 활성화와 표준 구독을 담는 소형 모듈이다. 설계 축은 "기본 표준 자동 활성화 OFF + 코드로 명시한 표준만 for_each 구독".

### L1–2 · data "aws_partition" "current" / data "aws_region" "current"

표준 ARN 조립용 파티션·리전 조회. Security Hub 표준 ARN은 리전이 박히는 형식이라 리전 data가 필요하다(`data.aws_region.current.region` — provider v6의 신 속성명).

### L4–16 · locals (표준 ARN과 enabled_standards 맵)

- `foundational_standard_arn` — `arn:<파티션>:securityhub:<리전>::standards/aws-foundational-security-best-practices/v/1.0.0`. 계정 ID 자리가 빈(`::`) AWS 소유 리소스 ARN이다.
- `cis_v3_standard_arn` — `.../cis-aws-foundations-benchmark/v/3.0.0`.
- `enabled_standards` — 두 bool 변수에 따라 `{ foundational = ARN }`, `{ cis_v3 = ARN }`을 조건부로 merge한 맵. **맵의 키(foundational/cis_v3)가 for_each의 state 주소가 되는 것**이 요점이다 — ARN 자체를 키로 쓰면 표준 버전 업그레이드(예: CIS v3.0.0→다음 버전) 시 state 주소가 바뀌어 재생성 diff가 나지만, 논리 이름 키는 주소를 안정적으로 유지한다.

### L21–25 · resource "aws_securityhub_account" "this"

Security Hub 계정 활성화(리전당 하나).

- `enable_default_standards = false` — 켜는 순간 AWS가 기본 표준을 임의로 자동 구독하는 동작을 차단. 어떤 표준을 쓸지는 아래 구독 리소스(코드)가 결정한다 — "표준 목록의 단일 진실은 코드"라는 방침의 구현이다.
- `auto_enable_controls = var.auto_enable_new_controls`(루트에서 true) — 이미 활성화된 표준에 AWS가 새 Control을 추가하면 자동 활성화. 표준 선택은 수동, 컨트롤 추종은 자동.
- `control_finding_generator = "SECURITY_CONTROL"` — 통합 컨트롤 finding 방식. 구 방식(STANDARD_CONTROL)은 같은 검사가 표준마다 별개 finding을 만들어 FSBP와 CIS를 같이 켜면 중복 finding이 났지만, 이 방식은 **컨트롤당 finding 하나**로 통합된다(신규 계정 기본값이기도 하다). CIS를 나중에 켤 수 있는 이 구성에서 중복 노이즈를 미리 제거한 선택이다.

### L30–43 · resource "aws_securityhub_standards_subscription" "this"

- `for_each = local.enabled_standards` — 맵 기반 구독. 변수 토글만으로 표준이 plan 차원에서 추가/제거된다.
- `standards_arn = each.value`.
- `depends_on = [aws_securityhub_account.this]` — Security Hub가 켜지기 전 구독 시도는 실패하므로 명시 순서.
- `timeouts { create = "10m", delete = "10m" }` — 표준 활성화는 수백 개 컨트롤 배치가 도는 비동기 작업이라 기본 타임아웃보다 넉넉히 잡았다. Inspector2 enabler의 15분 타임아웃과 같은 계열의 "느린 보안 서비스 API" 대응이다.

활성화되는 표준의 검사 내용: **FSBP v1.0.0**은 AWS 서비스별 실무 통제(위 security-hub.tf 해설의 목록 — IAM 자격증명 위생, S3 퍼블릭/암호화/SSL, EC2·EBS 암호화와 IMDSv2, RDS 접근·암호화, EKS/ECR/KMS/CloudTrail/Config/GuardDuty 활성화 상태 등)를 리소스 단위로 평가한다. **CIS v3.0.0**(선택)은 CIS 벤치마크 체계를 따라 루트 계정 통제(액세스 키 금지·MFA·하드웨어 MFA), 자격증명 수명주기(45일 미사용 비활성화, 키 로테이션), 로깅(CloudTrail 전 리전·검증·암호화, Config 활성화, S3 액세스 로깅, Flow Logs), 모니터링(무단 API 호출·콘솔 로그인 실패·루트 사용 등 메트릭 필터+알람), 네트워크(기본 SG 트래픽 차단, 0.0.0.0/0 관리 포트 금지) 항목을 검사한다.

## account-baseline/module/security-hub/variables.tf (16줄)

### L1–5 · variable "enable_foundational_security_best_practices"

`type = bool`, `default = true` — FSBP v1.0.0 활성화 여부. 루트가 true를 명시 전달한다.

### L7–11 · variable "enable_cis_aws_foundations_benchmark_v3"

`type = bool`, `default = false` — CIS v3.0.0 추가 활성화 여부. 루트 변수 `security_hub_enable_cis_benchmark_v3`가 흘러 들어온다.

### L13–16 · variable "auto_enable_new_controls"

`type = bool`, `default = true` — 활성 표준에 AWS가 새 Control을 추가할 때 자동 활성화할지. aws_securityhub_account의 `auto_enable_controls`로 직결.

## account-baseline/module/security-hub/outputs.tf (21줄)

### L1–4 · output "security_hub_arn"

`aws_securityhub_account.this.arn` — 현재 리전 Security Hub ARN.

### L6–9 · output "enabled_standard_arns"

`local.enabled_standards` 맵 그대로 — 활성화하기로 한 표준의 논리명→ARN. 루트 output `security_hub_enabled_standards`의 원천.

### L11–17 · output "standard_subscription_arns"

for 표현식으로 구독 리소스의 실제 subscription ARN을 `{ 논리명 = ARN }` 맵으로 변환해 노출. 위 출력이 "의도"라면 이것은 "실제 구독 결과"다.

### L19–21 · output "control_finding_generator"

`SECURITY_CONTROL` 값 노출 — finding 생성 방식을 외부에서 확인·검증할 수 있게 한다.

## account-baseline/module/security-hub/versions.tf (9줄)

### L1–9 · terraform { required_version, required_providers }

aws-config 모듈의 versions.tf와 동일 — `>= 1.5.0`, aws `~> 6.0`. 두 모듈이 같은 제약을 자체 선언해 루트와의 버전 정합을 보장한다.

---

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| account-baseline/account-guard.tf | 10 | 1 | 전체 |
| account-baseline/account-hardening.tf | 46 | 3 | 전체 |
| account-baseline/aws-config.tf | 236 | 11 | 전체 |
| account-baseline/backend.tf | 16 | 1 | 전체 |
| account-baseline/cloudwatch-monitoring-link.tf | 72 | 6 | 전체 |
| account-baseline/cost-monitoring.tf | 101 | 6 | 전체 |
| account-baseline/ecr-scanning.tf | 36 | 2 | 전체 |
| account-baseline/guardduty.tf | 88 | 6 | 전체 |
| account-baseline/iam-security.tf | 174 | 9 | 전체 |
| account-baseline/kms-logs.tf | 117 | 5 | 전체 |
| account-baseline/providers.tf | 45 | 3 | 전체 |
| account-baseline/security-hub.tf | 41 | 3 | 전체 |
| account-baseline/ssm-session-logging.tf | 71 | 2 | 전체 |
| account-baseline/variables.tf | 62 | 7 | 전체 |
| account-baseline/module/aws-config/main.tf | 181 | 11 | 전체 |
| account-baseline/module/aws-config/variables.tf | 70 | 8 | 전체 |
| account-baseline/module/aws-config/outputs.tf | 23 | 5 | 전체 |
| account-baseline/module/aws-config/versions.tf | 9 | 1 | 전체 |
| account-baseline/module/security-hub/main.tf | 42 | 5 | 전체 |
| account-baseline/module/security-hub/variables.tf | 16 | 3 | 전체 |
| account-baseline/module/security-hub/outputs.tf | 21 | 4 | 전체 |
| account-baseline/module/security-hub/versions.tf | 9 | 1 | 전체 |


---

# persistent · discord-notifications — 상시 자원 계층

이 프로젝트의 Workload 계정은 두 개의 시간 축을 가진다. 런타임 루트(`go/terraform`)는 비용 절약을 위해 매일 아침 daily-up으로 태어나고 매일 밤 daily-down으로 파괴된다(약 278개 리소스). 반면 여기서 다루는 `persistent/`는 그 파괴 사이클에서 **살아남아야 하는 것들**만 모아 둔 상시 자원 계층이다. 무엇이 남는가 — 서명된 컨테이너 이미지(ECR), 이미지 서명·데이터 암호화 KMS 키, ArgoCD용 GitHub PAT 시크릿 그릇, CloudFront 액세스 로그 버킷, GuardDuty 자동대응 차단 IP set, 그리고 CI가 AWS를 assume하는 OIDC provider와 IAM role. 무엇이 사라지는가 — VPC, EKS, RDS, ALB, CloudFront 배포, WAF Web ACL 같은 런타임 전부다.

두 계층의 경계에는 일관된 계약이 있다. **참조 방향은 항상 일일 → 상시 한 방향**이고, 런타임 루트는 상시 자원을 remote state가 아니라 `data` 소스(이름·별칭 고정 조회)로 읽는다(`../terraform/persistent-data.tf`, `edge-logs.tf`). 따라서 `persistent/`를 먼저 apply해야 런타임 루트의 apply가 성립한다. 이 계층에 들어온 리소스들은 대부분 사고의 산물이다 — ECR 이미지가 destroy에 쓸려나가 ImagePullBackOff·503이 반복된 사고(7/31, 8/6), KMS 키 ARN이 매일 바뀌어 CI 서명이 깨진 사고(8/6), 시크릿 값이 재구축마다 증발한 사고(8/5~8/6), 로그 버킷이 teardown을 통째로 실패시킨 사고(8/12). 즉 persistent는 "일일 파괴 아키텍처에서 파괴가 건드리면 안 되는 것들의 목록"을 사고 하나하나로 배워서 코드화한 결과물이다.

`discord-notifications/`는 성격이 조금 다른 별도 루트다. ArgoCD Notifications 컨트롤러를 Discord 웹훅에 배선하는 Kubernetes 리소스 2개(+계정 가드)를 담는데, 대상인 EKS 클러스터 자체는 일일 계층 소유다. 그런데도 별도 state로 분리한 이유는 이 루트의 apply/destroy가 메인 인프라에 영향을 주지 않게 하고, 클러스터 이름 하나만으로 독립적으로 접속을 구성하기 위해서다. 클러스터가 떠 있을 때만 apply가 성립한다는 점에서 "상시 코드, 일일 대상"인 셈이다.

---

## persistent/account-guard.tf (12줄)

3계정(Management/Log/Workload) SSO 환경에서 가장 흔한 사고는 "엉뚱한 프로필로 apply"다. 이 파일은 실행 계정이 Workload(828885965304)가 아니면 plan 단계에서 즉시 실패시키는 안전핀이다. 다른 루트들(management, log-archive, discord-notifications 등)에도 각자 자기 계정 번호로 같은 패턴이 복제되어 있다.

### L1 · data "aws_caller_identity" "current"

현재 자격증명(프로필·SSO 세션)이 가리키는 AWS 계정 ID·ARN을 STS에서 조회한다. 인자가 없는 data 소스이며, 아래 가드뿐 아니라 `cloudfront-logs.tf`의 버킷 이름·버킷 정책 조건에서도 `account_id`를 참조한다. 계정 ID를 코드에 하드코딩하는 대신 이 data 소스를 쓰면 "지금 실제로 로그인된 계정"이 기준이 된다.

### L3–12 · resource "terraform_data" "account_guard"

- `terraform_data`는 Terraform 1.4+에 내장된 리소스 타입으로, 외부 provider 없이 값을 state에 담거나 lifecycle 체크의 앵커로 쓸 수 있다(`null_resource`의 현대적 대체재 — provider 다운로드가 필요 없다).
- `input = data.aws_caller_identity.current.account_id` — 검증에 쓴 계정 ID를 state에 남겨, 나중에 "이 state가 어느 계정에서 만들어졌는지" 추적할 수 있게 한다.
- `lifecycle.precondition` — `condition`이 `account_id == "828885965304"`(Workload 계정)일 때만 통과한다. precondition은 **plan 시점에 평가**되므로, management-admin 프로필로 잘못 실행해도 리소스에 손대기 전에 `error_message`("persistent/는 Workload 계정 828885965304에서만 실행할 수 있습니다")와 함께 멈춘다. provider 레벨의 `allowed_account_ids`로도 같은 효과를 낼 수 있지만, 이 프로젝트는 에러 메시지를 한국어로 명시하고 루트별로 눈에 보이는 파일 하나로 규약을 드러내는 쪽을 택했다.

## persistent/backend.tf (16줄)

이 루트의 tfstate 저장 위치를 선언한다. 같은 버킷을 쓰는 다른 루트(`../terraform`, `../discord-notifications`)와 `key`만 다른 동일 패턴이다.

### L3–16 · terraform { backend "s3" }

- `bucket = "gochuchamchi-tfstate-828885965304"` — 계정 ID를 접미사로 붙여 S3 전역 네임스페이스 충돌을 피한다. 이 버킷 자체는 부트스트랩 단계에서 만든 것이다.
- `key = "persistent/terraform.tfstate"` — 루트별로 key를 분리해 하나의 버킷에 여러 state를 공존시킨다. state 분리가 곧 blast radius 분리다: 런타임 루트를 destroy해도 이 state는 손도 안 댄다.
- `region = "ap-northeast-2"` / `profile = "workload-admin"` — backend 블록은 provider 설정을 상속하지 않으므로 프로필을 따로 명시해야 한다. backend 블록에는 변수를 쓸 수 없어서(초기화 시점 제약) 값이 하드코딩되어 있다.
- `encrypt = true` — state 객체를 SSE로 암호화해 업로드한다.
- `use_lockfile = true` — 주석(L1)대로 Terraform 1.10+의 **S3 네이티브 잠금**이다. 과거처럼 DynamoDB 테이블을 따로 두지 않고, S3 조건부 쓰기로 `.tflock` 객체를 만들어 동시 apply를 막는다. 학생 프로젝트에서 DynamoDB 테이블 하나를 관리 대상에서 지운 실용적 선택이고, `providers.tf`의 `required_version = ">= 1.10"`이 이 기능의 하한이다.
- `kms_key_id = "arn:aws:kms:...:alias/gochuchamchi-tfstate"` — 2026-08-13에 추가된 SSE-KMS 지정. 함정이 하나 있다: `encrypt = true`만 두면 Terraform이 PUT 요청에 `AES256`을 **명시적으로** 실어 보내서, 버킷에 걸어 둔 기본 암호화(SSE-KMS)를 객체 단위로 덮어써 버린다. 그래서 버킷 기본값에 기대지 않고 key alias ARN을 직접 지정해 state 객체가 확실히 CMK로 암호화되게 했다(상세 사연은 `../terraform/backend.tf` 주석 참조).

## persistent/cloudfront-logs.tf (204줄)

CloudFront 액세스 로그를 받는 S3 버킷과 그 부속 설정 전부(소유권·퍼블릭 차단·암호화·수명주기·버킷 정책·output)를 한 파일에 담았다. 파일 머리의 긴 주석(L1–24)이 이 프로젝트에서 가장 좋은 교훈 하나를 기록하고 있다: 이 버킷은 원래 일일 계층(`../terraform`)에 있었고, 매일 밤 로그가 같이 지워지는 걸 막으려고 `force_destroy = false`를 걸어 두었다. 그런데 그 플래그는 보존 장치가 아니라 **teardown을 실패시키는 장치**였다 — S3는 비어 있지 않은 버킷을 지울 수 없으므로 2026-08-12 저녁 daily-down이 `BucketNotEmpty`로 멈췄고, 8/11 로그가 남아 있던 것도 "보존 성공"이 아니라 "destroy 연속 실패"의 흔적이었다. 커밋 5832f65가 버킷을 상시 계층으로 옮겨 해결했다: 이제 로그는 날짜를 넘겨 누적되고 일일 계층은 깨끗하게 지워진다. 이 분리가 가능한 구조적 이유도 주석에 명시돼 있다 — 버킷 정책이 CloudFront 배포 ARN을 참조하지 않고 delivery-source를 와일드카드로 허용하므로, 배포가 매일 새로 만들어져도 정책은 그대로 유효하다. 일일 계층(`../terraform/edge-logs.tf`)은 이 버킷을 `data "aws_s3_bucket"`으로 읽기만 하므로, 이 루트를 먼저 apply해야 한다.

### L26–33 · locals { cloudfront_log_tags }

공통 태그 맵이다. `Project = "gochuchamchi"`, `Environment = "project"`, `ManagedBy = "Terraform"`, `Component = "edge-logs"`. 버킷 태그에서 `merge()`로 `Component`를 `"cloudfront-logs"`로 덮어쓰는데, 이는 "edge-logs 기능군에 속하되 이 리소스는 로그 버킷"이라는 두 단계 분류를 태그로 표현한 것이다. 비용 탐색기나 리소스 검색에서 계층을 구분하는 용도다.

### L35–46 · resource "aws_s3_bucket" "cloudfront_logs"

- `bucket = "gochuchamchi-cloudfront-logs-${data.aws_caller_identity.current.account_id}"` — 계정 ID 접미사로 전역 유일성을 확보한다. 이름이 결정적(deterministic)이라는 점이 중요하다: 일일 계층이 remote state 없이 **이름만으로** `data "aws_s3_bucket"` 조회를 할 수 있는 근거다.
- `force_destroy = false` — 같은 인자, 정반대 의미. 일일 계층에 있을 때는 매일 밤 destroy와 충돌해 사고를 냈지만, 이 루트는 destroy 대상이 아니므로 이제는 순수하게 "실수로 이 루트를 destroy해도 증적(로그)이 있으면 지워지지 않게 막는" 보호 장치로 작동한다(L38–39 주석). 진짜 지우려면 버킷을 비우는 명시적 행동이 선행돼야 한다.
- `tags = merge(...)` — 위 locals에 `Name`과 `Component = "cloudfront-logs"`를 덮어쓴다.

### L48–54 · resource "aws_s3_bucket_ownership_controls" "cloudfront_logs"

`object_ownership = "BucketOwnerEnforced"` — ACL을 완전히 비활성화하고 모든 객체의 소유권을 버킷 소유자로 강제한다(현행 AWS 권장 기본값). CloudFront 신형 로그 전달(v2, `delivery.logs.amazonaws.com` 경유)은 구형 로그(ACL 기반 전달)와 달리 버킷 **정책**으로 권한을 받으므로 ACL이 꺼져 있어도 동작한다. 접근 제어 모델을 정책 하나로 단일화해 감사 포인트를 줄이는 설정이다.

### L56–63 · resource "aws_s3_bucket_public_access_block" "cloudfront_logs"

네 플래그(`block_public_acls`, `block_public_policy`, `ignore_public_acls`, `restrict_public_buckets`)를 모두 `true`로 잠근다. 액세스 로그에는 클라이언트 IP·URI 등 민감 정보가 담기므로 퍼블릭 노출 경로를 원천 차단하는 표준 4종 세트다. 이 리소스가 아래 버킷 정책의 `depends_on`에 들어가는 이유는 그쪽에서 설명한다.

### L65–73 · resource "aws_s3_bucket_server_side_encryption_configuration" "cloudfront_logs"

`sse_algorithm = "AES256"` — SSE-S3(S3 관리 키)다. tfstate 버킷과 달리 CMK(SSE-KMS)를 쓰지 않은 것은 의도적 선택으로 보면 된다: 로그 전달은 PUT이 잦아 KMS 요청 비용이 붙고, 서비스 주체의 KMS 권한 배선도 추가로 필요하다. 접근 로그는 비밀 값이 아니라 접근 통제가 핵심이므로(위 public access block + 아래 TLS 강제) SSE-S3로 충분하다는 판단이다.

### L75–104 · resource "aws_s3_bucket_lifecycle_configuration" "cloudfront_logs"

로그 비용 관리의 핵심이다. 규칙 하나(`id = "archive-cloudfront-access-logs"`, `status = "Enabled"`)에 네 동작이 들어 있다.

- `filter { prefix = "" }` — 버킷 전체 대상. provider v4+에서 lifecycle rule은 filter를 명시해야 하므로 빈 prefix로 "전부"를 표현한다.
- `transition { days = 30, storage_class = "STANDARD_IA" }` — 30일 뒤 저빈도 접근 계층으로. 30이라는 숫자는 취향이 아니라 제약이다 — S3는 STANDARD_IA 전환에 최소 30일을 요구한다. 최근 30일 로그는 사고 조사로 자주 열어볼 수 있으니 STANDARD 유지가 합리적이기도 하다.
- `transition { days = 90, storage_class = "GLACIER" }` — 90일 뒤 장기 보관 계층으로. 조회는 느려지지만 "증적 보존"이라는 버킷의 존재 이유에는 부합한다.
- `expiration { days = var.cdn_log_retention_days }` — 기본 365일 후 삭제. 변수로 뺀 이유와 `> 90` validation의 이유는 `variables.tf`에서 설명한다(만료일이 마지막 전환일보다 커야 한다는 S3 제약).
- `abort_incomplete_multipart_upload { days_after_initiation = 7 }` — 실패한 멀티파트 업로드 조각이 눈에 안 보이게 과금되는 것을 7일 뒤 청소하는 위생 설정이다.

### L106–184 · data "aws_iam_policy_document" "cloudfront_logs"

버킷 정책 본문을 HCL로 조립한다. `jsonencode`보다 policy document data 소스를 쓰면 문법 검증과 condition 블록 가독성을 얻는다. 세 statement로 구성된다.

- **L107–127 `DenyInsecureTransport`** — `aws:SecureTransport = "false"` 조건에서 모든 주체(`*`)의 `s3:*`를 명시적 Deny. 평문 HTTP 접근을 버킷·객체 레벨 모두(`arn`, `arn/*`) 차단하는 보안 베이스라인이다. 명시적 Deny는 어떤 Allow보다 우선한다.
- **L129–152 `AWSLogDeliveryAclCheck`** — 서비스 주체 `delivery.logs.amazonaws.com`(CloudFront 표준 로깅 v2가 쓰는 통합 로그 전달 서비스)에 버킷 ARN 대상 `s3:GetBucketAcl`, `s3:ListBucket`을 허용한다. 로그 전달 서비스가 쓰기 전에 버킷 상태를 확인하는 데 필요한 최소 권한이다. 두 condition이 핵심이다: `aws:SourceAccount = 내 계정 ID`는 **confused deputy 방지**(다른 계정이 같은 AWS 서비스를 시켜 내 버킷에 쓰게 하는 공격 차단)이고, `aws:SourceArn`의 `ArnLike` 값 `arn:aws:logs:us-east-1:<계정>:delivery-source:*`는 이 계정의 delivery-source에서 온 요청만 허용한다. 리전이 `us-east-1`인 이유는 CloudFront가 글로벌(us-east-1 기준) 서비스라 그 delivery-source 리소스가 us-east-1에 생기기 때문이다. 그리고 **끝의 `*` 와일드카드가 이 파일 전체 설계를 지탱한다** — 특정 배포 ARN을 박아 넣지 않았기 때문에, CloudFront 배포가 매일 destroy/재생성되어 delivery-source가 새로 만들어져도 이 정책은 수정 없이 유효하다. 상시 계층과 일일 계층의 분리가 성립하는 기술적 조건이다.
- **L154–183 `AWSLogDeliveryWrite`** — 같은 서비스 주체에 객체 레벨(`arn/*`) `s3:PutObject`를 허용한다. 추가 condition `s3:x-amz-acl = "bucket-owner-full-control"`은 로그 객체가 반드시 버킷 소유자 완전 제어로 업로드되도록 강제하는 관례적 조건이고, `SourceAccount`/`SourceArn` 조건은 위와 동일한 이중 잠금이다.

### L186–194 · resource "aws_s3_bucket_policy" "cloudfront_logs"

위 policy document를 버킷에 부착한다. `depends_on = [ownership_controls, public_access_block]`이 명시된 이유: Terraform은 참조가 없으면 이들을 병렬 적용하는데, 소유권/퍼블릭 차단 설정과 정책 부착이 경합하면 일시적 충돌(예: 퍼블릭 정책 평가 순서 문제)이 날 수 있어 순서를 고정한 것이다. S3 부속 리소스들 사이의 암묵적 경합을 없애는 방어적 패턴이다.

### L196–199 · output "cloudfront_log_bucket_name"

`aws_s3_bucket.cloudfront_logs.id`(= 버킷 이름). description이 계약을 문장으로 남긴다 — "일일 계층이 data로 읽는다". 실제 조회는 이름 규칙으로 하므로 이 output은 사람 확인용이다.

### L201–204 · output "cloudfront_log_bucket_arn"

버킷 ARN. 정책 디버깅이나 다른 도구에서 참조할 때 쓴다.

## persistent/ecr.tf (175줄)

컨테이너 이미지 레지스트리와, GitHub Actions CI가 액세스 키 없이 push할 수 있게 하는 OIDC 신뢰 체계를 담는다. 파일 머리 주석(L1–12)이 state 분리의 이유를 기록한다: 메인 인프라를 destroy하면 `force_delete`가 이미지까지 전부 지웠고, 재구축 후 GitOps 매니페스트가 가리키는 태그가 없어 파드가 ImagePullBackOff → ALB 503이 됐다. 2026-07-31과 08-06에 같은 사고가 반복되어 그때마다 CI를 손으로 재실행해야 했고, 2026-08-06에 이 파일을 persistent로 떼어냈다(계획서 `docs/ecr-state-separation.txt`). OIDC provider·role까지 함께 옮긴 이유도 주석(L102–109)에 있다 — role ARN이 재구축으로 바뀌면 GitHub 쪽 변수(`AWS_ECR_BUILD_ROLE_ARN` 등)와 어긋나 CI가 통째로 죽고, 이미지를 살려도 CI가 죽으면 복구 수단이 없다.

### L14–52 · resource "aws_ecr_repository" "gochuchamchi"

- `name = "gochuchamchi"` — 고정 이름. 일일 계층 `persistent-data.tf`가 이름으로 data 조회한다.
- `image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"` — PR #5에서 이관한 불변 태그 설정(L17–21 주석). `release-*`/`candidate-*` 태그에는 GitHub run 식별자가 들어가므로 같은 태그가 다른 digest로 옮겨질 이유가 없다 — 불변으로 잠가 태그 바꿔치기(공급망 공격·실수 재푸시)를 차단한다. 그런데 완전 `IMMUTABLE`이면 문제가 생긴다: Cosign은 서명·어테스테이션을 `sha256-<digest>.sig` 같은 **OCI 태그 매니페스트**로 저장하고, 서명을 추가·로테이션할 때마다 이 태그를 같은 이름으로 갱신한다. 불변이면 서명 갱신 자체가 막힌다. 그래서 예외 필터가 있는 변종을 쓴다.
- `image_tag_mutability_exclusion_filter` ×3 (L24–37) — `sha256-*.sig`(서명), `sha256-*.att`(어테스테이션), `sha256-*.sbom`(SBOM)을 `WILDCARD` 타입으로 예외 처리. Cosign 참조 아티팩트 3종만 가변으로 남기고 실제 이미지 태그는 전부 불변이다.
- `force_delete = true` (L39–41) — 직관에 반하는 조합처럼 보이지만 주석이 논리를 설명한다: 정말 저장소를 지워야 하는 날, 이미지가 남아 있다는 이유로 막히면 곤란하다(cloudfront-logs가 `BucketNotEmpty`로 겪은 것과 같은 종류의 함정을 피함). 실수 방지는 이 플래그가 아니라 아래 `prevent_destroy`가 담당한다 — "지울 수 있는 능력"과 "지우지 않겠다는 결심"을 다른 장치에 맡긴 역할 분리다.
- `lifecycle { prevent_destroy = true }` (L45–47) — 이 state를 분리한 목적이 곧 이미지 보존이므로, plan에 destroy가 잡히면 Terraform이 에러로 거부한다. 정말 지우려면 이 블록을 코드에서 먼저 지워야 한다(L43–44 주석). 사람의 2단계 확인을 코드로 강제하는 패턴이다.
- `image_scanning_configuration { scan_on_push = true }` — push 시점 기본 취약점 스캔. 비용 없는 기본 방어선이다.

### L54–100 · resource "aws_ecr_lifecycle_policy" "gochuchamchi"

저장소 용량·비용을 관리하는 3단계 만료 정책(PR #5 이관). `jsonencode`로 규칙 리스트를 넣는다. **rulePriority의 순서가 정책의 정확성을 결정한다**는 것이 이 블록의 핵심이다.

- **rule 1 (priority 1): `signed-*` 태그 최근 20개 보존** — `tagStatus = "tagged"` + `tagPatternList = ["signed-*"]` + `imageCountMoreThan 20`. 즉 서명 릴리스는 최신 20개만 남기고 만료. 이 규칙이 반드시 최우선이어야 하는 이유(L61–62 주석): 같은 digest가 `candidate-*` 태그도 함께 갖고 있어서, candidate 만료 규칙이 먼저 매칭되면 **서명된 릴리스가 candidate 규칙에 걸려 만료**될 수 있다. ECR lifecycle은 이미지당 우선순위가 가장 낮은 번호의 매칭 규칙 하나만 적용하므로, 보존 규칙을 1번에 둬야 서명 이미지가 candidate 규칙의 영향권 밖에 놓인다.
- **rule 2 (priority 2): `candidate-*` 7일 만료** — `sinceImagePushed 7 days`. 서명 잡이 실패해 `signed-*` 태그를 못 받은 candidate는 릴리스 가치가 없으므로 일주일 뒤 청소한다(L74–75 주석).
- **rule 3 (priority 3): untagged 7일 만료** — 빌드 중간 산물·태그를 뺏긴 레이어 매니페스트를 청소한다.

### L110–112 · data "tls_certificate" "github_actions"

GitHub OIDC 발급자(`token.actions.githubusercontent.com`)의 TLS 인증서 체인을 가져와 SHA-1 thumbprint를 얻는다. `providers.tf`에 `tls` provider(~> 4.0)가 선언된 이유가 이 data 소스 하나다. 참고로 현재 AWS는 GitHub OIDC에 대해 자체 신뢰 루트를 쓰기 때문에 thumbprint가 사실상 무시되지만, API 스키마상 값은 여전히 필요하므로 하드코딩 대신 동적으로 조회해 인증서 로테이션에도 코드가 깨지지 않게 했다.

### L114–122 · resource "aws_iam_openid_connect_provider" "github_actions"

- `url = "https://token.actions.githubusercontent.com"` — GitHub Actions의 OIDC 발급자. 이 provider가 있어야 워크플로의 OIDC 토큰으로 `AssumeRoleWithWebIdentity`가 가능하다. 액세스 키를 GitHub Secret에 두지 않는 keyless 인증의 뿌리다.
- `client_id_list = ["sts.amazonaws.com"]` — 토큰의 `aud` 클레임으로 허용할 값. AWS 공식 aud다.
- `thumbprint_list` — 위 data 소스의 첫 인증서 fingerprint.
- `lifecycle { prevent_destroy = true }` — OIDC provider는 계정당 발급자별 1개뿐이고, 아래 두 role의 trust policy가 이 ARN을 참조한다. 재생성되면 ARN이 바뀌어 신뢰 체계가 무너지므로 잠근다.

### L124–144 · resource "aws_iam_role" "github_actions_ecr_push"

CI 빌드 잡이 assume하는 role이다. `assume_role_policy`의 Condition 두 개가 보안의 전부다:

- `StringEquals`: `token.actions.githubusercontent.com:aud = "sts.amazonaws.com"` — aud 검증.
- `StringLike`: `sub = "repo:${var.github_owner}/gochuchamchi-spring:ref:refs/heads/main"` — **sub 클레임을 저장소·브랜치까지 고정**한다. 같은 owner의 다른 저장소, 같은 저장소의 PR 브랜치·포크에서는 assume이 불가능하다. L137 주석대로 "main 브랜치 push(=CI 트리거 조건)"과 정확히 일치시킨 것이다. sub 조건이 없으면 GitHub의 아무 저장소나 이 role을 쓸 수 있게 되는 것이 OIDC 신뢰 정책의 고전적 함정인데, 그 함정을 정확히 막았다.

### L146–175 · resource "aws_iam_role_policy" "github_actions_ecr_push"

빌드 role의 인라인 권한 정책(`name = "ecr-push"`).

- `EcrAuth`: `ecr:GetAuthorizationToken`을 `Resource = "*"`로 — 이 액션은 리소스 레벨 제한을 지원하지 않아 `*`가 API상 불가피하다(docker login 토큰 발급).
- `EcrPush`: 레이어 업로드 4종(`InitiateLayerUpload`/`UploadLayerPart`/`CompleteLayerUpload`/`BatchCheckLayerAvailability`) + 매니페스트 읽기·쓰기(`BatchGetImage`/`GetDownloadUrlForLayer`/`PutImage`)를 **이 저장소 ARN 하나로만** 허용. 캐시 활용을 위한 pull 계열이 포함된 최소 push 권한 세트다. 서명용 KMS 권한이 없다는 점이 중요하다 — 서명은 별도 role(`image-signing.tf`)의 몫이다.

## persistent/image-signing.tf (113줄)

이미지 서명 파이프라인의 상시 부분 — Cosign이 쓰는 KMS 서명 키와, 서명 잡 전용 IAM role이다. 전체 그림: CI 빌드 잡이 `candidate-*` 이미지를 push → 보호된 GitHub Environment의 서명 잡이 이 KMS 키로 Cosign 서명을 만들어 ECR에 게시 → 클러스터의 Kyverno(일일 계층 담당)가 이 키의 공개키로 배포 시점 검증. 머리 주석(L1–16)의 사고 기록: 재구축하면 KMS 키가 새로 생기고 옛 키는 30일 PendingDeletion으로 들어가는데, 수동 관리이던 GitHub 변수 `IMAGE_SIGNING_KMS_KEY_ARN`이 옛 키를 가리킨 채 CI가 돌면 서명 잡 실패 → 이미지 미게시 → 503. 2026-08-06에 실제로 이 경로를 탔고 원인이 세 단계 떨어져 있어 추적이 오래 걸렸다. 지금은 `../terraform/ci-sync.tf`가 apply마다 GitHub 변수를 실제 ARN으로 덮어써 수동 동기화가 필요 없지만, 이 파일의 역할은 그보다 근본적이다 — **ARN이 애초에 바뀌지 않게** 만든다.

### L18–24 · locals { image_signing_tags }

`Project`/`ManagedBy`/`Component = "image-signing"` 공통 태그. 키와 role에 재사용된다.

### L27–38 · resource "aws_kms_key" "image_signing"

- `key_usage = "SIGN_VERIFY"` — 암복호화가 아닌 서명·검증 전용 비대칭 키. **개인키는 KMS 밖으로 절대 나오지 않는다**(L26 주석) — CI 러너가 탈취돼도 키 유출이 아니라 "서명 권한 남용"까지만 피해가 한정되고, 그마저 CloudTrail의 `kms:Sign` 호출 기록으로 추적된다. 파일 기반 Cosign 키 대비 이 방식의 결정적 장점이다.
- `customer_master_key_spec = "ECC_NIST_P256"` — Cosign/Sigstore 생태계의 표준 곡선(ECDSA P-256). 서명이 작고 검증이 빠르다.
- `deletion_window_in_days = 30` — 삭제 예약 시 대기 기간 최대치. 서명 키가 사라지면 **이미 서명된 모든 이미지의 검증이 불가능**해지므로 실수 복구 시간을 최대로 잡았다. `kms-data.tf`의 7일과 대비되는 지점이다.
- `lifecycle { prevent_destroy = true }` — 같은 이유로 Terraform 레벨에서도 잠금. 이중 안전장치다.

### L40–43 · resource "aws_kms_alias" "image_signing"

`alias/gochuchamchi-image-signing`. 사람이 콘솔·CLI에서 키를 찾는 이름이고, `cosign --key awskms:///...`에 alias로도 키를 지정할 수 있다. key_id가 아닌 alias를 외부에 노출하면 키 로테이션 시 참조를 바꿀 필요가 없어진다.

### L49–71 · resource "aws_iam_role" "github_actions_image_signer"

서명 전용 role. 머리 주석(L45–48)이 권한 분리 원칙을 명시한다 — 빌드 role(`github_actions_ecr_push`)은 이 키를 쓸 수 없다. 빌드가 오염돼도 서명은 못 만든다는 뜻이다.

- `max_session_duration = 3600` — 세션 1시간(기본값을 명시). 서명 잡은 몇 분이면 끝나므로 길 이유가 없다.
- trust policy의 Condition이 빌드 role과 결정적으로 다르다: `sub`가 `repo:<owner>/gochuchamchi-spring:environment:${var.image_signing_github_environment}` 형식이고 **`StringLike`가 아닌 `StringEquals`**다. GitHub의 보호된 Environment(`production-signing`)에서 도는 잡만 정확히 일치로 assume할 수 있다. Environment 보호 규칙(승인자, 브랜치 제한)이 곧 이 role의 추가 게이트가 된다 — "브랜치 조건"(빌드)보다 한 단계 강한 "환경 조건"(서명)이다.

### L73–113 · resource "aws_iam_role_policy" "github_actions_image_signer"

서명 잡의 인라인 정책(`name = "sign-and-publish-cosign-artifact"`). 세 statement:

- `EcrAuthentication`: `ecr:GetAuthorizationToken` — 빌드 role과 같은 이유로 `Resource = "*"`.
- `ReadCandidateAndPublishSignature`: candidate 이미지를 **읽고**(digest 확인: `DescribeImages`/`BatchGetImage`/`GetDownloadUrlForLayer`), 서명 아티팩트 태그 매니페스트를 **쓰는**(`PutImage` + 레이어 업로드 3종) 권한을 저장소 ARN 하나로 한정. Cosign 서명은 결국 ECR에 OCI 아티팩트를 push하는 작업이므로 push 계열 권한이 필요하다.
- `SignWithDedicatedKmsKey`: `kms:Sign`(서명 생성), `kms:GetPublicKey`(서명에 넣을 공개키 조회), `kms:DescribeKey`(키 상태 확인)를 **이 서명 키 ARN 하나로만** 허용. `kms:Decrypt`도 `kms:CreateKey`도 없다 — 문자 그대로 "이 키로 서명만 할 수 있는" role이다.

## persistent/kms-data.tf (38줄)

워크로드 데이터(RDS/EFS/AWS Backup) 암호화용 대칭 CMK다. 머리 주석(L1–16)의 이력: 원래 일일 계층에 있어 키가 매일 삭제 예약(7일 대기)되고 새 ARN으로 태어났다. 문제 두 가지 — (1) **DR 백업 복구 지점이 키보다 오래 산다**: 키가 소멸하면 백업 파일이 멀쩡해도 복호화가 불가능한, "백업은 있는데 복원이 안 되는" DR 최악의 실패 모드다. (2) ARN이 매일 바뀌어 외부 참조와 어긋난다(8/6 서명 키 503과 같은 유형). 2026-08-07에 여기로 옮겼는데, 이동 방식이 흥미롭다 — baseline 55건처럼 `removed` + `import`로 state 수술을 한 게 아니라 **"코드 이동 + 재생성"**을 택했다. 어차피 매일 재생성되던 리소스라 기존 키에 지킬 값이 없었고, 전체 재구축 시점에 태어나는 위치만 바꾸면 됐기 때문이다. 리소스의 성격에 따라 이관 전략을 달리한 좋은 사례다.

### L18–28 · resource "aws_kms_key" "data"

- `key_usage`/`customer_master_key_spec` 미지정 — 기본값인 대칭 `ENCRYPT_DECRYPT`/`SYMMETRIC_DEFAULT`. RDS·EFS·Backup이 요구하는 것이 정확히 대칭 CMK다.
- `enable_key_rotation = true` — 연 1회 자동 백킹 키 로테이션. ARN·alias는 그대로 유지되므로 참조가 깨지지 않으면서 키 재료만 갱신된다. 비대칭 키(서명 키)는 이 옵션을 지원하지 않아 저쪽에는 없다.
- `deletion_window_in_days = 7` — 최소값. 서명 키의 30일과 다른 이유를 생각해 볼 만하다: 이 키는 alias 기반 조회라 재생성 시 참조 복구가 쉽고, 짧은 창은 "지우기로 결정했으면 빨리 정리"라는 의미다. 다만 **이 리소스에는 `prevent_destroy`가 없다** — 서명 키·시크릿과 달리 Terraform 레벨 잠금이 빠져 있다는 점은 알고 있어야 할 비대칭이다(백업 암호화 키라는 성격상 발표·면접에서 "보완 여지"로 언급할 수 있는 지점이다).
- `tags` — `Name = "gochuchamchi-data-cmk"` 포함 표준 3종.

### L30–33 · resource "aws_kms_alias" "data"

`alias/gochuchamchi-data`. **일일 계층이 이 키를 찾는 유일한 경로**다 — `../terraform/persistent-data.tf`가 ARN 하드코딩 없이 이 별칭으로 data 조회한다(L14–15 주석). 별칭이 간접 참조 계층이 되어 "키는 persistent, 참조는 이름으로"라는 계약을 완성한다.

### L35–38 · output "kms_data_key_arn"

키 ARN. 일일 계층은 별칭으로 조회하므로 이것은 사람 확인·검증 스크립트용이다.

## persistent/outputs.tf (29줄)

머리 주석(L1–4)이 이 루트의 출력 철학을 요약한다: 메인(`../terraform`)은 이 값들을 `terraform_remote_state`가 아니라 **data 소스로 직접 조회**한다. 이름이 고정된 리소스뿐이라 data 소스 쪽이 결합도가 낮고(다른 state 파일의 스키마에 묶이지 않음) apply 순서에도 덜 민감하기 때문이다. 따라서 아래 output 5개는 기계 간 인터페이스가 아니라 **사람이 값을 확인할 때** 쓴다 — 특히 GitHub 변수와 대조할 때.

### L6–9 · output "ecr_repository_url"

`aws_ecr_repository.gochuchamchi.repository_url`. CI push 대상이자 GitOps 매니페스트의 이미지 참조 경로다.

### L11–14 · output "github_actions_ecr_role_arn"

빌드 role ARN — GitHub 변수 `AWS_ECR_BUILD_ROLE_ARN`에 대응. 워크플로의 `role-to-assume`에 들어간다.

### L16–19 · output "github_actions_image_signer_role_arn"

서명 role ARN — GitHub 변수 `AWS_IMAGE_SIGNER_ROLE_ARN`에 대응.

### L21–24 · output "image_signing_kms_key_arn"

서명 키 ARN — `cosign --key awskms:///<arn>` 형식으로 쓰이며 GitHub 변수 `IMAGE_SIGNING_KMS_KEY_ARN`에 대응. 이 세 변수는 `../terraform/ci-sync.tf`가 자동 동기화하므로 output은 검증용이다.

### L26–29 · output "argocd_git_pat_secret_name"

레거시 통합 PAT 시크릿의 이름. description이 운영 절차를 문서화한다 — 값 주입은 `aws secretsmanager put-secret-value`로(Terraform은 값을 다루지 않는다). 신형 분리 시크릿 2개(PR #7)의 output은 아직 없다는 점도 눈에 띈다.

## persistent/providers.tf (26줄)

### L1–14 · terraform { required_version, required_providers }

- `required_version = ">= 1.10"` — backend의 `use_lockfile`(S3 네이티브 잠금)이 1.10 기능이라 하한이 여기서 온다.
- `aws ~> 6.0` — v6 메이저 고정. `IMMUTABLE_WITH_EXCLUSION` 같은 신형 인자를 쓰려면 최신 메이저가 필요하다. `~>`는 6.x 안에서만 업그레이드를 허용해 v7 파괴적 변경을 차단한다.
- `tls ~> 4.0` — `data "tls_certificate"`(OIDC thumbprint 조회) 하나 때문에 있다.

### L16–19 · provider "aws" (기본)

`region = var.region`(ap-northeast-2), `profile = var.aws_profile`(workload-admin). 이 루트의 거의 모든 리소스가 사용한다.

### L22–26 · provider "aws" (alias = "us_east_1")

리전만 us-east-1로 바꾼 별칭 provider. L21 주석대로 **CLOUDFRONT scope WAF 리소스는 us-east-1 전용**이라는 AWS 제약 때문에 존재하며, `waf-blocklist.tf`의 IP set 하나가 이것을 쓴다. profile은 동일 — 계정은 같고 리전만 다르다.

## persistent/secrets.tf (56줄)

ArgoCD 계열이 private GitOps 저장소에 접근할 때 쓰는 GitHub PAT의 **그릇(컨테이너)** 3개다. 이 파일의 설계 원칙은 하나로 요약된다 — **Terraform은 시크릿의 값을 절대 만지지 않는다**. `aws_secretsmanager_secret_version` 리소스를 쓰지 않으므로 PAT 평문이 tfstate에 남지 않는다(감사 #1이 정한 원칙, L19–20 주석). 그릇만 Terraform이 만들고, 값은 운영자가 CLI(`aws secretsmanager put-secret-value`)로 1회 주입하며, ESO(External Secrets Operator)가 그 값을 K8s Secret으로 동기화한다. 머리 주석(L1–21)의 사고 기록: `recovery_window_in_days = 0`인 시크릿은 destroy 때 값까지 즉시 소멸한다. 일일 계층에 있던 시절 재구축마다 빈 그릇만 생겨 ESO → ArgoCD → 앱 배포가 통째로 멈춰 503이 됐고(8/5, 8/6 연속), 그릇을 영속화하자 값도 재구축을 건너 살아남게 됐다. `../terraform/eso.tf`의 자동 주입은 "값이 이미 있으면 건드리지 않는다" 방식이라 충돌하지 않는다.

**ESO 관련 함정 하나**: ESO ExternalSecret이 `property` 지정 없이 이 시크릿들을 읽으므로, **시크릿 값 전체가 곧 PAT 문자열**이어야 한다. JSON으로 감싸면 안 되고, 끝에 개행이 붙어도 안 된다(개행 포함 문자열이 그대로 Authorization 헤더로 가서 인증이 깨진다). 값 주입 시 가장 흔한 실수 지점이다.

### L23–34 · resource "aws_secretsmanager_secret" "argocd_git_pat"

레거시 통합 시크릿 `gochuchamchi/argocd/git-pat`(Contents: Read/write). PR #7의 읽기/쓰기 분리 이후에도 **롤백용으로 남겨 둔** 그릇이다 — 분리 구성에 문제가 생기면 GitOps 쪽을 되돌려 이 시크릿 하나로 복귀할 수 있다.

- `name` — `gochuchamchi/argocd/git-pat`. 슬래시 계층 네이밍으로 프로젝트/용도를 인코딩. ESO가 이 이름으로 조회하므로 이름 자체가 인터페이스다.
- `description` — 값의 권한 범위와 관리 방식을 영문으로 명시("Value injected manually via CLI, synced to K8s by ESO — never touched by Terraform"). 콘솔에서 이 시크릿을 본 사람이 절차를 알 수 있게 한 문서화다.
- `recovery_window_in_days = 0` — 삭제 시 30일 복구 유예 없이 즉시 소멸. 위험해 보이지만 L27–28 주석의 논리: 이 state는 destroy 대상이 아니므로 복구 기간이라는 개념 자체가 무의미하고, 유예 기간이 있으면 오히려 같은 이름 재생성이 30일간 막히는 부작용이 있다. 사고 방지는 복구 창이 아니라 `prevent_destroy`가 맡는다.
- `lifecycle { prevent_destroy = true }` — 값을 담은 그릇의 파괴를 Terraform 레벨에서 거부.

### L38–46 · resource "aws_secretsmanager_secret" "argocd_gitops_read_pat"

PR #7이 추가한 분리 시크릿 1: `gochuchamchi/argocd/gitops-read-pat`. **Argo CD 본체용 — Contents: Read-only** fine-grained PAT가 들어간다. Argo CD는 GitOps 저장소를 읽기만 하면 되므로 쓰기 권한을 주지 않는다. 인자 구성(recovery 0 + prevent_destroy)은 레거시와 동일한 패턴이다.

### L48–56 · resource "aws_secretsmanager_secret" "argocd_image_updater_write_pat"

분리 시크릿 2: `gochuchamchi/argocd/image-updater-write-pat`. **Argo CD Image Updater용 — Contents: Read/write**. Image Updater는 새 이미지 태그를 GitOps 저장소에 커밋해야 하므로 쓰기가 필요하다. 이 분리(L36–37 주석)의 가치: 읽기 전용 토큰이 유출돼도 저장소 변조가 불가능하고, 쓰기 토큰의 사용 주체가 Image Updater 하나로 좁혀져 감사가 쉬워진다. 최소 권한 원칙을 PAT 단위까지 내린 것이다.

## persistent/variables.tf (33줄)

### L1–5 · variable "aws_profile"

기본값 `workload-admin`. description이 `../terraform/variables.tf`와 같은 값임을 명시 — 루트 간 프로필 규약을 문서로 묶는다.

### L7–10 · variable "region"

기본값 `ap-northeast-2`(서울). WAF IP set만 별칭 provider로 us-east-1을 쓴다.

### L12–16 · variable "github_owner"

기본값 `landoll9999`. OIDC trust policy의 `sub` 조건(`repo:<owner>/gochuchamchi-spring:...`)에 들어간다. `../terraform`의 `argocd_github_owner`와 같은 값이어야 CI와 GitOps가 같은 계정을 본다.

### L18–22 · variable "image_signing_github_environment"

기본값 `production-signing`. 서명 role trust policy의 environment sub 조건에 들어간다. GitHub 쪽 Environment 이름과 정확히 일치해야 하며, 어긋나면 서명 잡의 assume이 조용히 거부된다.

### L24–33 · variable "cdn_log_retention_days"

기본값 365(일). `cloudfront-logs.tf` lifecycle의 `expiration.days`로 들어간다. `validation` 블록이 핵심이다 — `condition = var.cdn_log_retention_days > 90`, 에러 메시지 "logs transition to Glacier on day 90". S3는 만료일이 마지막 전환일(90일 Glacier)보다 커야 한다는 제약이 있는데, 이를 apply 시점 API 에러로 만나는 대신 **plan 시점 validation으로 앞당겨** 놓았다. 변수의 유효 범위를 코드가 스스로 설명하는 패턴이다.

## persistent/waf-blocklist.tf (47줄)

GuardDuty 자동대응 파이프라인의 상시 조각 — 공격자 IP 차단 목록이다. 머리 주석(L1–15)의 구조: 격리 Lambda(`../cloudwatch-notifications/isolation_function.py`)가 네트워크 기반 GuardDuty finding의 원격 IP를 이 IP set에 넣고, 일일 계층의 edge WAF(`../terraform/edge.tf`)가 이 IP set을 block rule로 참조해 CloudFront 엣지에서 차단한다. 왜 persistent인가 — **WAF Web ACL은 매일 죽어도 "무엇을 차단 중인가"라는 상태는 사고가 끝날 때까지 살아야 한다.** 차단 목록이 일일 계층에 있었다면 매일 밤 리셋되어, 공격자가 자정 이후 다시 들어올 수 있었을 것이다. 참조 방향은 여기서도 한 방향(일일 → 상시)이다: edge WAF는 data 소스로 ARN을 읽고, Lambda는 이름으로 조회해 IP를 넣고, 만료 IP는 audit 경로(매시간)가 뺀다 — **WAF IP set에는 TTL이 없어서** 자동 만료를 코드로 구현해야 한다는 것이 이 설계의 숨은 제약이다.

### L17–37 · resource "aws_wafv2_ip_set" "guardduty_blocklist"

- `provider = aws.us_east_1` — `scope = "CLOUDFRONT"`인 WAF 리소스는 us-east-1에서만 만들 수 있다는 AWS 제약. `providers.tf`의 별칭 provider가 여기서 쓰인다.
- `name = "gochuchamchi-guardduty-blocklist"` — 고정 이름. Lambda가 이 이름으로 IP set을 찾으므로 이름이 곧 API다.
- `scope = "CLOUDFRONT"` — 엣지(글로벌) 배포용. 리전 ALB용(`REGIONAL`)이 아니라 CloudFront 앞단에서 차단한다 — 공격 트래픽이 오리진에 닿기 전에 끊는 가장 바깥 방어선이다.
- `ip_address_version = "IPV4"` — GuardDuty finding의 원격 IP가 IPv4 기준이라 맞췄다.
- `addresses = []` — 초기 빈 목록. L25 주석대로 채우는 것은 Terraform이 아니라 Lambda의 런타임 몫이다.
- `lifecycle { ignore_changes = [addresses] }` — **이 블록이 없으면 설계가 무너진다.** Terraform은 state와 실제의 차이를 "드리프트"로 보고 apply마다 `addresses`를 코드의 빈 목록으로 되돌린다 — 즉 apply 한 번에 차단 중이던 공격자 IP가 전부 풀린다(L27–28 주석). `ignore_changes`로 이 속성의 소유권을 Lambda에 넘겨, "그릇은 Terraform, 내용물은 런타임"이라는 secrets.tf와 동일한 소유권 분리 패턴을 완성한다.
- `tags` — `Component = "auto-response"`로 자동대응 기능군임을 표시.

### L39–42 · output "guardduty_blocklist_ip_set_name"

Lambda가 조회·갱신에 쓰는 이름(CLOUDFRONT scope, us-east-1이라는 맥락 포함). Lambda 환경변수 설정 시 대조용이다.

### L44–47 · output "guardduty_blocklist_ip_set_arn"

일일 edge WAF가 block rule에서 참조할 ARN. 실제 참조는 data 소스로 하므로 역시 사람 확인용이다.

## discord-notifications/account-guard.tf (12줄)

`persistent/account-guard.tf`와 동일한 패턴의 계정 가드다. 에러 메시지의 루트 이름만 "discord-notifications/"로 다르다.

### L1 · data "aws_caller_identity" "current"

현재 자격증명의 계정 ID 조회. 이 루트에서는 가드 전용이다.

### L3–12 · resource "terraform_data" "account_guard"

`precondition`으로 Workload 계정(828885965304)이 아니면 plan을 실패시킨다. 이 루트는 EKS에 kubernetes provider로 붙기 때문에 계정이 어긋나면 `data.aws_eks_cluster` 조회부터 이상한 에러로 실패하는데, 가드가 있으면 "계정이 틀렸다"는 명확한 메시지를 먼저 받는다.

## discord-notifications/backend.tf (15줄)

### L2–15 · terraform { backend "s3" }

`persistent/backend.tf`와 완전히 같은 구성에서 `key = "discord-notifications/terraform.tfstate"`만 다르다. 같은 tfstate 버킷, 같은 `use_lockfile`(S3 네이티브 잠금), 같은 `kms_key_id`(2026-08-13 SSE-KMS 명시 — `encrypt = true`만으로는 AES256이 버킷 기본 암호화를 덮어쓰는 문제의 동일한 해결). state가 분리되어 있으므로 이 루트의 apply/destroy는 메인 인프라 state에 영향을 주지 않는다.

## discord-notifications/notifications.tf (104줄)

ArgoCD Notifications → Discord 웹훅 배선의 본체다. 머리 주석(L1–10)이 이 루트가 성립하는 원리를 설명한다: argo-helm/argo-cd 차트의 notifications 컨트롤러(기본 활성화 — `../terraform/argocd.tf`의 `helm_release.argocd`에서 끄지 않았으므로 켜져 있음)는 argocd 네임스페이스의 **표준 이름**(ConfigMap `argocd-notifications-cm`, Secret `argocd-notifications-secret`)을 읽어 동작한다. 컨트롤러는 "누가 만들었는지"가 아니라 "이름이 맞는지"만 보므로, 어느 state에서 만들든 상관없다 — 이 이름 규약이 별도 루트 분리를 가능하게 한 열쇠다. 전제조건은 `../terraform` apply로 EKS + ArgoCD가 이미 떠 있는 것이며, 어긋나면 providers.tf의 `data.aws_eks_cluster` 조회가 plan 단계에서 실패해 바로 드러난다.

### L13–22 · resource "kubernetes_secret_v1" "argocd_notifications_secret"

- `metadata.name = "argocd-notifications-secret"` / `namespace = "argocd"` — 컨트롤러가 찾는 표준 이름 그대로. 바꾸면 동작하지 않는다.
- `data = { discord-webhook-url = var.discord_webhook_url }` — 웹훅 URL을 Secret에만 담는다(kubernetes provider의 `data`는 자동 base64 인코딩). L12 주석대로 ConfigMap에서는 `$discord-webhook-url` **참조 문법**으로만 쓰인다 — notifications-engine이 `$키이름`을 이 Secret의 해당 키 값으로 치환해 준다. URL이 ConfigMap(평문 노출 대상)에 들어가지 않게 하는 관례다. 한 가지 알아둘 nuance: `variables.tf`에서 `sensitive = true`로 plan 출력은 마스킹되지만, kubernetes_secret 리소스의 특성상 **웹훅 URL이 이 루트의 tfstate에는 들어간다**. state 버킷이 SSE-KMS로 암호화되고 접근이 workload-admin으로 제한된다는 것이 방어선이다 — persistent/secrets.tf의 "값은 state 밖" 원칙과는 다른 트레이드오프임을 구분해서 설명할 수 있어야 한다.

### L24–104 · resource "kubernetes_config_map_v1" "argocd_notifications_cm"

notifications 컨트롤러의 전체 설정을 담는 ConfigMap. `data`의 키 하나하나가 컨트롤러의 설정 단위다. 이 블록의 주석들은 전부 "실제로 확인해 보니"로 시작하는 시행착오의 기록이라 발표 소재로 좋다.

- **`service.webhook.discord` (L34–39)** — 알림 전송 채널 정의. 왜 범용 webhook인가(L31–33 주석): notifications-engine에는 "discord"라는 **네이티브 서비스 타입이 없다**. 소스(`pkg/services`)에 discord.go가 없고, 시도하면 컨트롤러 로그에 "service type 'discord' is not supported" 에러가 실제로 났다. 그래서 범용 webhook 서비스로 Discord Webhook URL에 직접 POST한다. `url: $discord-webhook-url`이 위 Secret 참조이고, `headers`의 `Content-Type: application/json`은 Discord API가 JSON body를 요구하기 때문이다. 서비스 이름의 뒷부분("discord")이 아래 template의 `webhook.discord` 키와 짝을 이룬다.
- **`trigger.on-sync-succeeded` / `on-sync-failed` / `on-health-degraded` (L47–69)** — 언제 알림을 보낼지 정의하는 트리거 3종. L41–44 주석의 발견: trigger/template은 컨트롤러 내장이 아니라 **이 CM 안에 명시적으로 있어야만 동작**한다. 기존엔 argo-cd 차트가 기본 catalog로 채워 줬던 것인데, 이제 CM을 이 루트가 전담하므로 argoproj/argo-cd의 `notifications_catalog/install.yaml`에서 그대로 가져왔다. 각 트리거의 구조: `when`은 조건식(CEL 유사) — sync 성공은 `operationState.phase in ['Succeeded']`, 실패는 `['Error', 'Failed']`, 성능 저하는 `health.status == 'Degraded'`. `oncePer: app.status.operationState?.syncResult?.revision`은 **같은 revision에 대해 한 번만** 발송한다는 중복 억제 — 컨트롤러가 재조정(reconcile)을 반복해도 revision이 안 바뀌면 Discord가 도배되지 않는다. `send`는 발송할 template 이름 목록이다.
- **`template.app-sync-succeeded` / `app-sync-failed` / `app-health-degraded` (L71–93)** — 메시지 본문 3종. catalog 기본 template을 같은 이름으로 **오버라이드**한 이유(L44–46 주석): 기본 template에는 discord용 webhook body가 없고(`message` 필드만 있음), webhook 서비스의 기본 동작은 GET + 메시지 원문 전송인데 **Discord webhook은 POST + JSON만 허용**한다. 그래서 각 template에 `webhook.discord.method: POST`와 JSON `body`를 명시했다. body는 Go template 문법으로 앱 이름(`{{.app.metadata.name}}`), 완료 시각/에러 메시지, ArgoCD UI 딥링크(`{{.context.argocdUrl}}/applications/...`)를 조립하고, 이모지(✅/❌/⚠️)로 Discord에서 상태를 한눈에 구분하게 했다. `webhook.discord` 키가 위 서비스 정의 이름과 일치해야 매칭된다.
- **`subscriptions` (L95–102)** — 트리거와 수신처의 전역 연결. `recipients: [discord]`(서비스 이름), `triggers:` 3종 전부. 전역 subscription이므로 개별 Application에 어노테이션을 달 필요 없이 모든 앱의 이벤트가 Discord로 간다 — 앱이 몇 개 안 되는 이 프로젝트 규모에 맞는 단순화다.

## discord-notifications/providers.tf (34줄)

### L1–12 · terraform { required_providers }

`aws ~> 6.0`(EKS data 조회용), `kubernetes ~> 2.35`(Secret/ConfigMap 생성용). 이 루트는 `required_version`을 따로 안 박았지만 backend의 `use_lockfile` 때문에 실질 하한은 역시 1.10이다.

### L14–17 · provider "aws"

`region`/`profile` — persistent와 같은 workload-admin 규약.

### L22–24 · data "aws_eks_cluster" "this"

`name = var.cluster_name`으로 클러스터의 엔드포인트·CA 인증서를 조회한다. L19–21 주석이 설계 의도를 밝힌다: `../terraform` state를 전혀 참조하지 않고 **클러스터 이름 하나로** 접속 정보를 독립 구성한다(state 완전 분리 → 이 루트의 apply/destroy가 메인에 무영향). 부수 효과로 이 조회 자체가 전제조건 검사가 된다 — 클러스터가 없으면(daily-down 이후 등) plan이 여기서 명확하게 실패한다.

### L26–28 · data "aws_eks_cluster_auth" "this"

클러스터 인증 토큰 발급. IAM 자격증명으로 서명된 **단기(약 15분) 토큰**이라 kubeconfig 파일 없이, 장기 자격증명 없이 접속한다. 대신 plan~apply가 길어지면 토큰이 만료될 수 있다는 것이 이 방식의 알려진 트레이드오프인데, 이 루트는 리소스 2개뿐이라 문제가 되지 않는다.

### L30–34 · provider "kubernetes"

위 두 data 소스를 조립한다 — `host`(엔드포인트), `cluster_ca_certificate`(`base64decode`로 디코딩한 CA), `token`(단기 토큰). exec 플러그인 방식 대신 data 소스 방식을 쓴 단순한 구성으로, kubectl·aws-iam-authenticator 로컬 설치에 의존하지 않는다.

## discord-notifications/variables.tf (22줄)

### L1–5 · variable "aws_profile"

기본값 `workload-admin` — `../terraform/variables.tf`와 동일 값 사용을 description으로 명시.

### L7–10 · variable "region"

기본값 `ap-northeast-2`.

### L12–16 · variable "cluster_name"

기본값 `gochuchamchi-eks`. description이 운영 순서를 문서화한다 — "이미 떠 있어야 하는" 클러스터이며 `../terraform`을 먼저 apply한 뒤 이 모듈을 적용한다. 일일 계층 코드가 클러스터 이름을 바꾸면 이 기본값도 함께 바꿔야 하는 암묵적 결합점이다.

### L18–22 · variable "discord_webhook_url"

- `sensitive = true` — plan/apply 출력에서 값이 마스킹된다.
- 기본값이 **없다** — 값 없이는 plan이 멈추므로 주입을 강제한다. description대로 `TF_VAR_discord_webhook_url` 환경변수로 주입하고 **git 커밋 금지**다. Discord 웹훅 URL은 URL 자체가 인증 토큰이라(아는 사람은 누구나 채널에 POST 가능) 시크릿으로 취급한다. 앞서 notifications.tf에서 언급했듯 sensitive는 출력 마스킹일 뿐 tfstate 저장까지 막지는 못한다는 점을 함께 기억할 것.

---

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| persistent/account-guard.tf | 12 | 2 | 전체 |
| persistent/backend.tf | 16 | 1 | 전체 |
| persistent/cloudfront-logs.tf | 204 | 10 | 전체 |
| persistent/ecr.tf | 175 | 6 | 전체 |
| persistent/image-signing.tf | 113 | 5 | 전체 |
| persistent/kms-data.tf | 38 | 3 | 전체 |
| persistent/outputs.tf | 29 | 5 | 전체 |
| persistent/providers.tf | 26 | 3 | 전체 |
| persistent/secrets.tf | 56 | 3 | 전체 |
| persistent/variables.tf | 33 | 5 | 전체 |
| persistent/waf-blocklist.tf | 47 | 3 | 전체 |
| discord-notifications/account-guard.tf | 12 | 2 | 전체 |
| discord-notifications/backend.tf | 15 | 1 | 전체 |
| discord-notifications/notifications.tf | 104 | 2 | 전체 |
| discord-notifications/providers.tf | 34 | 5 | 전체 |
| discord-notifications/variables.tf | 22 | 4 | 전체 |


---

# cloudwatch-notifications — 알림 허브·자동 대응 (Workload 상시)

이 루트는 Workload 계정(828885965304)의 **알림 허브이자 자동 대응(SOAR) 계층**이다. 프로젝트 전체 구조에서 management(조직·SSO) / log-archive(로그 중앙 수집·SIEM) / account-baseline(상시 보안) / persistent(상시 자원) / terraform(런타임, 매일 daily-up/down으로 생성·파괴)과 나란히 서는 **상시 계층**으로, daily-down이 절대 손대지 않는다. 여기를 `terraform destroy` 하면 SNS 허브·격리 Lambda·IAM 감시·트리아지까지 40여 개 리소스가 한 번에 사라지므로 **destroy 금지 구역**이다. 상태 파일도 자체 backend(`cloudwatch-notifications/terraform.tfstate`)로 분리돼 있어 런타임 루트의 destroy와 물리적으로 격리된다.

통보 데이터 흐름의 뼈대는 "**모든 알림 소스 → 서울 default 이벤트 버스 → EventBridge 룰 → SNS 허브(`gochuchamchi-alerts`) → 구독자(Discord Lambda + 이메일)**"이다. 이 프로젝트의 CloudWatch 알람에는 `alarm_actions`가 하나도 없는 것이 정상인데, 알람이 SNS를 직접 가리키는 대신 EventBridge가 `CloudWatch Alarm State Change` 이벤트를 **알람 이름 접두사 `gochuchamchi-`**로 잡아 허브로 넘기기 때문이다(eventbridge.tf). 덕분에 알람을 만드는 쪽(런타임 루트, persistent 등)은 이 루트의 토픽 ARN을 몰라도 되고, 계층 간 교차 참조가 0이 된다. us-east-1에만 존재하는 알람(WAF/CloudFront 등)과 글로벌 서비스 이벤트(IAM·콘솔 로그인)는 `../terraform` 쪽 us-east-1 relay 규칙이 서울 버스로 중계해 주고, 이 루트는 서울에서 그것을 받기만 한다. 이 설계의 진짜 위험은 반대편에 있다 — **접두사 규약을 안 지킨 알람은 어떤 에러도 없이 조용히 통보에서 빠진다.**

통보와 별개로 **대응 경로**가 있다. GuardDuty High 이상 finding, Security Hub finding(스위치), Log 계정 SIEM의 urgent 판정(크로스계정)은 SNS를 거치지 않고 격리 Lambda `gochuchamchi-guardduty-isolation`으로 직결된다 — 통보 채널(Discord Webhook 등)의 장애가 격리 실행을 막으면 안 되기 때문이다. 격리 Lambda는 EC2 ENI의 SG 교체·IAM 액세스키 비활성화·WAF IP 차단·파드 NetworkPolicy 등 대응 8종을 환경변수 스위치로 게이트하고, 이력을 DynamoDB에 남긴다. 마지막으로 triage.tf는 GuardDuty 통보 경로에 LLM 1차 판정을 끼워 넣는 실험 기능인데, 현재 `enable_triage=false`로 **배선만 끊겨 있고 기계는 남아 있다**(의도된 설계). 운영 주의 한 가지 — 이 루트를 plan/apply 할 때는 `TF_VAR_alert_emails=["where5683@naver.com"]` 주입이 필수다. 빠뜨리면 이메일 구독을 삭제하는 plan이 뜬다.

## cloudwatch-notifications/providers.tf (18줄)

이 루트가 요구하는 프로바이더 버전과 기본 AWS 연결 설정을 선언한다. 파일이 짧은 이유는 이 루트가 단일 리전(서울)·단일 계정만 다루기 때문이다 — us-east-1 쪽 relay 규칙은 `../terraform`에 있으므로 여기엔 alias 프로바이더조차 필요 없다.

### L1–13 · terraform { required_providers }

`aws`는 `hashicorp/aws` `~> 6.0` — 메이저 6에 고정하고 마이너/패치만 자동 승격을 허용하는 pessimistic constraint다. 메이저 업그레이드는 리소스 스키마가 깨질 수 있어 사람이 명시적으로 올리게 막는다. `archive`는 `hashicorp/archive` `~> 2.0` — lambda.tf·guardduty-response.tf·triage.tf의 `data "archive_file"`(Python 소스 → zip)을 위해 필요하다. 이 프로바이더 덕에 별도 빌드 파이프라인 없이 `terraform apply`만으로 Lambda 배포 패키지가 만들어진다.

### L15–18 · provider "aws"

`region = var.region`(기본 ap-northeast-2), `profile = var.aws_profile`(기본 workload-admin). 하드코딩하지 않고 변수로 뺀 것은 `../terraform/variables.tf`와 값을 맞추기 위해서다. profile 방식은 SSO 로그인(`aws sso login`) 세션을 그대로 태우는 이 프로젝트의 표준 인증 경로다. 잘못된 profile로 실행하는 사고는 account-guard.tf의 precondition이 plan 단계에서 잡는다.

## cloudwatch-notifications/backend.tf (15줄)

상태 파일 저장 위치를 선언한다. 이 루트의 state는 런타임 루트와 같은 버킷을 쓰되 key로 분리된다 — 그래서 런타임 루트의 daily destroy가 이 루트의 state를 건드릴 방법이 없다.

### L2–15 · terraform { backend "s3" }

- `bucket = "gochuchamchi-tfstate-828885965304"` — 계정 ID를 이름에 넣어 전역 유일성을 확보한 tfstate 전용 버킷. Workload 계정 소유다.
- `key = "cloudwatch-notifications/terraform.tfstate"` — 루트별 디렉터리형 key. 루트 하나 = state 하나 원칙.
- `region`/`profile` — backend 접근용 설정. backend 블록은 변수를 못 쓰므로(초기화가 변수 평가보다 먼저다) 여기만은 리터럴 하드코딩이 불가피하다.
- `encrypt = true` + `use_lockfile = true` — 파일 상단 주석대로 **Terraform 1.10+의 S3 네이티브 잠금**이다. 예전 방식인 DynamoDB 잠금 테이블 없이, state 옆에 `.tflock` 오브젝트를 조건부 PUT 해서 동시 apply를 막는다. 학생 프로젝트에서 잠금 테이블 하나를 통째로 아끼는 선택.
- `kms_key_id = "arn:aws:kms:...:alias/gochuchamchi-tfstate"` — (2026-08-13) 핵심 함정을 막는 줄이다. `encrypt = true`만 두면 Terraform이 PUT 요청에 **AES256(SSE-S3)을 명시적으로 실어 보내** 버킷의 기본 암호화(SSE-KMS)를 오브젝트 단위로 덮어써 버린다. KMS 키를 명시해야 state 오브젝트가 실제로 CMK로 암호화된다. 같은 이유의 상세 주석이 `../terraform/backend.tf`에 있다.

## cloudwatch-notifications/account-guard.tf (10줄)

"이 루트는 Workload 계정에서만 실행된다"를 코드로 강제하는 안전장치다. SSO 프로필을 3계정에서 번갈아 쓰는 이 프로젝트에서, management-admin 프로필로 이 루트를 apply 하는 사고를 plan 단계에서 차단한다.

### L1–10 · resource "terraform_data" "account_guard"

`terraform_data`는 아무 인프라도 만들지 않는 순수 state 내 리소스다. 실제 일은 `lifecycle.precondition`이 한다 — `data.aws_caller_identity.current.account_id == "828885965304"`(Workload 계정)가 아니면 plan이 한국어 에러 메시지와 함께 즉시 실패한다. precondition은 리소스에 붙어야만 평가되므로 이 껍데기 리소스가 필요한 것이다. `input = data.aws_caller_identity.current.account_id`는 호출자 계정이 바뀌면 이 리소스가 replace 되도록 해 두는 것인데, 어차피 그 전에 precondition이 막으므로 실질적으로는 "이 리소스가 caller identity에 의존한다"는 그래프 연결 역할이다. 참조하는 `data.aws_caller_identity.current`는 drift-detection.tf L26에 정의돼 있다 — 같은 모듈 안이라 파일 경계는 의미가 없다.

## cloudwatch-notifications/variables.tf (26줄)

루트 공통 변수 3개. GuardDuty·트리아지 관련 변수는 각각 guardduty-response.tf·triage.tf에 기능과 함께 두는 스타일이라, 여기엔 연결 설정과 이메일만 남아 있다.

### L1–5 · variable "region"

기본값 `ap-northeast-2`. 프로바이더 리전이자 격리 Lambda IAM 정책의 ARN 조립(`arn:aws:ec2:${var.region}:...`)에도 쓰인다. 리전을 변수로 뺀 덕에 정책 ARN들이 리전 하드코딩 없이 따라온다.

### L7–11 · variable "aws_profile"

기본값 `workload-admin`. 주석대로 `../terraform/variables.tf`와 동일 값을 쓰는 것이 규약이다 — 루트마다 프로필 이름이 다르면 사람이 헷갈린다.

### L17–26 · variable "alert_emails"

SNS 허브를 구독할 이메일 목록. **기본값이 빈 목록**이고 개인 이메일을 코드에 하드코딩하지 않는다(2026-08-04 하드코딩 리뷰 원칙) — 공개 저장소에 이메일이 남는 것을 막고, 사람이 바뀌어도 코드 수정이 없다. 주입은 `$env:TF_VAR_alert_emails = '["..."]'`(PowerShell). `validation` 블록은 각 항목이 이메일 형식(`^[^@\s]+@[^@\s]+\.[^@\s]+$`)인지 `alltrue` + `can(regex(...))`로 검사한다 — 오타가 apply까지 가서 확인 메일이 허공으로 가는 것을 plan에서 막는다. **운영 함정**: 이 변수는 default가 `[]`라서, 주입을 잊고 plan 하면 기존 이메일 구독을 **삭제하는 plan**이 정상처럼 뜬다. 이 루트를 만질 때 환경변수 주입이 체크리스트 1번인 이유다. 빈 목록이면 Discord만 동작하는데, 그러면 sns.tf의 DLQ 자기 감시 루프의 최종 수신자가 없어진다(Discord가 죽었을 때 그 사실을 알려줄 채널이 Discord뿐인 모순).

## cloudwatch-notifications/secrets.tf (6줄)

Discord Webhook 시크릿을 **조회만** 한다. 이 루트에서 시크릿을 다루는 원칙이 이 여섯 줄에 요약돼 있다 — 값은 Terraform이 절대 만지지 않는다.

### L4–6 · data "aws_secretsmanager_secret" "discord_webhook"

`name = "gochuchamchi/discord/cloudwatch-webhook"`으로 기존 시크릿의 **메타데이터(ARN)만** 읽는다. `aws_secretsmanager_secret_version`(값 조회)이 아니라는 점이 핵심이다 — 값을 data로 읽으면 tfstate에 웹훅 URL 평문이 남는다. 대신 ARN만 Lambda 환경변수로 넘기고, 실제 URL은 Lambda가 런타임에 `GetSecretValue`로 가져온다(lambda.tf의 IAM 정책이 그 권한). 시크릿 자체(그릇과 값)는 이 루트 밖에서 수동 생성·주입된 것이라, 이 루트를 destroy 해도 웹훅 값은 살아남는다. triage.tf의 Groq 키 시크릿은 같은 원칙의 변형(그릇은 Terraform, 값은 수동)이다.

## cloudwatch-notifications/sns.tf (174줄)

이 루트의 심장인 SNS 알림 허브와 그 신뢰성 장치(DLQ·자기 감시 알람)를 정의한다. 도입 배경(2026-08-04, 파일 상단 주석): 기존 EventBridge → Lambda 직결 구조는 ① 채널 추가마다 Lambda 코드를 고쳐야 했고(팬아웃 불가) ② Lambda가 실패하면 알림이 흔적 없이 사라졌다(유실). SNS를 사이에 끼우면서 "채널 추가 = 구독 추가"가 됐고, 실패분은 재시도 후 DLQ에 남는다. KMS 암호화를 안 한 이유도 주석에 있다 — EventBridge는 기본 관리형 키(`aws/sns`)로 암호화된 토픽에 발행할 수 없어(그 키 정책은 수정 불가) CMK가 필요한데, CMK는 월 $1 + 키 정책 관리 비용이 따라온다. 이 토픽에 흐르는 것은 알람 이름/상태 같은 비밀 아닌 데이터뿐이라 학습 단계에선 미암호화, 운영 전환 시 CMK 세트 도입으로 미뤘다.

### L16–22 · resource "aws_sns_topic" "alerts"

토픽 `gochuchamchi-alerts` 하나가 이 프로젝트 전체의 알림 팬아웃 지점이다. 인자가 name과 tags뿐인 것이 오히려 설계다 — FIFO도, KMS도, delivery policy 커스텀도 없는 표준 토픽. 모든 신규 알림 소스는 "이 토픽으로 발행"이 규약이고, 그 사실이 L171 output의 description에 명문화돼 있다.

### L27–54 · resource "aws_sns_topic_policy" "alerts"

토픽 리소스 정책으로 **발행자를 최소권한으로 제한**한다. `Principal`을 서비스 전체(`events.amazonaws.com`)로 열되, `Condition.ArnEquals."aws:SourceArn"`으로 "우리 룰 3개에서 온 발행만" 허용한다 — 같은 계정의 다른 EventBridge 룰이 이 토픽으로 아무거나 쏘는 것을 막는 것이다. 허용 목록은 `cloudwatch_alarm_state_change`(알람 상태), `guardduty_finding`(GuardDuty 통보), `iam_activity_forwarded`(IAM 활동) 세 룰의 ARN. L41 주석대로 신규 알림 소스는 이 목록에 추가하는 것이 규약이고, 격리 Lambda의 결과 발행은 이 정책이 아니라 **Lambda 실행 역할의 IAM `sns:Publish`**로 허용된다 — 같은 계정 안에서는 IAM 정책과 리소스 정책의 합집합으로 평가되기 때문에 리소스 정책에 Lambda 역할을 또 적을 필요가 없다.

**함정(검증 필요)**: drift-detection.tf의 세 룰(console_mutation·iam_mutation·root_activity)도 이 토픽을 타겟으로 하는데, 이 SourceArn 허용 목록에 **없다**. `ArnEquals` 목록에 없는 룰의 발행은 AccessDenied로 실패하고, EventBridge는 타겟 실패를 기본으로는 어디에도 알리지 않는다 — 즉 코드만 보면 드리프트 감지 알림이 SNS에 도달하지 못하는 상태일 수 있다. 콘솔에서 무해한 변경(태그 하나 추가 등)을 내 보고 Discord/이메일 도착을 확인하거나, 룰의 FailedInvocations 지표를 확인해 볼 가치가 있다. 도달한다면 실환경 정책이 코드와 다르게 갱신돼 있다는 뜻이니 그것대로 드리프트다.

### L60–70 · resource "aws_sns_topic_subscription" "discord_lambda"

구독 1: `protocol = "lambda"`, `endpoint`는 Discord 전송 Lambda ARN. 기존 EventBridge → Lambda 직결 파이프라인을 SNS 뒤로 옮긴 것이다. `redrive_policy`가 이 구독의 존재 이유의 절반이다 — SNS의 Lambda 재시도(3회)까지 전부 실패한 메시지를 `alerts_dlq`로 보낸다. 주석 그대로, 이게 없으면 Discord 장애 시 알림이 흔적 없이 유실된다.

### L73–81 · resource "aws_lambda_permission" "allow_sns"

SNS가 Discord Lambda를 호출할 수 있게 하는 리소스 기반 권한. `principal = "sns.amazonaws.com"` + `source_arn`을 우리 토픽으로 좁혀, 다른 토픽이 이 Lambda를 호출하는 것을 막는다. eventbridge.tf L47 주석이 말하는 "Lambda 호출 권한은 EventBridge가 아니라 SNS가 가짐"이 바로 이 블록이다 — 직결 시절의 EventBridge용 permission을 대체했다.

### L95–101 · resource "aws_sns_topic_subscription" "email"

구독 2: `for_each = toset(var.alert_emails)`로 이메일 목록을 구독 리소스로 펼친다. count가 아닌 for_each인 이유 — 이메일 하나를 빼도 나머지 구독이 재생성되지 않는다(주소 자체가 key). 주석의 두 가지 운영 특성이 중요하다. ① apply 후 각 수신자가 확인 메일의 "Confirm subscription"을 눌러야 활성화되고, PendingConfirmation 상태로 3일이 지나면 만료된다. ② PendingConfirmation 구독은 API로 삭제가 불가능해서 destroy 시 state에서만 제거되고 실제로는 3일 후 자동 소멸한다 — 에러가 아니라 정상 동작이다. 코드 0줄로 채널 하나(이메일)를 확보하는 SNS 기본 기능이며, Discord가 죽었을 때의 최후 통보 경로다.

### L113–122 · resource "aws_sqs_queue" "alerts_dlq"

Discord 전달 최종 실패분이 쌓이는 DLQ. `message_retention_seconds = 1209600`(14일, SQS 최대치)로 잡은 이유는 주석대로 원인 조사 시간을 벌기 위해서다 — 기본 4일이면 주말 끼고 놓치면 증거가 사라진다. triage.tf의 Lambda `dead_letter_config`도 이 큐를 재사용한다(실패 경로를 한 곳에 모은다).

### L124–144 · resource "aws_sqs_queue_policy" "alerts_dlq"

SNS 서비스가 이 큐에 `sqs:SendMessage` 할 수 있게 하는 큐 정책. 토픽 정책과 같은 패턴으로 `Condition.ArnEquals."aws:SourceArn"`을 우리 토픽 ARN으로 좁혔다 — 아무 토픽이나 이 큐를 쓰레기통으로 쓰지 못한다.

### L147–169 · resource "aws_cloudwatch_metric_alarm" "alerts_dlq_messages"

**자기 감시 루프의 핵심**. DLQ에 메시지가 1개라도 보이면(`AWS/SQS`의 `ApproximateNumberOfMessagesVisible`, `Maximum`, 300초 1회 평가, `>= 1`) ALARM으로 넘어간다. 알람 이름이 `gochuchamchi-alerts-dlq-has-messages`로 **`gochuchamchi-` 접두사를 지키는 것이 기능 요건**이다(L146 주석) — 그래야 eventbridge.tf의 prefix 룰이 이 알람의 상태 변경을 잡아 같은 SNS 토픽으로 발행하고, Discord Lambda가 여전히 죽어 있어도 이메일 구독자에게는 SNS가 직접 전달한다. 즉 "알림 파이프라인 자체의 고장"을 파이프라인의 살아 있는 절반으로 통보하는 구조다. `treat_missing_data = "notBreaching"`은 SQS의 특성 대응이다 — 메시지가 0이면 지표 자체가 안 찍히므로, 미수신을 정상으로 간주하지 않으면 알람이 INSUFFICIENT_DATA를 오간다. `alarm_actions`가 없는 것도 이 프로젝트에선 정상이다(EventBridge prefix 룰이 대신한다).

### L171–174 · output "alerts_topic_arn"

허브 토픽 ARN을 노출한다. 다른 루트가 remote state로 참조하기 위한 것이라기보다(이 프로젝트는 계층 간 참조를 피한다), description에 적힌 대로 "신규 알림 소스는 이 토픽으로"라는 운영 규약의 문서화에 가깝다.

## cloudwatch-notifications/lambda.tf (125줄)

SNS 허브의 구독자인 Discord 전송 Lambda(`gochuchamchi-cloudwatch-discord`)와 그 실행 역할을 정의한다. 이 Lambda의 역할은 단순하다 — SNS 메시지를 받아 사람이 읽을 Discord 임베드로 바꿔 Webhook으로 쏜다. 채널 추가가 "구독 추가"가 된 대신, 이 Lambda는 Discord 전담으로 좁아졌다.

### L5–9 · data "archive_file" "cloudwatch_discord"

`lambda_function.py` 한 파일을 zip으로 만든다. `source_file`(단일 파일) 방식이라 `__pycache__` 같은 부산물이 섞일 여지가 없다. `output_path`는 모듈 디렉터리 안 — zip은 빌드 산출물이라 커밋 대상이 아니다.

### L16–29 · data "aws_iam_policy_document" "lambda_assume_role"

`lambda.amazonaws.com` 서비스가 `sts:AssumeRole` 할 수 있게 하는 표준 신뢰 정책. 이 문서는 이 파일의 Discord 역할뿐 아니라 guardduty-response.tf의 격리 역할(L491), triage.tf의 트리아지 역할(L376)까지 **세 곳에서 재사용**된다 — 동일 서비스 principal의 신뢰 정책을 세 번 복붙하지 않기 위한 공용 data 소스다.

### L36–46 · resource "aws_iam_role" "cloudwatch_discord"

Discord Lambda 전용 실행 역할. 함수마다 역할을 따로 두는 것이 이 루트의 일관된 패턴이다(격리 Lambda·트리아지 Lambda도 각자 역할) — 한 역할에 권한을 몰아넣으면 어떤 함수가 어떤 권한을 실제로 쓰는지 추적이 불가능해진다.

### L53–59 · resource "aws_iam_role_policy_attachment" "lambda_basic_execution"

AWS 관리형 `AWSLambdaBasicExecutionRole`(CloudWatch Logs 쓰기)을 부착한다. 로그 없는 Lambda는 디버깅이 불가능하므로 모든 함수의 기본값이다.

### L66–79 · data "aws_iam_policy_document" "read_discord_secret"

`secretsmanager:GetSecretValue`를 **정확히 웹훅 시크릿 ARN 하나**로 좁힌 최소권한 정책. 이 Lambda가 탈취돼도 다른 시크릿(Groq 키 등)은 못 읽는다.

### L81–86 · resource "aws_iam_role_policy" "read_discord_secret"

위 문서를 인라인 정책으로 역할에 부착한다. 관리형 정책이 아닌 인라인인 이유 — 이 정책은 이 역할 밖에서 재사용될 일이 없고, 역할과 생애주기를 같이 한다.

### L93–125 · resource "aws_lambda_function" "cloudwatch_discord"

- `handler = "lambda_function.lambda_handler"`, `runtime = "python3.12"` — 표준 라이브러리만 쓰는 단일 파일 함수라 레이어가 없다.
- `filename` + `source_code_hash = data.archive_file...output_base64sha256` — 소스 파일이 바뀌면 해시가 바뀌어 재배포가 트리거된다. 해시가 없으면 py를 고쳐도 apply가 "변경 없음"으로 지나간다.
- `timeout = 15` — Discord Webhook HTTP 호출 하나에 충분한 값. SNS → Lambda는 비동기 호출이라 타임아웃이 길 필요가 없고, 길면 장애 시 재시도 간격만 늘어진다. `memory_size = 128` — 최소값, JSON 가공에 충분.
- `environment.DISCORD_SECRET_ARN` — secrets.tf에서 읽은 **ARN만** 주입한다. 웹훅 URL 자체는 환경변수에도, state에도 없다. Lambda가 콜드스타트 때 GetSecretValue로 가져온다.
- `depends_on`으로 basic execution 부착과 시크릿 읽기 정책을 명시 — 함수가 먼저 생성돼 첫 호출이 권한 오류로 죽는 경쟁 상태를 막는다.

이 함수 하나가 알람 상태 변경 JSON, GuardDuty finding JSON, IAM 활동의 input_transformer 문자열까지 **형태가 다른 메시지를 전부** 받는다는 점을 기억해야 한다. drift-detection.tf L140 주석이 "input_transformer를 쓰면 Lambda의 json.loads가 터진다"고 경고하는 이유이자, iam-activity.tf가 그럼에도 transformer를 쓰는 것과의 긴장 지점이다(해당 파일 해설 참고).

## cloudwatch-notifications/eventbridge.tf (57줄)

`alarm_actions` 없는 알람 설계를 성립시키는 파일이다. CloudWatch가 발행하는 `CloudWatch Alarm State Change` 이벤트를 접두사로 잡아 SNS 허브로 넘긴다.

### L5–42 · resource "aws_cloudwatch_event_rule" "cloudwatch_alarm_state_change"

이벤트 패턴 해부:

- `source = ["aws.cloudwatch"]` — CloudWatch 서비스가 발행한 이벤트만.
- `detail-type = ["CloudWatch Alarm State Change"]` — 알람 상태 전이 이벤트만. 이 이벤트는 알람에 액션이 있든 없든 상태가 바뀌면 무조건 발행된다는 점이 이 설계의 근거다.
- `detail.alarmName = [{ prefix = "gochuchamchi-" }]` — **이 한 줄이 프로젝트 전체의 알람 통보 규약**이다. 어느 루트가 알람을 만들든 이름만 접두사를 지키면 자동으로 통보에 편입된다. 알람 쪽에서 SNS ARN을 참조할 필요가 없으니 상시 계층 ↔ 런타임 계층 간 참조가 생기지 않고, us-east-1 알람도 relay로 서울 버스에 도착하기만 하면 같은 룰에 걸린다(relay는 source/detail-type/detail을 보존한다). 대가는 "규약 위반의 침묵" — 접두사 없는 알람은 아무 데도 걸리지 않고, 그 사실을 알려주는 것도 없다.
- `detail.state.value = ["ALARM", "OK"]` — 발동과 복구만 통보한다. `INSUFFICIENT_DATA`를 뺀 것은 소음 통제다 — 일일 재구축 환경에서는 리소스가 매일 사라지며 INSUFFICIENT_DATA 전이가 대량 발생한다. OK를 포함한 것은 "복구됐다"는 정보가 대응 종료 판단에 필요하기 때문이다.

`state = "ENABLED"`를 명시한 것은 기본값이지만, 이 룰이 꺼지면 알람 통보 전체가 죽는 만큼 의도를 코드에 박아 둔 것이다.

### L52–57 · resource "aws_cloudwatch_event_target" "alerts_sns"

룰의 타겟을 SNS 허브로 연결한다. L45 주석이 이력의 요점이다 — (2026-08-04) 기존 Lambda 직결에서 SNS 경유로 전환하면서, Lambda 호출 권한은 SNS가(sns.tf의 `allow_sns`), EventBridge → SNS 발행 권한은 토픽 정책(sns.tf의 `aws_sns_topic_policy.alerts`)이 담당하는 구조로 권한이 재배치됐다. target 리소스 자체에는 권한이 없다는 것 — EventBridge target은 "배선"일 뿐이고 권한은 항상 수신 측 리소스 정책이 쥔다는 것이 이 두 줄이 가르치는 내용이다.

## cloudwatch-notifications/drift-detection.tf (164줄)

"Terraform 밖에서 인프라가 바뀐 순간"을 실시간으로 잡는 파일이다(2026-08-04 자동화 3/3). 파일 헤더 주석이 이 설계의 트레이드오프를 정직하게 적어 놨다 — 드리프트 감지의 정석은 "하루 1회 `terraform plan -detailed-exitcode` → 종료코드 2면 알림"인데, 이 스택은 kubernetes/helm 프로바이더를 쓰고 EKS 퍼블릭 엔드포인트가 /32 허용목록으로 잠겨 있어 GitHub 호스티드 러너에서는 plan이 refresh 단계에서 타임아웃 난다. 즉 plan 방식은 self-hosted runner(배스천) 결정이 선행돼야 하고, 이 파일은 **그 결정 없이 지금 당장 얻을 수 있는 신호를 먼저 확보하는 쪽**이다. plan 방식은 모든 드리프트를 잡지만 러너 인프라가 필요하고 최대 1일 늦는다. 이 이벤트 방식은 사람이 콘솔로 만진 변경을 즉시·비용 0으로 잡지만 **CLI/SDK로 낸 수동 변경은 못 잡는다** — 둘은 대체재가 아니라 보완재고, 러너가 생기면 plan 룰을 추가로 붙인다는 계획까지 주석에 있다. 전제 조건도 명시돼 있다: EventBridge의 `AWS API Call via CloudTrail` 이벤트는 CloudTrail이 관리 이벤트를 기록 중일 때만 발행된다(`../terraform/cloudtrail.tf`). 비용은 사실상 0이다 — AWS 서비스가 발행하는 이벤트는 EventBridge 무과금이고 SNS 발행분만 미미하게 과금된다. 한 가지 교차 참조: 이 파일의 세 룰은 sns.tf 토픽 정책의 SourceArn 허용 목록에 빠져 있다(sns.tf 해설의 "함정(검증 필요)" 참고).

### L26 · data "aws_caller_identity" "current"

현재 자격증명(계정 ID·ARN)을 조회하는 빈 블록 data 소스. 이 모듈에서 소비자가 셋이다 — ① account-guard.tf의 precondition(계정 ID 비교), ② 아래 iam_mutation 룰의 `anything-but` 제외 대상(호출자 ARN), ③ guardduty-response.tf IAM 정책들의 ARN 조립(`arn:aws:ec2:${var.region}:${account_id}:...`). 파일상 위치가 drift-detection.tf인 것은 우연에 가깝다 — Terraform은 모듈 단위로 파일을 합쳐 평가하므로 어디 있든 동작은 같지만, "이 data를 지우면 세 파일이 깨진다"는 건 알고 있어야 한다.

### L39–75 · resource "aws_cloudwatch_event_rule" "console_mutation"

룰 1: **콘솔에서 사람이 직접 수행한 모든 인프라 변경**을 잡는다. 이름 `gochuchamchi-console-mutation`, description은 한국어로 의도를 명시. 이벤트 패턴 해부:

- `detail-type = ["AWS API Call via CloudTrail"]` — CloudTrail이 기록한 관리 API 호출이 EventBridge로 흘러들어온 이벤트만. `source`보다 이걸 먼저 이해해야 한다 — 이 이벤트는 CloudTrail이 꺼지면 함께 사라진다(헤더 주석의 전제).
- `source = [...12개]` — `aws.ec2`, `aws.eks`, `aws.rds`, `aws.elasticache`, `aws.elasticloadbalancing`, `aws.s3`, `aws.iam`, `aws.secretsmanager`, `aws.kms`, `aws.route53`, `aws.logs`, `aws.autoscaling`. 주석대로 "이 프로젝트가 Terraform으로 관리하는 서비스만" 감시하는 화이트리스트다. `aws.logs`/`aws.autoscaling`은 ALB controller·ExternalDNS 같은 컨트롤러가 자동으로 만지는 서비스지만, 아래 콘솔 조건이 이미 사람만 남기므로 포함해도 소음이 안 생긴다는 판단까지 주석에 있다.
- `detail.readOnly = [false]` — 조회성 호출(Describe*/List*/Get*)을 배제한다. CloudTrail은 `readOnly`를 불리언으로 기록하므로 패턴도 불리언 `false`다. 주석대로 이게 없으면 콘솔 화면 한 번 여는 것만으로 수십 건이 발행된다 — 콘솔 UI는 화면 렌더링을 위해 Describe를 무더기로 호출하기 때문이다.
- `detail.sessionCredentialFromConsole = ["true"]` — **이 룰의 핵심 한 줄**이다. CloudTrail이 "이 API 호출은 콘솔 세션 자격증명으로 이뤄졌다"고 표시하는 필드로, 사람이 브라우저에서 클릭한 변경에만 붙는다. 여기는 불리언이 아니라 **문자열 `"true"`**인 점을 눈여겨봐야 한다 — CloudTrail이 이 필드를 문자열로 기록하기 때문에 패턴도 문자열로 맞춘 것이고, `[true]`로 쓰면 영원히 안 걸린다. EventBridge 매칭은 "필드가 존재하고 값이 일치"할 때만 성립하므로, 이 필드 자체가 없는 Terraform/CLI/SDK/컨트롤러 호출은 **자동으로 걸러진다**. 별도 제외 목록 없이 "사람의 콘솔 변경"만 남기는 우아한 필터인데, 뒤집으면 이 파일의 한계 그 자체다 — 훔친 액세스키로 CLI에서 낸 변경은 이 필드가 없어 룰 1을 그냥 통과한다(그건 룰 2와 GuardDuty의 몫).

`state = "ENABLED"` 명시와 Name 태그는 eventbridge.tf의 룰과 같은 관례다.

### L88–109 · resource "aws_cloudwatch_event_rule" "iam_mutation"

룰 2: **Terraform 실행 주체를 제외한 누구든** IAM을 변경하면 잡는다. IAM은 콘솔이든 CLI든 "권한 경계가 바뀌는" 최고 위험 변경이라 룰 1(콘솔 한정)과 별도로 전 채널을 본다는 것이 주석의 논리다. 패턴 해부:

- `detail-type` + `source = ["aws.iam"]` — CloudTrail 경유 IAM API 호출만.
- `detail.readOnly = [false]` — 변경 호출만. 룰 1과 같은 소음 통제.
- `detail.userIdentity.arn = [{ "anything-but" = data.aws_caller_identity.current.arn }]` — EventBridge의 부정 매칭 연산자로 **plan/apply 시점의 호출자 ARN**을 제외한다. 이게 없으면 apply마다 IAM 변경 수십 건이 전부 울린다.

여기엔 문서화된 것보다 깊은 함정이 있다. `data.aws_caller_identity.current.arn`은 SSO 환경에서 `arn:aws:sts::828885965304:assumed-role/AWSReservedSSO_...권한세트.../사용자명` 형태의 **세션 ARN**이고, 이 값이 apply 시점에 룰 패턴 안에 **리터럴로 구워진다**. 즉 이 룰이 실제로 제외하는 것은 "Terraform"이 아니라 "**마지막으로 이 루트를 apply한 사람의 SSO 세션 주체**"다. 다른 팀원이 apply 하면 룰 내용이 그 사람 ARN으로 바뀌는 in-place 변경이 plan에 뜨고(정상이다), 반대로 A가 apply 해 둔 상태에서 B가 런타임 루트를 apply 하면 B의 IAM 변경은 전부 알림으로 쏟아진다. 주석의 ⚠도 같은 맥락이다 — 나중에 CI(OIDC 역할)에서 apply 하게 되면 `arn = [{ "anything-but" = [A, B] }]`처럼 목록으로 바꿔 그 역할 ARN을 추가해야 한다. 또 하나: IAM은 글로벌 서비스라 CloudTrail 이벤트가 us-east-1에서 발행되므로, 서울 버스의 이 룰에는 `../terraform`의 us-east-1 relay가 중계해 준 이벤트가 걸린다(iam-activity.tf 헤더 주석 참고). 그래서 relay 대상 이벤트는 이 룰과 iam-activity.tf의 `iam_activity_forwarded` **둘 다에 매칭될 수 있고**(EventBridge는 룰마다 독립 평가) 같은 변경이 두 번 통보될 수 있다 — 소음이지 결함은 아니지만, 알림이 두 건 오는 이유를 물으면 이렇게 답하면 된다.

### L118–137 · resource "aws_cloudwatch_event_rule" "root_activity"

룰 3: **루트 계정 사용**. 주석의 논리가 명확하다 — 루트는 MFA 강제 그룹(`../terraform/iam-security.tf`)으로도 통제할 수 없는 유일한 주체이므로, 정상 운영에서 쓰일 일이 없고 "쓰였다는 사실 자체가 신호"다. 패턴 해부:

- `detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]` — API 호출뿐 아니라 **콘솔 로그인 이벤트까지** 잡는다. 루트는 로그인 자체가 사건이다.
- `detail.userIdentity.type = ["Root"]` — CloudTrail의 주체 유형 필드. 루트 자격증명으로 이뤄진 모든 호출에 붙는다.
- 앞의 두 룰과 달리 `source` 필터도 `readOnly` 필터도 **없다**. 의도적이다 — 루트가 어느 서비스를 만지든, 심지어 로그인 후 둘러보기만(읽기 전용 호출) 해도 알아야 할 사건이라는 것(주석 명시). 소음 걱정이 없는 이유는 조건 자체의 희귀성이다 — Root 이벤트는 정상 상태에서 0건이어야 한다.

이 룰도 글로벌 이벤트(us-east-1 발행)는 relay를 타야 서울에 도착하며, 도착한 Root 이벤트는 iam-activity.tf 룰의 첫 번째 `$or` 갈래와도 겹친다(중복 통보 가능 — 위 룰 2와 같은 성질). 루트 사용은 서울 리전 API 호출로도 네이티브로 잡힐 수 있어(iam-activity.tf 주석), 이 룰은 relay 없이도 부분적으로 동작한다.

### L148–152 · resource "aws_cloudwatch_event_target" "console_mutation_sns"

룰 1을 SNS 허브에 배선한다. `target_id = "SendConsoleMutationToSnsHub"`는 룰 내 타겟 식별자(같은 룰에 타겟을 여럿 달 때 구분용)일 뿐 권한과 무관하다. L140–146 주석이 세 타겟 공통의 설계 결정을 설명한다 — **input_transformer를 쓰지 않는다**. 사람이 읽기 좋은 문자열로 변환하면 이메일은 예뻐지지만, 같은 토픽을 구독하는 Discord Lambda가 받는 Message가 "JSON이 아닌 문자열"이 되어 `json.loads`에서 터지고, 그 실패가 SNS 재시도 → DLQ 적재로 이어진다. 그래서 원본 CloudTrail JSON을 그대로 보내고 사람용 가공은 Lambda(lambda_function.py)가 담당하며, 이메일 구독자는 원본 JSON을 받는 것을 감수한다 — 알림의 1차 목적이 "발생 사실 통보"이기 때문. iam-activity.tf가 정확히 반대 선택을 한 것과 비교해서 읽어야 한다(그쪽 해설 참고).

### L154–158 · resource "aws_cloudwatch_event_target" "iam_mutation_sns"

룰 2 → SNS 허브. `target_id = "SendIamMutationToSnsHub"`. 구조는 위와 동일하고, 발행 권한은 sns.tf 토픽 정책의 몫이다 — 그리고 바로 그 지점이 앞서 지적한 함정(이 룰의 ARN이 허용 목록에 없음)이다.

### L160–164 · resource "aws_cloudwatch_event_target" "root_activity_sns"

룰 3 → SNS 허브. `target_id = "SendRootActivityToSnsHub"`. 세 타겟 모두 `arn = aws_sns_topic.alerts.arn` 한 줄이 배선의 전부라는 것 — EventBridge target은 권한을 갖지 않는 순수 배선이라는 eventbridge.tf의 교훈이 여기서도 반복된다.

## cloudwatch-notifications/iam-activity.tf (74줄)

us-east-1에서 전달된 **루트 사용·IAM 변경·콘솔 로그인 실패** 이벤트를 서울에서 받아 SNS 허브로 발행하는 파일이다(2026-08-12). 헤더 주석이 구조를 요약한다 — 짝 파일 `../terraform/iam-activity-monitoring.tf`가 us-east-1에서 이벤트를 잡아 서울 default 버스로 relay 하고, 이 파일은 서울에서 그걸 받는다. relay 시 source/detail-type/detail이 보존되므로 **아래 패턴은 ../terraform 쪽과 동일하게 유지해야 한다** — 둘이 어긋나면 이벤트가 어떤 에러도 없이 조용히 안 잡힌다(접두사 규약과 같은 종류의 침묵 실패). 왜 이런 우회가 필요한가에 대한 배경 두 가지: ① IAM·콘솔 로그인은 글로벌 서비스라 CloudTrail 이벤트가 us-east-1에서만 발행된다 — 서울 버스에 이 detail-type이 보인다면 us-east-1 포워더가 보낸 것뿐이다(단 루트 사용은 서울에서도 네이티브로 잡힐 수 있어 패턴을 동일하게 좁혀 오탐을 막는다). ② 정석인 "CloudTrail → CloudWatch Logs → metric filter" 경로를 못 쓴다 — 이 프로젝트의 org trail은 S3 전용이라 CloudWatch Logs로 흐르지 않기 때문에, 같은 신호를 EventBridge 이벤트에서 뽑는 것이다.

### L15–44 · resource "aws_cloudwatch_event_rule" "iam_activity_forwarded"

이름 `gochuchamchi-iam-activity-forwarded`. 최상위에 `source` 필터가 없다는 것부터 특이한데, 세 갈래의 출처가 제각각이라(`aws.iam`/`aws.signin`) detail 내부의 `eventSource`로 대신 좁힌 것이다. 패턴 해부 — `detail-type = ["AWS API Call via CloudTrail", "AWS Console Sign In via CloudTrail"]` 아래 `detail.$or`로 세 갈래를 병렬로 건다:

- **갈래 1 — 루트 사용**: `userIdentity.type = ["Root"]`. drift-detection.tf 룰 3과 같은 조건이다(중복 매칭 가능성은 그쪽 해설 참고).
- **갈래 2 — IAM 변경**: `eventSource = ["iam.amazonaws.com"]` + `eventName`을 **변경 동사 접두사 10종**으로 필터한다 — `Create`/`Delete`/`Update`/`Put`/`Attach`/`Detach`/`Add`/`Remove`/`Tag`/`Untag`. IAM의 쓰기 API 이름이 대부분 이 동사들로 시작한다는 사실(CreateUser, DeletePolicy, UpdateAssumeRolePolicy, PutUserPolicy, AttachRolePolicy, AddUserToGroup…)을 이용한 화이트리스트다. drift-detection.tf의 iam_mutation이 `readOnly = [false]`라는 의미 기반 필터를 쓴 것과 달리 여기는 이름 기반인데, 이름 기반의 함정은 **목록에 없는 동사는 침묵**한다는 것이다 — 실제로 `DeactivateMFADevice`, `ChangePassword`, `SetDefaultPolicyVersion`, `EnableMFADevice`, `UploadServerCertificate`는 이 접두사들에 안 걸린다. MFA 비활성화나 비밀번호 변경은 공격자의 전형적 행동인데 이 갈래가 놓친다는 뜻이다(콘솔로 했다면 console_mutation이, readOnly 기준인 iam_mutation이 잡아 주는 것이 그나마의 보완). 발표에서 "이 목록의 커버리지 한계를 안다"고 말할 수 있는 지점이다.
- **갈래 3 — 콘솔 로그인 실패**: `eventSource = ["signin.amazonaws.com"]` + `eventName = ["ConsoleLogin"]` + `responseElements.ConsoleLogin = ["Failure"]`. CloudTrail은 로그인 시도의 결과를 `responseElements`에 남기므로 응답 필드로 성패를 거른다. **실패만** 잡는 것이 소음 통제다 — 성공 로그인은 매일 발생하는 정상 이벤트고, 연속 실패야말로 크리덴셜 스터핑/무차별 대입의 신호다.

`state` 인자가 없어 기본값 ENABLED로 동작한다(eventbridge.tf가 굳이 명시한 것과 대조되는 부분 — 동작은 같다).

### L46–74 · resource "aws_cloudwatch_event_target" "iam_activity_sns"

룰을 SNS 허브로 배선하되, 이 루트에서 **유일하게 input_transformer를 쓰는** 타겟이다. 주석의 근거는 멘토 지적이다 — CloudTrail 원문(그리고 GuardDuty JSON)은 필드가 너무 많아 알림으로는 그대로 못 본다. 구조 해부:

- `input_paths` — 이벤트에서 8개 필드를 JSONPath로 뽑아 이름을 붙인다: `account`(`$.detail.userIdentity.accountId`), `actor`(주체 ARN), `type`(주체 유형 — Root/IAMUser/AssumedRole), `eventName`, `source`(eventSource), `sourceIp`, `time`, `region`. 알림을 받고 "누가·무엇을·어디서·언제"에 즉답하기 위한 최소 집합이다.
- `input_template` — 뽑은 값을 `<placeholder>` 문법으로 끼워 넣은 사람용 본문. **각 줄이 큰따옴표로 감싸여 있는 것**은 장식이 아니라 EventBridge의 멀티라인 템플릿 규약이다 — 여러 개의 따옴표 문자열을 나열하면 EventBridge가 이어 붙여 개행 있는 하나의 문자열로 만든다. 마지막 줄의 "→ 예상한 변경인지 확인하세요…"는 알림에 대응 지침을 실어 보내는 이 프로젝트의 습관(triage 알람 description과 같은 패턴)이다.

**긴장 지점** — drift-detection.tf L140 주석은 "transformer를 쓰면 Lambda의 json.loads가 터진다"며 원본 JSON을 고집했는데, 이 파일은 정반대를 선택했다. 결과적으로 SNS 허브에는 JSON 메시지(알람·GuardDuty·드리프트)와 **평문 문자열 메시지(IAM 활동)가 섞여 흐르고**, Discord Lambda(lambda_function.py)는 json.loads 실패 시 원문을 그대로 전달하는 방어 분기를 가져야만 이 설계가 성립한다. 여기서 그 대가를 지불하고도 transformer를 쓴 이유는 IAM 활동 알림의 소비자가 사실상 이메일이기 때문 — "발생 사실 + 행위자"만 즉시 읽히면 되고, 원문이 필요하면 CloudTrail(S3/SIEM)에 있다. 같은 SNS를 구독하는 Discord Lambda도 이 문자열을 받는다는 주석(L64)은 이 트레이드오프를 인지하고 있다는 기록이다.

## cloudwatch-notifications/log-account-eventbridge.tf (14줄)

이 루트에서 가장 짧지만 **유일한 크로스계정 이음새**인 파일이다. Log 계정(564186750363)이 Workload 계정의 default 이벤트 버스로 이벤트를 밀어 넣을 수 있게 허용한다. 헤더 주석의 시나리오는 Firehose 헬스 알람이다 — Log 계정의 SIEM 파이프라인(Firehose)에 붙은 CloudWatch 알람이 상태를 바꾸면, Log 계정 쪽 EventBridge 룰이 그 이벤트를 이 버스로 크로스계정 전송하고, 도착한 이벤트는 **이미 있는 prefix 룰**(eventbridge.tf의 `gochuchamchi-*` 알람 룰)에 걸려 SNS → Discord로 흐른다. 즉 이 파일은 수신 측 허가만 열 뿐, 라우팅은 기존 규약이 그대로 처리한다 — 알람 이름 접두사 규약이 계정 경계까지 넘어 동작하는 순간이다.

### L9–14 · resource "aws_cloudwatch_event_permission" "allow_log_account_firehose_alarm_events"

`aws_cloudwatch_event_permission`은 이벤트 버스의 **리소스 기반 정책**을 Terraform 리소스로 표현한 것이다(SNS 토픽 정책·Lambda permission과 같은 계열). 인자 해부:

- `statement_id = "AllowLogAccountFirehoseAlarmEvents"` — 버스 정책 내 statement 식별자. 다른 계정을 추가로 허용하게 되면 statement가 옆에 나란히 쌓인다.
- `action = "events:PutEvents"` — 허용하는 유일한 행위. 버스에 이벤트를 넣는 것뿐, 룰·타겟 조작은 불가능하다.
- `principal = "564186750363"` — Log 계정 **전체**를 계정 단위로 허용한다. 특정 역할 ARN이 아니라 계정 ID인 점, 그리고 이벤트 내용에 대한 조건이 없는 점이 눈에 띄는데, guardduty-response.tf L444 주석이 이를 명시적으로 인정한다("이벤트 종류 무관"). 넓어 보이지만 위험 평가가 뒤에 있다 — 버스에 이벤트를 넣는 것 자체는 아무 효과가 없고, **여기 룰에 걸려야만** 뭔가가 일어난다. 패턴에 안 걸리는 이벤트는 버스에서 그냥 증발한다. 실질 위험은 위장 이벤트다: Log 계정이 침해되면 가짜 `gochuchamchi-*` 알람 이벤트(소음·양치기 효과)나 가짜 SIEM 대응 요청(`source: gochuchamchi.siem` — guardduty-response.tf의 siem_response 룰이 격리 Lambda로 라우팅)을 보낼 수 있다. 후자의 완화가 이중 게이트다 — SIEM 요청은 WAF 차단으로만 처리되고 그마저 `waf_response_enabled`(기본 false)가 잠근다.
- `event_bus_name = "default"` — 이 프로젝트는 커스텀 버스 없이 default 버스 하나로 모든 룰을 돌리므로 명시적이지만 사실상 유일한 선택지다.

이 permission이 열어 주는 트래픽은 현재 두 종류다: ① Firehose 헬스 알람(→ prefix 룰 → SNS), ② SIEM detector의 urgent 대응 요청(→ siem_response 룰 → 격리 Lambda). 파일 이름과 주석은 ①만 말하고 있으니, ②가 추가된 2026-08-13 이후로는 주석이 반쯤 낡았다는 것도 알아 두면 좋다 — 허가 자체는 이벤트 종류 무관이라 코드는 고칠 필요가 없었다.

## cloudwatch-notifications/guardduty-response.tf (843줄)

GuardDuty 탐지를 **통보**(SNS 허브)와 **자동 대응**(격리 Lambda)의 두 경로로 나눠 처리하는, 이 루트에서 가장 큰 파일이다(2026-08-07 도입, 이후 세 차례 확장). 헤더 주석이 "왜 account-baseline이 아니라 이 state인가"를 세 가지로 못 박는다 — ① 이 파일의 EventBridge 룰은 `source: aws.guardduty` 이벤트 패턴만 쓰므로 detector 리소스를 참조할 필요가 없다(계층 교차 참조 0), ② account-baseline은 removed+import 마이그레이션 중이라 "첫 plan이 import만 있어야" 검증이 되는데 새 리소스를 넣으면 판정이 흐려진다, ③ SNS 허브·Discord Lambda가 이미 여기 있어 배선이 가장 짧다. 두 번째 설계 원칙은 격리 대상과의 관계다 — 격리 대상(EKS 노드/EC2)은 매일 destroy되는 main 계층에 있지만, 이 Lambda는 Terraform 참조가 아니라 "finding에 적힌 인스턴스 ID"로 런타임에 API를 때리므로 한 방향 참조 원칙(terraform/ → 상시 계층)을 깨지 않는다. 검역 SG도 같은 이유로 Terraform이 아니라 **Lambda가 대상 VPC 안에 즉석 생성**한다 — VPC가 매일 죽었다 살아나 ARN을 배포 시점에 알 수 없기 때문이다. 격리 Lambda `gochuchamchi-guardduty-isolation`의 진입점은 넷이다: ① GuardDuty/Security Hub/SIEM finding(이벤트 기반 격리·대응), ② `{"action":"recover"}` 수동 호출(오격리 원상복구 — 격리 시 ENI 태그 `gochuchamchi:pre-quarantine-sgs`에 기록해 둔 원본 SG를 복원), ③ `{"action":"audit"}` 매시간 스케줄(미복구 감시), ④ 모든 행위의 이력은 DynamoDB `gochuchamchi-isolation-history`에 남는다. **자동 복구는 없다** — 오탐 판단은 사람의 몫이고, AssumedRole/Root 자격증명 finding도 자동 대응 없이 manual-required로 처리된다(SSO 계정이라 AssumedRole이 흔한 환경 특성). 대응 8종은 전부 변수 스위치로 게이트되며 위험한 것일수록 기본값이 드라이런(false)이다.

### L18–22 · variable "guardduty_notify_min_severity"

통보 룰 (B) 갈래의 severity 하한. 기본 4 — GuardDuty 스케일에서 4.0~6.9가 Medium, 7.0~8.9가 High다. 이 숫자 하나만으로 통보를 걸렀던 것이 과거 설계였고, 그 한계가 아래 Rule 1의 개편 사유가 됐다(실측: 중요한 finding이 전부 severity 2였다).

### L24–28 · variable "guardduty_isolate_min_severity"

자동 격리 발동 하한. 기본 7(High 이상). Rule 2의 이벤트 패턴에 들어가는 동시에 Lambda 환경변수 `MIN_SEVERITY`로도 주입된다 — EventBridge가 한 번 거르고 Lambda가 다시 확인하는 이중 검증이라, 누가 Lambda를 직접 호출해도 낮은 severity finding으로 격리를 유발할 수 없다.

### L30–34 · variable "isolation_enabled"

자동 격리의 총괄 스위치. 기본 true. false면 Lambda가 통보만 하고 SG 교체를 하지 않는 **드라이런**이 된다 — 오탐 검증 기간에 "격리했을 것이다"라는 알림만 보며 판단 품질을 관찰하는 용도다. 다른 대응 스위치들과 달리 이것만 기본 true인 것은 EC2 격리가 가장 오래 검증된 원조 기능이기 때문이다.

### L36–43 · variable "protected_instance_tag_keys"

자동 격리에서 제외할 인스턴스 태그 키(또는 접두사) 목록. 기본값 `eks:cluster-name`, `kubernetes.io/cluster/` — **EKS 워커 노드 제외**다. 워커를 격리하면 그 위의 파드 전부가 죽어 서비스 전체 영향이 되므로, description대로 P1 수동 대응으로 전환한다. 접두사 매칭(`kubernetes.io/cluster/` 뒤에 클러스터명이 붙는다)까지 지원하는 것은 Lambda 쪽 구현이다.

### L49–53 · variable "credential_response_enabled"

탈취 의심 IAM 액세스키 자동 비활성화 스위치(2026-08-12 확장분). 기본 true. false면 통보만 하는 드라이런.

### L55–65 · variable "protected_access_key_ids"

자동 비활성화에서 제외할 액세스키 ID 목록 — "최후의 안전장치". description의 논리가 이 변수의 백미다: **비워 두는 것이 기본**인 이유는 GuardDuty 자격증명 finding이 "비정상 사용"을 탐지한 것이라 정상 사용 중인 키는 애초에 탐지되지 않기 때문이고, 여기에 키를 넣으면 그 키가 실제로 탈취돼도 자동 대응이 안 되므로 **넣는 순간 그 위험을 감수하는 것**이라고 명시한다. 이 계정의 유일한 정적 키 주체(terra-user — SSO가 아닌 IAM 사용자)까지 기록해 뒀다.

### L67–71 · variable "quarantine_stale_hours"

격리 후 이 시간이 지나도록 복구/정리되지 않으면 audit 경로가 재통보하는 임계값. 기본 12시간 — 일일 재구축 환경에서는 어떤 리소스도 24시간을 넘겨 살아 있지 않으므로, 격리 상태가 반나절을 넘기면 "사람이 잊었다"는 신호로 본다.

### L73–77 · variable "isolation_history_retention_days"

이력 테이블의 TTL 보존 일수. 기본 90일. DynamoDB TTL로 자동 삭제되므로 비용이 무한히 늘지 않는다 — Lambda가 항목을 쓸 때 `expiresAt`을 이 값으로 계산해 넣는다.

### L83–87 · variable "waf_response_enabled"

네트워크 기반 finding의 원격 IP를 WAF 차단 목록에 자동 추가할지(2026-08-13 확장분). **기본 false(드라이런)** — 관찰 후 켠다. 격리·키 대응과 독립적인 부가 대응이라고 description이 선을 긋는다.

### L89–93 · variable "waf_blocklist_ip_set_name"

격리 Lambda가 IP를 넣고 빼는 WAF IP set의 **이름**. 기본 `gochuchamchi-guardduty-blocklist`. 이 IP set은 `../persistent` 소유이고 CLOUDFRONT scope(us-east-1)다 — ARN이 아니라 이름으로 받는 이유는 계층 교차 참조를 피하기 위해서고, Lambda가 런타임에 `ListIPSets`로 이름을 ID로 해석한다. 비우면 Lambda가 WAF 대응 자체를 건너뛴다.

### L95–99 · variable "waf_block_ttl_hours"

WAF 자동 차단 IP의 유효 시간. 기본 24시간. **WAF IP set에는 TTL 기능이 없어** 코드로 해제해야 하는데, 그 청소를 매시간 도는 audit 경로가 맡는다 — DynamoDB에 IP별 만료 시각을 남겨 두고(아래 IAM 정책의 GetItem/DeleteItem), 만료분을 IP set에서 뺀다.

### L101–105 · variable "protected_response_ips"

WAF 자동 차단 제외 IP(관리자 IP 등). 기본 빈 목록. 사설/내부 IP는 코드가 자동 제외하므로 여기엔 공인 IP만 넣는다는 description — 자기 자신(관리자)을 엣지에서 차단하는 최악의 자충수를 막는 변수다.

### L111–115 · variable "pod_response_enabled"

EKS 런타임 finding의 대상 파드에 deny-all NetworkPolicy를 자동 적용할지(2026-08-13). 기본 false. 실행 방식이 특이하다 — Lambda가 EKS API에 직접 붙는 게 아니라 **배스천을 SSM으로 시켜 kubectl을 돌린다**(gochuchamchi 네임스페이스 한정). 그 권한 설계는 아래 IAM 정책의 SSM statement 3개에 있다.

### L121–131 · variable "securityhub_response_enabled"

Security Hub HIGH/CRITICAL finding(GuardDuty 제품 제외)을 격리 Lambda로 보낼지. 기본 false — description이 이 스택의 토글 패턴 하나를 정의한다: **리소스(EventBridge 규칙)는 두고 배선(state)만 끈다**. 그리고 이것은 '입력원' 스위치일 뿐, 실제 격리 실행은 여전히 isolation_enabled 등 개별 대응 스위치가 게이트하는 **이중 게이트** 구조다. GuardDuty는 이미 직접 경로로 처리되므로 Lambda가 ProductName=GuardDuty를 걸러 이중 대응을 막는다는 것까지 명시돼 있다.

### L137–141 · variable "iam_subject_response_enabled"

탈취 의심 IAM 주체(역할/사용자)에 deny-all 정책을 자동 부착할지(추가 대응 4종 중 ①). 기본 false. **키 비활성화가 못 잡는 AssumedRole/SSO 세션**에 대한 대응이다 — 액세스키가 없는 주체는 UpdateAccessKey로 막을 수 없으니 주체 자체에 deny를 씌운다. 정상 역할에 붙으면 서비스가 마비되므로 protected_iam_principals를 반드시 채우고 켜야 한다는 경고가 description에 있다.

### L143–147 · variable "protected_iam_principals"

IAM 주체 격리에서 제외할 역할/사용자 이름 목록(파드 역할·CI 역할·운영자 등 절대 막으면 안 되는 것). 기본 빈 목록 — iam_subject_response_enabled를 켤 때 반드시 채운다는 짝 규약이다. protected_access_key_ids와 달리 이쪽은 "비워 두는 게 기본"이 아니다 — deny-all 정책 부착은 키 비활성화보다 파급이 크기 때문이다.

### L149–153 · variable "s3_response_enabled"

S3 대상 finding 시 버킷에 PublicAccessBlock을 자동 강제할지(②). 기본 false. "퍼블릭 차단은 보수적이라 상대적으로 안전하다"는 description — 잘못 발동해도 버킷이 비공개가 될 뿐 데이터 유실이 없다는 위험 평가다.

### L155–159 · variable "sg_response_enabled"

격리 시 원본 SG의 0.0.0.0/0 위험 인그레스(민감 포트/광범위 개방)를 자동 제거할지(③). 기본 false. 대상을 좁혔지만 정상 규칙 오제거 위험이 있어 관찰 후 켠다 — 격리(SG 교체)가 인스턴스 단위 대응이라면 이것은 침해의 원인이 된 구멍 자체를 막는 SG 단위 대응이다.

### L161–165 · variable "snapshot_on_isolate_enabled"

EC2 격리 시 EBS 볼륨 포렌식 스냅샷을 자동으로 뜰지(④). 기본 false. 읽기 전용이라 안전하고 비용만 소폭 든다 — 격리된 인스턴스가 다음 daily-down에 사라져도 디스크 증거가 남는다는 점에서, 이력 테이블(메타데이터)과 짝을 이루는 데이터 차원의 증거 보존이다.

### L180–215 · resource "aws_dynamodb_table" "isolation_history"

격리/복구 이력 저장소(2026-08-12). 도입 배경 주석이 명확하다 — 그전까지 격리 결과는 SNS로 흘러가고 사라졌고, 인스턴스 포렌식 태그만 남는데 인스턴스가 destroy되면 그것도 없어진다. "언제 무엇을 왜 격리/복구했는가"가 안 남으면 사후 조사도, 제로트러스트가 요구하는 행위 감사도 불가능하다. DynamoDB를 고른 이유도 주석에 있다 — 조회가 쉽고(대상별/시간별), TTL로 자동 정리되고, on-demand 과금이라 격리 이벤트처럼 드문 쓰기량에선 사실상 무료다. S3는 append 조회가 번거롭고 Athena를 또 붙여야 한다. 인자 해부:

- `billing_mode = "PAY_PER_REQUEST"` — 프로비저닝 용량 없이 쓴 만큼만. 드문 쓰기에 최적.
- `hash_key = "targetId"` / `range_key = "eventTime"` — 파티션 키가 대상 리소스(인스턴스 ID 또는 액세스키 ID)인 것은 "이 자원에 무슨 일이 있었나"가 가장 흔한 조회이기 때문이고(주석), 정렬 키가 시각이라 Query 한 번으로 대상별 시간순 이력이 나온다. `attribute` 블록 둘은 키로 쓰는 속성만 선언한다 — DynamoDB는 스키마리스라 키 외 속성은 선언하지 않는다.
- `ttl { attribute_name = "expiresAt" }` — isolation_history_retention_days(90일)가 여기로 구현된다. TTL 속성 이름만 테이블이 정하고 값 계산은 Lambda 몫이다.
- `point_in_time_recovery { enabled = true }` — 감사 증적은 실수로 지워지면 안 되는 데이터라 PITR을 켰다. triage.tf의 상태 테이블이 PITR을 끈 것(유실돼도 알림 한 번 더 올 뿐)과 대조적인, 데이터 성격에 따른 선택이다.
- `server_side_encryption { enabled = true }` — AWS 관리형 키. 주석대로 이력에 비밀값은 안 들어가므로 CMK까지는 불필요.

### L226–235 · resource "aws_cloudwatch_event_rule" "quarantine_audit"

미복구 격리 감시 스케줄(2026-08-12). `schedule_expression = "rate(1 hour)"` — 이벤트 패턴이 아니라 시간 기반 룰이다. 격리해 두고 사람이 잊으면 노드가 계속 죽어 있으므로, 매시간 Lambda를 audit 모드로 깨워 "격리된 지 quarantine_stale_hours를 넘긴 대상"을 재통보한다. 별도 Lambda를 만들지 않고 같은 함수의 action 분기를 쓰는 이유가 주석에 있다 — 격리/복구/감사가 같은 태그·같은 이력 테이블을 다루므로 **로직이 한 곳에 있어야 어긋나지 않는다**.

### L237–244 · resource "aws_cloudwatch_event_target" "quarantine_audit_lambda"

스케줄 룰 → 격리 Lambda 배선. 핵심은 `input = jsonencode({ action = "audit" })` — EventBridge가 이벤트 원문 대신 이 고정 JSON을 Lambda에 넘긴다. 주석대로 이것이 격리 경로(GuardDuty finding 원문이 들어옴)와 audit 경로를 구분하는 **유일한 신호**다. 수동 복구(`{"action":"recover"}`)도 같은 분기 체계를 쓰지만 그쪽은 EventBridge가 아니라 사람이 `aws lambda invoke`로 직접 호출한다 — Terraform에 리소스가 없는 진입점이다.

### L246–253 · resource "aws_lambda_permission" "allow_eventbridge_audit"

EventBridge가 격리 Lambda를 호출할 수 있게 하는 리소스 기반 권한, audit 룰 전용. `source_arn = aws_cloudwatch_event_rule.quarantine_audit.arn`으로 **이 스케줄 룰에서 온 호출만** 허용한다. 이 파일에는 같은 모양의 permission이 넷 있다(audit/isolation/securityhub/siem) — 룰마다 statement를 따로 쌓아 어떤 경로의 권한인지 추적 가능하게 하는 패턴이다.

### L276–290 · variable "guardduty_always_notify_type_prefixes"

Rule 1 (A) 갈래의 "severity 무관 항상 통보" 타입 접두사 목록. 9개 각각에 인라인 주석이 붙어 있다 — `Policy:IAMUser/Root`(루트 자격증명 사용), `Policy:S3/`(퍼블릭 차단 해제 등 버킷 정책 완화), `CredentialAccess:`(자격증명 탈취 시도), `Exfiltration:`(데이터 반출), `Backdoor:`(C2/백도어), `Trojan:`(트로이목마), `CryptoCurrency:`(암호화폐 채굴 — 피침해 EC2의 전형적 증상), `Impact:`(랜섬/변조 등 파괴적 영향), `PenTest:`(침투도구 사용). 공통점은 **낮은 severity로 와도 놓치면 안 되는, 의미가 확정적인 타입**이라는 것. GuardDuty 타입 이름이 `위협단계:리소스/세부유형` 구조라 접두사 매칭이 카테고리 매칭으로 동작한다. 이 목록은 triage.tf에도 `ALWAYS_NOTIFY_PREFIXES`로 재사용된다 — EventBridge 필터와 트리아지 티어 승격이 같은 정의를 공유해야 어긋나지 않기 때문이다.

### L292–301 · variable "guardduty_notify_noise_types"

Rule 1 (B) 갈래에서 Medium 이상이어도 통보하지 않을 소음 타입 4개 — 접두사가 아니라 **정확한 전체 이름**이다(`Recon:EC2/PortProbeUnprotectedPort`, `Recon:EC2/PortProbeEMRUnprotectedPort`, `UnauthorizedAccess:EC2/SSHBruteForce`, `UnauthorizedAccess:EC2/RDPBruteForce`). 전체 이름인 이유는 제외는 넓게 걸수록 위험하기 때문 — `Recon:` 전체를 빼면 진짜 정찰 신호까지 사라진다. 이 4개가 소음인 근거는 환경 실측이다: 공인 IP에는 포트 스캔·무차별 대입이 항상 쏟아지는 인터넷 배경소음이고, 이 프로젝트의 배스천은 SSH/RDP 인바운드가 0개(SSM 접속)라 무차별 대입은 성공 자체가 불가능한 순수 노이즈다.

### L303–331 · resource "aws_cloudwatch_event_rule" "guardduty_finding"

**Rule 1: 통보 — 타입 기반 필터(2026-08-12 개편)**. 개편 배경이 이 파일에서 가장 중요한 실측 스토리다: 기존엔 severity>=4만 통보했는데, 실제 finding을 보니 전부 severity 2였고 그중 `Policy:IAMUser/RootCredentialUsage`(루트 자격증명 사용)가 있었다 — **가장 중요한 신호가 숫자가 낮아 통보에서 누락**되고 있었다. 반대로 Medium 이상에 섞여 오는 PortProbe/BruteForce는 순수 소음이었다. 멘토 조언대로 "심각도 숫자"가 아니라 "타입(필드)"으로 의미를 판단하도록 바꾼 것이 이 패턴이다. 해부:

- `source = ["aws.guardduty"]` + `detail-type = ["GuardDuty Finding"]` — GuardDuty가 EventBridge로 발행하는 finding 이벤트만.
- `detail.$or` — 두 갈래의 논리합:
  - **(A) 항상 통보**: `type = [for p in var.guardduty_always_notify_type_prefixes : { prefix = p }]`. Terraform for 표현식이 접두사 목록을 `[{prefix="Policy:IAMUser/Root"}, {prefix="Policy:S3/"}, ...]` 형태로 펼친다 — EventBridge 패턴에서 같은 필드의 배열 원소들은 OR로 평가되므로 "이 접두사들 중 하나라도 맞으면"이 된다. severity 조건이 아예 없다.
  - **(B) 그 외**: `severity = [{ numeric = [">=", var.guardduty_notify_min_severity] }]`(수치 비교 연산자 — 문자열 비교가 아니라 숫자 비교) AND `type = [{ "anything-but" = var.guardduty_notify_noise_types }]`(소음 타입 정확 일치 제외). 같은 객체 안의 필드들은 AND다.

임계값·목록이 전부 변수라 **운영 중 tfvars 조정만으로 필터가 바뀐다** — 코드 배포 없는 튜닝이 이 개편의 부수 수확이다.

### L337–343 · resource "aws_cloudwatch_event_target" "guardduty_sns"

Rule 1 → SNS 허브 배선인데 `count = var.enable_triage ? 0 : 1`이 붙어 있다. 트리아지가 켜지면 finding은 트리아지 Lambda로 가고(triage.tf의 target이 1이 됨) 이 SNS 직결은 사라진다 — **둘 중 하나만 존재**한다. 주석이 이 블록의 존재 이유를 "롤백 경로"라고 명시한다: `enable_triage=false` 한 번으로 트리아지 도입 전 동작으로 정확히 되돌아가고, 전환 중에도 알림이 끊기는 구간이 없다. 현재 enable_triage 기본값이 false이므로 **지금 살아 있는 배선은 이쪽**이다.

### L352–372 · resource "aws_cloudwatch_event_rule" "guardduty_finding_critical"

**Rule 2: 대응 — severity >= 7(High 이상) → 격리 Lambda 직결**. 패턴은 `severity = [{ numeric = [">=", var.guardduty_isolate_min_severity] }]` 하나뿐 — 통보 룰과 달리 타입 필터가 없다. 대응 발동 조건은 단순·보수적으로 유지하고(High면 무조건 Lambda가 본다), 타입별 세부 판단(EC2인가 자격증명인가, 보호 대상인가)은 Lambda 코드가 한다는 역할 분담이다. SNS를 거치지 않는 이유가 헤더 주석에 있다 — 대응 경로는 팬아웃이 필요 없고, **통보 경로의 장애(예: Discord Webhook 문제로 DLQ 적재)가 격리 실행을 막으면 안 된다**. 신뢰성은 EventBridge 자체가 보장한다: Lambda 호출 실패를 최대 24시간 자체 재시도한다.

### L374–378 · resource "aws_cloudwatch_event_target" "guardduty_isolation_lambda"

Rule 2 → 격리 Lambda 배선. `input` 가공 없이 finding 원문 전체를 넘긴다 — Lambda가 severity·타입·리소스 정보를 직접 파싱해야 하기 때문이다(audit 타겟이 고정 JSON을 넘기는 것과 대조).

### L380–390 · resource "aws_lambda_permission" "allow_eventbridge_isolation"

Rule 2 전용 호출 권한. 주석이 원칙을 재확인한다 — `source_arn`을 이 룰로 좁혀 **같은 계정의 다른 룰/주체가 격리를 트리거하는 것을 차단**한다(sns.tf의 SourceArn 조건과 같은 원칙). 격리는 실질적 파괴력이 있는 행위라 호출 경로 통제가 통보보다 중요하다.

### L404–427 · resource "aws_cloudwatch_event_rule" "securityhub_finding"

**입력원 2: Security Hub HIGH/CRITICAL finding → 격리 Lambda**(2026-08-13). GuardDuty 외 소스(Inspector·Config 등)의 finding을 대응에 편입한다. 패턴 해부 — `detail.findings`는 Security Hub 이벤트에서 배열인데, EventBridge는 배열의 **원소 각각에 대해** 패턴을 평가하므로 객체처럼 쓰면 된다:

- `Severity.Label = ["HIGH", "CRITICAL"]` — GuardDuty의 숫자 severity와 달리 Security Hub는 정규화된 라벨을 쓴다.
- `Workflow.Status = ["NEW"]` — 이미 사람이 잡은(NOTIFIED/RESOLVED) finding의 재발행을 걸러 재대응을 막는다.
- `RecordState = ["ACTIVE"]` — 보관 처리(ARCHIVED)된 finding 제외.
- `ProductName = [{ "anything-but" = ["GuardDuty"] }]` — **이중 트리거 방지의 핵심**. GuardDuty finding은 Security Hub에도 수입되는데, 이미 Rule 2 직접 경로가 처리하므로 여기서 제외하지 않으면 같은 침해에 대응이 두 번 발동한다.

`state = var.securityhub_response_enabled ? "ENABLED" : "DISABLED"` — 이 스택의 두 번째 토글 방식이다. 트리아지가 count로 리소스 존재 자체를 게이트하는 것과 달리, 여기는 **룰 리소스를 항상 두고 state 속성만 바꾼다**(주석: "껐다 켜는 데 IAM 전파 대기가 없다"). 현재 기본 false라 룰은 DISABLED로 존재한다.

### L429–433 · resource "aws_cloudwatch_event_target" "securityhub_isolation_lambda"

Security Hub 룰 → 격리 Lambda 배선. 룰이 DISABLED여도 target과 permission은 남아 있다 — state 토글 방식의 특징으로, 변수 하나 바꾸면 룰만 ENABLED로 바뀌는 최소 diff가 된다.

### L435–441 · resource "aws_lambda_permission" "allow_eventbridge_securityhub"

Security Hub 룰 전용 호출 권한. source_arn 패턴 동일.

### L451–465 · resource "aws_cloudwatch_event_rule" "siem_response"

**입력원 3: Log 계정 SIEM detector의 urgent 판정 → 격리 Lambda**(2026-08-13, 크로스계정). 패턴이 이 파일에서 유일하게 AWS 서비스가 아닌 **커스텀 이벤트**를 잡는다 — `source = ["gochuchamchi.siem"]`(Log 계정의 SIEM detector가 PutEvents 할 때 붙이는 자체 네임스페이스), `detail-type = ["SIEM Response Request"]`. Log 계정이 이 버스에 put 할 수 있는 권한은 log-account-eventbridge.tf의 event_permission이 이미 계정 단위로 부여했으므로(주석: "이벤트 종류 무관"), 이 룰은 라우팅만 한다. 대응 범위도 주석에 못 박혀 있다 — Lambda는 SIEM 요청의 `sourceIps`를 **WAF 24시간 차단으로만** 처리하고, 실제 차단은 `waf_response_enabled`가 게이트한다(Log 쪽 스위치와 **이중**). 크로스계정 입력이 EC2 격리나 키 비활성화 같은 강한 대응을 직접 일으킬 수 없게 반경을 제한한 설계다.

### L467–471 · resource "aws_cloudwatch_event_target" "siem_response_isolation"

SIEM 룰 → 격리 Lambda 배선. 이 룰은 state 게이트 없이 항상 ENABLED다 — 실행 게이트(waf_response_enabled, 기본 false)가 Lambda 안에 있으므로 배선 자체는 열어 둬도 드라이런이다.

### L473–479 · resource "aws_lambda_permission" "allow_eventbridge_siem_response"

SIEM 룰 전용 호출 권한. 여기까지 해서 격리 Lambda의 EventBridge 호출 경로는 정확히 4개 룰(critical/audit/securityhub/siem)로 명세된다 — permission의 source_arn 목록이 곧 이 Lambda의 공격 표면 문서다.

### L481–485 · data "archive_file" "guardduty_isolation"

`isolation_function.py` 단일 파일을 zip으로 패키징. lambda.tf의 Discord 함수와 같은 `source_file` 방식이다. 대응 8종을 담은 함수치고 파일 하나인 것은 표준 라이브러리(boto3 포함, Lambda 런타임 내장)만 쓰기 때문이다.

### L487–496 · resource "aws_iam_role" "guardduty_isolation"

격리 Lambda 전용 실행 역할 `gochuchamchi-guardduty-isolation-lambda`. `assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json` — lambda.tf의 공용 신뢰 정책 재사용(주석 명시). 함수별 역할 분리 패턴의 두 번째 사례다.

### L498–504 · resource "aws_iam_role_policy_attachment" "isolation_basic_execution"

AWS 관리형 `AWSLambdaBasicExecutionRole` 부착. policy_arn을 괄호로 감싼 것은 순전히 줄 길이 포매팅이다 — 의미 차이는 없다.

### L506–777 · data "aws_iam_policy_document" "guardduty_isolation"

이 파일의 실질적 무게중심 — **271줄, 21개 statement로 대응 8종의 권한을 최소권한 원칙으로 새긴 정책 문서**다. "격리 Lambda가 탈취되면 무엇까지 할 수 있는가"에 대한 답이기도 하므로 statement별로 본다. 반복되는 기법 세 가지를 먼저 잡으면 읽기 쉽다: ① Describe*/List*류는 리소스 수준 제한을 지원하지 않아 `*`로 열되 읽기 전용임을 근거로 삼는다, ② 쓰기 행위는 `arn:aws:ec2:${var.region}:${account_id}:...`로 리전·계정을 박아 좁힌다(대상 개체는 finding이 가리키므로 사전에 못 좁힘), ③ 더 좁힐 수 있는 곳은 condition(태그·생성 액션)으로 조인다.

- `DescribeTargets` — `ec2:DescribeInstances/DescribeSecurityGroups/DescribeNetworkInterfaces`를 `*`로. 대상 확인용 조회이고 기법 ①에 해당. audit 모드가 격리 태그로 인스턴스를 찾는 것도 이 권한을 쓴다(L635 주석).
- `CreateQuarantineSg` — `ec2:CreateSecurityGroup`을 security-group과 **vpc 두 ARN 타입**으로 허용한다. CreateSecurityGroup은 IAM 평가 시 두 리소스 타입 모두를 검사하기 때문에 둘 다 필요하다. VPC가 매일 재생성돼 ARN을 배포 시점에 못 박으므로(주석) 리전·계정 한정 + 와일드카드가 최선이다.
- `TagOnCreate` — `ec2:CreateTags`에 `condition ec2:CreateAction = CreateSecurityGroup`. **SG를 만드는 그 순간에만** 태그를 달 수 있다 — 검역 SG에 식별 태그(`gochuchamchi:role=quarantine`)를 강제하면서, 이 권한이 기존 SG에 임의 태그를 다는 데 악용되는 것을 막는다.
- `RevokeQuarantineEgress` — `ec2:RevokeSecurityGroupEgress`에 `condition aws:ResourceTag/gochuchamchi:role = quarantine`. 새 SG의 기본 egress(전체 허용)를 지워 **0규칙 = 전면 차단** 상태를 만드는 권한인데, 태그 조건 덕에 **우리가 만든 검역 SG에만** 쓸 수 있다 — 운영 SG의 egress를 지우는 사고/악용이 IAM 수준에서 불가능하다. 앞의 TagOnCreate와 맞물려 "생성 시 태깅 강제 → 태그로 후속 행위 제한"의 2단 잠금이 완성된다.
- `IsolateEni` — `ec2:ModifyNetworkInterfaceAttribute`를 `*`로. 격리의 실제 실행(ENI의 SG 목록을 검역 SG로 교체)이다. ENI는 finding이 가리키는 대상이라 사전에 좁힐 수 없다는 주석 — 이 statement가 이 정책에서 가장 강한 권한이고, 그래서 호출 경로 통제(lambda_permission의 source_arn)가 중요해진다.
- `TagQuarantinedInstance` — 인스턴스 ARN 한정 `ec2:CreateTags`. 격리 시각·finding ID 등 포렌식 태깅.
- `TagEniPreQuarantine` — network-interface ARN 한정 `ec2:CreateTags`. **복구의 근거**를 만드는 권한이다 — 격리 직전의 원본 SG 목록을 각 ENI의 `gochuchamchi:pre-quarantine-sgs` 태그에 기록해 두고, recover 경로가 이 태그를 읽어 복원한다. 상태 저장소를 따로 두지 않고 대상 자체에 상태를 붙이는 설계.
- `DeleteQuarantineTags` — instance/network-interface 한정 `ec2:DeleteTags`. recover 경로가 원상복구 후 격리 태그를 걷어낸다 — audit가 복구 완료를 태그 부재로 판단할 수 있게 하는 마무리다.
- `DisableCompromisedAccessKey` — `iam:ListAccessKeys` + `iam:UpdateAccessKey`를 `user/*`로. 주석의 판단이 중요하다: **DeleteAccessKey는 주지 않는다** — 삭제는 되돌릴 수 없고 포렌식 증적도 사라지는 반면, Inactive 전환은 즉시 효력이 있으면서 가역적이다. 자동 대응의 원칙(가역적 조치만 자동, 비가역은 사람)이 IAM 권한 목록에 그대로 새겨진 부분.
- `WriteIsolationHistory` — 이력 테이블 ARN 한정 `dynamodb:PutItem/Query/GetItem/DeleteItem`. Put/Query는 이력 적재·조회, **GetItem/DeleteItem은 WAF 차단 만료 청소용**이다(주석) — audit 경로가 각 IP의 만료 시각을 읽고, IP set에서 해제한 뒤 그 항목을 지운다.
- `ManageWafBlocklist` — `wafv2:GetIPSet/UpdateIPSet`을 `arn:aws:wafv2:us-east-1:...:global/ipset/${var.waf_blocklist_ip_set_name}/*`로. CLOUDFRONT scope IP set은 us-east-1 global ARN이라 리전이 하드코딩됐고, **이름은 특정하되 Id는 와일드카드**다 — IP set이 재생성돼 Id가 바뀌어도 정책이 깨지지 않게 하면서 이름으로는 좁힌 절충.
- `ListWafIpSets` — `*`. 이름 → Id 해석에 필요한 목록 조회. 리소스 수준 제한 미지원이지만 읽기 전용이라 노출 표면이 작다는 주석(기법 ①).
- `SendCommandRunShellDocument` + `SendCommandToBastionOnly` — 파드 격리 경로의 백미다. `ssm:SendCommand`는 document와 instance **양쪽 리소스에 대해 평가**되므로 statement를 둘로 나눠 각각 좁혔다: document는 `AWS-RunShellScript` 하나만(ARN에 계정 자리가 빈 것은 AWS 소유 공용 document라서), instance는 `*`이되 `condition ssm:resourceTag/Name = gochuchamchi-bastion`으로 **배스천에만**. 둘 다 매칭돼야 호출이 성립하므로 "배스천에서 셸 스크립트 실행" 외의 SSM 사용이 불가능하다. Lambda가 EKS 프라이빗 API에 직접 붙지 않고 이미 gochuchamchi 네임스페이스 edit 권한이 있는 배스천을 경유시키는 이유(주석) — Lambda를 VPC에 넣고 EKS 인증을 붙이는 복잡도를 피하면서 기존 권한 경계를 재사용한다.
- `ReadSsmCommandResult` — `ssm:GetCommandInvocation`을 `*`로. SendCommand의 실행 결과 폴링용 읽기 권한.
- `QuarantineIamPrincipal` — `iam:PutRolePolicy/PutUserPolicy/DeleteRolePolicy/DeleteUserPolicy`를 role/*, user/*로. 대응 ①(deny-all 인라인 정책 부착/제거). Put과 Delete가 짝인 것은 이 대응도 가역적이어야 하기 때문이다.
- `BlockS3Public` — `s3:PutBucketPublicAccessBlock`을 `arn:aws:s3:::*`로. 대응 ②. S3 버킷 ARN에는 계정이 없어 이 이상 못 좁힌다.
- `RemoveRiskySgRules` — `ec2:RevokeSecurityGroupIngress`를 SG ARN 한정으로. 대응 ③. RevokeQuarantineEgress와 달리 태그 조건이 없다 — 대상이 검역 SG가 아니라 원본(운영) SG이기 때문인데, 그만큼 스위치(sg_response_enabled)가 기본 false다.
- `ForensicSnapshot` — `ec2:CreateSnapshots`(복수형 — 인스턴스의 전 볼륨 일괄 스냅샷 API)를 `*`로. 대응 ④.
- `TagForensicSnapshot` — snapshot ARN 한정 `ec2:CreateTags`에 `condition ec2:CreateAction = CreateSnapshots`. TagOnCreate와 같은 "생성 순간에만 태깅" 기법.
- `PublishResult` — `sns:Publish`를 허브 토픽 ARN 한 개로. 대응 결과 통보가 SNS 허브로만 나갈 수 있다. sns.tf 해설에서 말한 "Lambda의 발행은 토픽 정책이 아니라 실행 역할 IAM으로 허용된다"의 실체가 이 statement다.

### L779–784 · resource "aws_iam_role_policy" "guardduty_isolation"

위 정책 문서를 인라인 정책으로 격리 역할에 부착한다. 이 역할 밖에서 재사용될 일 없는 정책이라 인라인 — lambda.tf와 같은 판단이다.

### L786–843 · resource "aws_lambda_function" "guardduty_isolation"

격리 Lambda 본체. 인자 해부:

- `handler = "isolation_function.lambda_handler"`, `runtime = "python3.12"`, `filename` + `source_code_hash` — Discord Lambda와 같은 단일 파일·해시 기반 재배포 패턴.
- `timeout = 120` — 주석이 산정 근거다: SG 생성 + ENI 교체 + SNS 발행에 더해, 파드 격리 경로는 배스천 SSM 명령의 완료 폴링(최대 50초)이 붙으므로 여유를 뒀다. Discord Lambda의 15초와 비교하면 "하는 일의 목록"이 타임아웃 값에 그대로 반영돼 있다.
- `memory_size = 128` — 최소값. API 호출 오케스트레이션이라 메모리를 안 먹는다.
- `environment.variables` — **변수 → 코드 스위치의 전달 계층**이다. 전부 문자열이어야 하므로 bool은 삼항으로 "true"/"false", number는 `tostring()`, list는 `join(",")`으로 직렬화한다. 묶음별로: 기본 격리(SNS_TOPIC_ARN, MIN_SEVERITY, QUARANTINE_SG_NAME=`gochuchamchi-quarantine`, ISOLATION_ENABLED, PROTECTED_INSTANCE_TAG_KEYS), 2026-08-12 확장(HISTORY_TABLE, HISTORY_RETENTION_DAYS, CREDENTIAL_RESPONSE_ENABLED, PROTECTED_ACCESS_KEY_IDS, QUARANTINE_STALE_HOURS), WAF(WAF_RESPONSE_ENABLED, WAF_BLOCKLIST_IP_SET_NAME, WAF_BLOCK_TTL_HOURS, PROTECTED_IPS), 파드 격리(POD_RESPONSE_ENABLED, BASTION_TAG_NAME=`gochuchamchi-bastion` — IAM 조건의 태그 값과 같은 문자열이어야 SendCommand가 성립한다), 추가 4종(IAM_SUBJECT_RESPONSE_ENABLED, PROTECTED_IAM_PRINCIPALS, S3_RESPONSE_ENABLED, SG_RESPONSE_ENABLED, SNAPSHOT_ON_ISOLATE_ENABLED). QUARANTINE_SG_NAME이 변수가 아닌 리터럴인 것은 검역 SG 이름이 운영 중 바뀔 이유가 없어서다.
- `depends_on` — basic execution 부착과 인라인 정책 부착을 명시. 함수가 권한보다 먼저 생겨 첫 finding 처리(격리!)가 AccessDenied로 죽는 경쟁 상태를 막는다 — 통보 Lambda보다 실패 비용이 훨씬 큰 함수라 이 두 줄의 가치도 크다.

## cloudwatch-notifications/triage.tf (649줄)

GuardDuty finding을 **LLM으로 1차 판정**해 (심각도 × 판정) 정책 표에 따라 통보 수위를 조절하는 실험 기능이다(2026-08-13). 헤더 다이어그램이 구조의 전부를 담고 있다 — Rule 1(타입/severity 필터)을 통과한 finding만 트리아지 Lambda로 가서 "필터 → Groq 판정 → 정책 표"를 거쳐 SNS 허브로 나가고, Rule 2(severity>=7)의 격리 경로는 **AI를 기다리지 않는다**. 두 원칙이 주석에 명시돼 있다: ① "필터와 판단은 층이 다르다" — 무엇을 볼지는 EventBridge 패턴이 공짜로 정하고(걸리면 Lambda 호출조차 없다), 트리아지는 살아남은 것에 대해서만 진짜/오탐을 붙인다. 소음 제거를 모델에 시키면 그게 곧 토큰 낭비다. ② 두 경로는 EventBridge에서 갈라져 서로를 모른다 — 대응이 모델 지연·장애·오판에 걸리면 안 되므로 이 변경은 통보 경로에만 끼어든다. Bedrock이 아니라 Groq인 이유는 비용이다(gpt-oss-120b 기준 finding 1건 약 $0.0006, 캐시·상한까지 걸면 월 $1 미만). 그 대가 두 가지도 코드에서 각각 막았다 — API 키가 생긴다 → Secrets Manager 수동 주입(state 오염 방지), 데이터가 AWS 밖으로 나간다 → 화이트리스트 투영 + 계정ID/사설IP/이메일 가명화. **현재 상태**: `enable_triage=false`로 배선 2개(EventBridge target + lambda permission)만 끊겨 있고, Lambda·IAM 역할·정책 3개·DynamoDB·시크릿·로그 그룹·알람 등 기계 9개는 남아 있다(유휴 비용 월 $0.5). 껐다 켜기가 수 초이고 시크릿은 지우면 이름이 7일 잠기므로, 이것은 방치가 아니라 의도된 설계다.

Python 쪽은 줄 단위 해설 대상이 아니므로 역할만 요약한다. `triage_function.py`가 오케스트레이터다 — 테스트 IP 제외 → 중복 억제(DynamoDB) → 티어 산정(severity + 타입 접두사 승격) → 판정 스킵 여부 → `judge.py` 호출 → `policy.py`로 (티어 × 판정) 표 평가 → SNS 발행 + CloudWatch 지표. `judge.py`는 provider 추상화 계층이다 — `TRIAGE_PROVIDER`에 따라 groq(기본, openai/gpt-oss-120b)/openai/gemini는 OpenAI Chat Completions 규격으로, anthropic만 Messages API로 호출하며, 외부 SDK 없이 표준 라이브러리 urllib만 쓰고, 전송 전에 화이트리스트 필드 투영과 가명화를 수행한다. `policy.py`는 정책 표와 confidence 하한을 적용한다. `context.md`는 이 인프라의 사실(배스천 SSH 인바운드 0, SSO 사용, 일일 재구축 등)을 모델에게 주는 지식 문서로, **판정 정확도의 대부분이 여기서 나오며 인프라가 바뀌면 룰이 아니라 이 문서를 고치는 것이 유지보수 전략**이다(archive_file 주석).

### L30–70 · variable "enable_triage"

이 파일의 마스터 스위치이자, 41줄짜리 description이 사실상 운영 런북인 변수다. 기본 false. 조목조목: ① false면 EventBridge 타겟이 SNS 직결로 되돌아간다(guardduty-response.tf의 count 게이트와 짝) — **알림 자체는 끊기지 않고 판정만 없어진다**. ② 기본값이 false인 이유는 이력이다 — 2026-08-13에 적용했다가 판정 provider를 재검토하기로 하면서 배선을 껐는데, 기본값이 true로 남아 있으면 이 루트를 apply하는 사람이 의도치 않게 트리아지를 되살리고, 그때 시크릿의 키가 유효한지 아무도 확인하지 않는다. **"코드의 기본값과 실제 배포 상태를 일치시켜 두는 것이 이 변수의 유일한 안전장치"**라는 문장은 이 프로젝트 전체에서 인용할 가치가 있는 원칙이다. ③ 켤 때는 `$env:TF_VAR_enable_triage = "true"`로 명시적으로, 켜기 전 compare-providers.py로 판정이 실제 나오는지 확인. ④ 긴급 정지 시 EventBridge 룰을 disable하지 말 것 — 룰을 끄면 통보 경로 전체가 죽는다(룰은 트리아지·SNS 직결 공용이므로). 이 변수로 끄면 SNS 직결로 안전하게 되돌아간다. ⑤ 끄는 것/안 끄는 것의 경계 — 끄는 것은 target과 permission 둘뿐, Lambda 함수·IAM 역할과 정책 3개·DynamoDB·로그 그룹·알람·시크릿은 남는다. 기계는 두고 배선만 끊으므로 재가동에 IAM 전파 대기가 없다. ⑥ 리소스까지 없애려면 -target destroy가 필요한데 **시크릿은 지우지 말 것** — recovery_window_in_days=7 동안 같은 이름 재생성이 잠긴다.

### L72–76 · variable "triage_judge_enabled"

Groq 판정만 따로 끄는 부분 스위치. 기본 true. false면 모든 finding이 UNCERTAIN으로 처리돼 정책 표대로 통보된다 — 소음은 늘지만 **탐지 공백은 없다**. 트리아지 파이프라인(중복 억제·티어링)은 유지한 채 모델 호출만 빼고 싶을 때 쓴다.

### L78–102 · variable "triage_provider"

판정을 맡길 API 규격. `groq`(기본)/`openai`/`gemini`/`anthropic` — validation이 이 4개로 강제한다. groq/openai/gemini는 OpenAI Chat Completions 규격을 공유하고 anthropic만 Messages API로 갈라진다는 것, 시크릿의 키 형식도 provider에 맞춰야 한다는 것(gsk_/sk-/AIza/sk-ant-)이 description에 있다. 경고 두 개가 실전적이다 — gemini는 구글의 OpenAI 호환 레이어(베타)를 타므로 response_format 지원을 compare-providers.py로 먼저 확인할 것, 그리고 **Claude를 쓰려면 반드시 "anthropic"** — OpenAI 호환 레이어로 부르면 response_format이 무시되어 구조화 출력이 깨지고 모든 finding이 조용히 "판정 없음"이 된다. 이 파일 전반의 고장 모드가 전부 이런 식이다: 에러가 아니라 **판정 없는 알림이 계속 나오는 침묵 열화**.

### L104–126 · variable "triage_groq_model"

모델 ID. 기본 빈 문자열 — 비우면 judge.py가 provider별 기본(groq=openai/gpt-oss-120b, openai=gpt-4o-mini, gemini=gemini-3.6-flash, anthropic=claude-haiku-4-5)을 채운다. gpt-oss-120b 선정 근거는 2026-08-12 실측 — llama-3.3-70b보다 싸고(입력 1/4) 빠르고(1.8배) 크며, Llama 3.3은 공식 지원 언어에 한국어가 없다. 경고 셋: provider와 모델의 짝이 안 맞으면 404 → 전부 "판정 없음"(헷갈리면 비워 두는 편이 안전), 웹 검색·코드 실행 도구가 붙은 시스템 금지 — **판정 입력에 공격자가 값을 정할 수 있는 문자열(인스턴스 태그, 버킷 이름, User-Agent)이 들어가므로 도구가 붙으면 프롬프트 인젝션이 오판을 넘어 실제 외부 요청으로 증폭된다**, 그리고 모델 목록은 수시로 바뀌는데 없는 모델이어도 알림은 계속 나와 알아채기 어렵다.

### L128–136 · variable "triage_groq_endpoint"

API 엔드포인트. 기본 빈 문자열 — provider만 바꾸고 엔드포인트를 옛 값으로 남겨 두는 사고를 막으려고 **기본값을 비워** provider 기본값이 따라오게 했다. 프록시나 호환 게이트웨이를 쓸 때만 채운다.

### L138–147 · variable "triage_groq_max_tokens"

판정 응답 최대 출력 토큰. 기본 4000. gpt-oss 계열은 추론 모델이라 최종 JSON 앞에 사고 과정 토큰을 먼저 생성하는데, 예산이 빠듯하면 JSON을 시작하기도 전에 소진돼 400 json_validate_failed로 떨어진다 — **700으로 잡았다가 실제로 만난 문제**다. "상한이지 지출이 아니다 — 생성된 토큰만 과금된다"는 문장이 4000이라는 넉넉한 값의 정당화다.

### L149–163 · variable "triage_groq_reasoning_effort"

추론 깊이. 기본 "low", validation은 ""/low/medium/high. 사고 과정 토큰도 출력 단가로 과금되므로 **이 값이 곧 판정 비용**이다 — finding 한 건이 정상 자동화인지 가르는 일이라 low로 충분하다는 판단. 빈 문자열이면 파라미터를 아예 안 보낸다 — 허용값이 다른 모델을 위한 탈출구이고 코드에도 자동 재시도가 있다.

### L165–205 · variable "triage_policy_matrix"

(심각도 티어 × AI 판정) → 액션의 2차원 map. 로그 담당자의 요구 구조를 그대로 표로 옮겼고, **코드 배포 없이 tfvars만 고쳐 정책을 바꿀 수 있다**는 것이 map(map(string)) 타입을 고른 이유다. 액션 6종: urgent(🚨 긴급)/alert(🔴 알림)/review(🟡 검토)/likely_fp(⚪ 오탐 의심, 낮은 우선순위 통보)/suppress(🔇 통보 안 함)/store(📦 통보 안 함, GuardDuty에 보관). 기본 표의 구조를 읽으면 설계 철학이 보인다 — CRITICAL 행은 판정과 무관하게 전부 urgent(모델이 오탐이라 해도 무시), **알림이 완전히 사라지는 칸은 MEDIUM × FALSE_POSITIVE 하나뿐**이고 그마저 triage_suppress_min_confidence를 통과해야 한다. "이 칸을 늘릴수록 모델 오판이 곧 미탐이 된다"는 경고가 이 표의 안전 원칙이다. validation 두 개 — 모든 액션이 6종 안에 있는지(중첩 for + alltrue), 네 티어가 모두 존재하는지. 표가 tfvars로 조정 가능한 만큼 잘못된 표가 apply되는 것을 plan에서 막는다.

### L207–225 · variable "triage_type_prefix_min_tier"

(A) 갈래(always_notify 접두사)에 걸린 타입의 **최소 티어**. 기본 "HIGH", validation은 MEDIUM/HIGH/CRITICAL(LOW는 승격의 의미가 없어 제외). description이 "⚠ 이 값이 이 스택에서 가장 중요한 설정"이라고 자평하는 이유 — **이 환경의 finding은 실제로 거의 전부 severity 2(LOW)다**(2026-08-12 실측 문서 인용). 티어를 severity로만 정하면 루트 사용·자격증명 탈취 같은 가장 중요한 finding이 전부 LOW로 떨어져 판정도 못 받고 저장만 된다. EventBridge (A) 갈래가 severity 무관으로 통과시킨 의미를 트리아지 층에서도 이어받는 장치이며, "이전 구현이 같은 함정을 문서로 남겼다"는 문장은 개편 전 severity 기반 필터의 누락 사고(guardduty-response.tf Rule 1 해설)를 가리킨다.

### L227–243 · variable "triage_suppress_min_confidence"

FALSE_POSITIVE 판정으로 알림을 없애는 데 필요한 최소 확신도. 기본 0.7, validation 0~1. 로그 담당자 스펙에는 없던 하한을 추가한 이유 — 없으면 모델이 확신 0.3으로 FALSE_POSITIVE를 뱉어도 그대로 묻힌다. "confidence를 스키마에 넣어 놓고 정책에서 안 쓰면 그 필드는 장식"이라는 문장이 요지다. 미달이면 UNCERTAIN으로 강등해 "검토"로 보낸다 — suppress의 유일한 칸(MEDIUM×FP)에 이중 자물쇠를 다는 변수.

### L245–256 · variable "triage_skip_judge_tiers"

판정 없이 저장만 할 티어 목록. 기본 ["LOW"] — 여기 걸리면 Groq 호출조차 없다(비용 0). LOW를 넣어도 증거는 안 사라진다는 논증이 삼단이다: GuardDuty가 90일 보관하고, (B) 갈래가 이미 severity<4를 걸러 Lambda까지 오지도 않으며, 여기 도착하는 LOW는 (A) 갈래(중요 타입)로 들어온 것들인데 그건 triage_type_prefix_min_tier가 HIGH로 올려 주므로 이 목록에 안 걸린다. 변수 셋(A 갈래 접두사·min_tier·skip 목록)이 맞물려야 "중요한 LOW는 판정받고, 시시한 LOW는 호출 안 한다"가 성립하는 구조다.

### L258–266 · variable "triage_test_ips"

점검/모의훈련 출발지 IP 목록. 기본 빈 목록. 여기서 온 finding은 판정도 통보도 하지 않는다 — 우리가 돌린 스캐너를 위협으로 알리면 알림 신뢰도가 먼저 무너진다(양치기 소년 방지). ⚠ 넣는 순간 그 IP의 실제 공격도 안 보이므로 **훈련 기간에만 넣고 뺄 것** — 화이트리스트는 공격자의 은신처가 될 수 있다는 상식의 코드화다.

### L268–272 · variable "triage_dedup_hours"

같은 finding id의 재통보 억제 기간. 기본 6시간. GuardDuty는 같은 사건을 count를 올리며 반복 발행하므로, 이 억제가 없으면 진행 중인 공격 하나가 채널을 도배한다.

### L274–278 · variable "triage_verdict_cache_hours"

같은 (타입 × 리소스) 조합의 판정 재사용 기간. 기본 6시간. **판정 호출을 아끼는 주 수단**이다 — 같은 인스턴스에 같은 유형의 finding이 반복되면 첫 판정을 재사용한다. dedup이 "같은 사건 알림 억제"라면 이것은 "비슷한 사건 판정 절약"으로, 층이 다르다.

### L280–284 · variable "triage_daily_call_limit"

하루 판정 호출 상한. 기본 300. 무료 티어의 429를 맞기 전에 **우리가 먼저 멈춘다** — 상한을 넘겨도 통보는 계속되고 판정만 빠진다(UNCERTAIN 경로). 외부 의존이 죽어도 핵심 기능(통보)은 열화만 되고 중단되지 않는다는 이 파일의 일관된 실패 설계다.

### L286–295 · variable "triage_strict_masking"

켜면 IAM 역할/사용자 이름, 버킷 이름까지 가명으로 치환해 Groq에 보낸다. 기본 false. 계정 ID·사설 IP·이메일은 **이 값과 무관하게 항상** 가려진다(judge.py의 기본 가명화). 기본 false인 이유가 트레이드오프의 정직한 기록이다 — "이 주체가 CI 자동화인가 사람인가"가 판정의 핵심 근거인데 이름을 가리면 그 판단이 불가능해진다. 프라이버시와 판정 정확도 사이에서, 이름 정도는 보내고 식별자는 가리는 중간선을 기본값으로 택했다.

### L298–301 · locals

`triage_name = "gochuchamchi-guardduty-triage"`와 `triage_metric_namespace = "Gochuchamchi/Triage"`. 함수·역할·정책·테이블·로그 그룹·알람 이름이 전부 `local.triage_name` 파생이라, 이 한 줄이 리소스 이름의 단일 진실이다. 네임스페이스는 IAM 정책의 PutMetricData condition과 Lambda 환경변수 METRIC_NAMESPACE 양쪽에 들어간다 — 둘이 어긋나면 지표 발행이 AccessDenied로 죽으므로 locals로 묶은 것이다.

### L323–332 · resource "aws_secretsmanager_secret" "triage_groq_api_key"

Groq API 키의 **그릇만** Terraform이 만들고 값은 사람이 넣는다(`gochuchamchi/triage/groq-api-key`). variable로 받으면 tfstate에 평문으로 남는다 — 2026-08-05에 PAT로 배운 원칙("시크릿 값은 인프라와 생애주기가 다르다")의 재적용이고, secrets.tf의 Discord 웹훅(그릇도 값도 수동)과는 변형 관계다. apply 후 한 번만 `aws secretsmanager put-secret-value`로 주입하며, 값을 안 넣어도 알림은 정상 동작한다 — 전부 "판정 없음"이 될 뿐. `recovery_window_in_days = 7`의 산정이 흥미롭다: 0이면 destroy 시 즉시 삭제돼 값이 증발하고, 크면 같은 이름 재생성이 "삭제 예약됨"으로 그만큼 막히므로 7일로 타협했다. enable_triage description의 "시크릿은 지우지 말 것"이 바로 이 속성 때문이다.

### L344–367 · resource "aws_dynamodb_table" "triage_state"

트리아지의 상태 테이블(`gochuchamchi-guardduty-triage-state`). 중복 억제/판정 캐시/호출 상한 **셋을 한 테이블에서 키 접두사로 구분**한다 — `finding#<id>`(이미 통보했나), `verdict#<type>#<resource>`(판정 재사용 가능한가), `quota#<YYYY-MM-DD>`(오늘 몇 번 호출했나). 단일 `hash_key = "state_key"`에 range key가 없는 이유다 — 전부 정확 키 조회(GetItem)라 정렬이 필요 없다. `ttl { attribute_name = "expires_at" }`로 dedup/캐시 기간 만료를 DynamoDB가 알아서 청소한다. `point_in_time_recovery { enabled = false }` — 주석의 판단이 정확하다: 중복 억제 상태가 유실돼도 알림이 한 번 더 오는 정도라 복구 대상이 아니다. isolation_history(PITR true)와의 대비가 "데이터의 가치에 맞춘 보호 수준"이라는 원칙을 보여 준다.

### L374–381 · resource "aws_iam_role" "triage"

트리아지 Lambda 전용 실행 역할. `assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json` — lambda.tf 공용 신뢰 정책의 세 번째 소비자. 함수별 역할 분리 패턴의 세 번째 사례이기도 하다.

### L383–386 · resource "aws_iam_role_policy_attachment" "triage_basic_execution"

관례대로 `AWSLambdaBasicExecutionRole` 부착. 로그 그룹은 아래에서 명시 생성하지만 쓰기 권한은 이 관리형 정책이 준다.

### L388–423 · data "aws_iam_policy_document" "triage"

트리아지 역할의 본 정책 — statement 4개가 이 Lambda의 행동 반경 전부다. `PublishToAlertHub`(sns:Publish, 허브 토픽 하나), `TrackTriageState`(dynamodb:PutItem/GetItem/UpdateItem, 상태 테이블 하나 — Query가 없는 것도 정확하다, 전부 키 조회니까), `ReadGroqApiKey`(secretsmanager:GetSecretValue, 트리아지 시크릿 하나 — Discord 웹훅 시크릿은 못 읽는다, lambda.tf의 역방향과 함께 시크릿 상호 격리가 성립한다), `PublishTriageMetrics`(cloudwatch:PutMetricData — 리소스 단위 제한이 불가능한 API라 `*`로 열되 `condition cloudwatch:namespace = Gochuchamchi/Triage`로 좁힌다, 격리 정책의 기법 ③과 동일). 격리 Lambda의 21개 statement와 비교하면 "판정만 하고 아무것도 만지지 않는" 함수라는 것이 권한 목록에서 바로 읽힌다.

### L425–429 · resource "aws_iam_role_policy" "triage"

위 문서를 인라인 정책으로 부착. 패턴 동일.

### L444–469 · data "archive_file" "triage"

배포 패키지. 상단 주석 두 개가 모두 중요하다. ① **외부 SDK가 없다** — Groq은 HTTP API고 judge.py는 표준 라이브러리 urllib만 쓴다. Bedrock 시절 필요했던 레이어 빌드(build-layer.ps1)가 사라졌고, 그래서 apply에 python/pip/PyPI 접근이 필요 없다 — provider 교체가 배포 파이프라인 단순화로 이어진 사례. ② `source_dir`이 아니라 **source 블록으로 파일을 하나씩 지정**한다 — 디렉터리를 통째로 넣으면 `__pycache__`나 배포 대상이 아닌 검증 스크립트(check-groq.py, compare-providers.py)까지 딸려가 zip 해시가 예측 불가능하게 흔들린다(= 코드 변경이 없는데 재배포가 뜬다). 포함 파일 4개: triage_function.py, judge.py, policy.py, 그리고 **context.md** — "판정 정확도의 대부분이 여기서 나온다. 인프라가 바뀌면 룰이 아니라 이 문서를 고치는 것이 이 설계의 유지보수 전략"이라는 주석이 붙은, 코드가 아닌 지식 문서가 배포 패키지에 들어가는 특이 지점이다.

### L471–540 · resource "aws_lambda_function" "triage"

트리아지 Lambda 본체. 인자 해부:

- `timeout = 60` — 판정 1회(최대 20초, 아래 TRIAGE_TIMEOUT_SECONDS) + 재시도 여유. 주석의 경고가 이 파일의 고장 철학을 압축한다: 이 값을 줄이면 Lambda가 중간에 잘려 **알림도 지표도 안 남는다 — 가장 조용한 형태의 고장이다**. `memory_size = 256` — Discord/격리 Lambda(128)의 두 배인 것은 JSON 투영·가명화·HTTP 호출이 겹치기 때문.
- `environment.variables` — 변수 계층이 통째로 내려간다. 주목할 것들: `TRIAGE_SECRET_ARN` 주석 — **시크릿 리소스/이름은 그대로 두고 환경변수 이름만 옮겼다**. 시크릿 이름을 바꾸면 재생성인데 삭제된 이름이 복구 대기창 7일 동안 잠겨 provider 전환이 그만큼 막히기 때문이다. `TRIAGE_*` 접두사로의 개명 이유도 주석에 있다 — provider가 groq만이 아니게 된 뒤로 GROQ_ 접두사가 거짓말이 되기 때문이고, judge.py는 TRIAGE_*를 우선 읽고 옛 GROQ_*로 물러선다(하위 호환). `POLICY_MATRIX`/`ALWAYS_NOTIFY_PREFIXES`/`SKIP_JUDGE_TIERS`/`TEST_IPS`는 `jsonencode()`로 직렬화 — 격리 Lambda의 join(",")보다 구조적인 전달이다. `ALWAYS_NOTIFY_PREFIXES`가 guardduty-response.tf의 변수를 그대로 참조하는 것이 EventBridge 필터와 트리아지 승격 로직의 정의 공유 지점이다.
- `dead_letter_config { target_arn = aws_sqs_queue.alerts_dlq.arn }` — Lambda 자체가 죽어도 finding을 잃지 않는다. 새 DLQ를 만들지 않고 sns.tf의 알림 DLQ를 재사용해 실패 경로를 한 곳에 모았고, DLQ 알람(→ 이메일 직접 전달)이 이 실패도 함께 감시한다.
- `depends_on` — 권한 부착 완료 후 함수 생성. 다른 두 Lambda와 같은 경쟁 상태 방지.

### L543–550 · data "aws_iam_policy_document" "triage_dlq"

`sqs:SendMessage`를 alerts_dlq 하나로 좁힌 문서. 주석이 함정을 짚는다 — **dead_letter_config는 실행 역할의 권한으로 큐에 쓴다**. SNS → DLQ는 큐 정책(sns.tf)이 허용하지만 Lambda → DLQ는 역할 IAM이 필요하다 — 같은 큐를 쓰는 두 실패 경로의 권한 모델이 다르다는 것. 이 정책이 없으면 Lambda 실패 시 DLQ 적재도 실패해 finding이 진짜로 증발한다.

### L552–556 · resource "aws_iam_role_policy" "triage_dlq"

위 DLQ 문서를 별도 인라인 정책(`...-dlq`)으로 부착. 본 정책과 분리한 것은 관심사 분리 — 판정 권한과 실패 처리 권한을 문서 단위로 나눠 둔 것이다.

### L559–566 · resource "aws_cloudwatch_log_group" "triage"

`/aws/lambda/<함수명>` 로그 그룹을 **명시 생성**하고 `retention_in_days = 30`을 박는다. 주석대로 암묵 생성되면 보존기간이 "무기한"이라 요금이 계속 는다 — Lambda가 첫 실행 때 알아서 만드는 로그 그룹의 기본값 함정을 코드로 막은 것. 이름을 `aws_lambda_function.triage.function_name` 참조로 조립해 함수와의 연결이 그래프에 남는다.

### L579–585 · resource "aws_cloudwatch_event_target" "triage"

**enable_triage가 게이트하는 배선 첫 번째**. `count = var.enable_triage ? 1 : 0`으로, Rule 1(guardduty_finding)의 타겟을 트리아지 Lambda로 건다. guardduty-response.tf의 guardduty_sns 타겟(count가 정반대)과 합쳐 "둘 중 하나만 존재"가 성립한다 — 같은 룰의 타겟을 변수 하나로 갈아 끼우는 스위치 구조. 현재 false이므로 이 리소스는 **존재하지 않는다**.

### L587–595 · resource "aws_lambda_permission" "triage_from_events"

**게이트되는 배선 두 번째**. EventBridge가 트리아지 Lambda를 호출할 권한, source_arn은 Rule 1. 타겟과 같은 count 게이트가 걸려 있어 꺼진 상태에서는 권한 자체가 없다 — 배선을 끊을 때 호출 가능성까지 회수하는 깔끔한 마무리다. enable_triage 해설의 "끄는 것은 이 둘뿐"이 가리키는 두 리소스가 바로 위 타겟과 이 permission이다.

### L609–629 · resource "aws_cloudwatch_metric_alarm" "triage_errors"

자기 감시 알람. 논리가 주석에 있다 — 트리아지가 켜진 상태에서 Lambda가 죽으면 **GuardDuty 통보 경로 전체가 조용해진다**(타겟이 이쪽이므로). 오류를 알람으로 잡아 두지 않으면 "알림이 없는 것"과 "탐지가 멈춘 것"이 구분되지 않는다. `AWS/Lambda` `Errors` 지표를 FunctionName 차원으로, Sum/300초/1회 평가/`>= 1` — 오류 1건이면 즉시 ALARM. `treat_missing_data = "notBreaching"` — 호출이 없으면 지표가 안 찍히는 Lambda 특성 대응(sns.tf DLQ 알람과 동일). 알람 이름 `gochuchamchi-guardduty-triage-errors`가 prefix 규약을 지켜 eventbridge.tf 룰 → SNS 허브로 통보된다 — 알람에 alarm_actions가 없는 것도 규약대로다. `alarm_description`이 사실상 대응 런북이다: 로그 경로를 적시하고, 원인 파악이 길어지면 enable_triage=false로 SNS 직결로 되돌리라는 지시까지 담았다. 지금은 enable_triage=false라 호출 자체가 없어 이 알람은 영원히 OK다 — 남아 있는 기계 9개 중 하나로, 유휴 비용 월 $0.1의 출처다.

### L636–639 · output "triage_function_name"

트리아지 Lambda 이름. 수동 테스트(`aws lambda invoke`)나 로그 조회 시 이름을 복붙하기 위한 운영 편의 output이다.

### L641–644 · output "triage_groq_secret_name"

시크릿 이름과 함께, description에 **후속 수동 작업 지시**를 실었다 — "apply 후 이 시크릿에 Groq API 키를 주입해야 판정이 붙는다(없어도 통보는 동작)". apply 출력이 곧 체크리스트가 되게 하는 패턴으로, sns.tf output(규약 문서화)과 같은 용법이다.

### L646–649 · output "triage_policy_matrix"

현재 적용 중인 (심각도 × 판정) → 액션 표를 그대로 노출한다. tfvars로 조정 가능한 값이므로 "지금 뭐가 적용돼 있나"를 콘솔 뒤지지 않고 `terraform output`으로 확인하게 한 것 — 정책 표가 코드 밖(tfvars)에서 바뀔 수 있는 설계의 보완 장치다.

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| providers.tf | 18 | 2 | 100% |
| backend.tf | 15 | 1 | 100% |
| account-guard.tf | 10 | 1 | 100% |
| variables.tf | 26 | 3 | 100% |
| secrets.tf | 6 | 1 | 100% |
| sns.tf | 174 | 9 | 100% |
| lambda.tf | 125 | 7 | 100% |
| eventbridge.tf | 57 | 2 | 100% |
| drift-detection.tf | 164 | 7 | 100% |
| guardduty-response.tf | 843 | 42 | 100% |
| iam-activity.tf | 74 | 2 | 100% |
| log-account-eventbridge.tf | 14 | 1 | 100% |
| triage.tf | 649 | 34 | 100% |
| **합계** | **2,175** | **112** | **100%** |


---

# terraform (1) — 런타임 루트: 네트워크·데이터·컴퓨트 기반

이 섹션이 다루는 `terraform/` 루트는 gochuchamchi 프로젝트에서 유일하게 **매일 태어나고 매일 죽는 계층**이다. 아침에 `daily-up.ps1`이 apply를 돌려 약 235+15개 리소스(VPC·EKS·RDS·Redis·EFS·ALB·CloudFront 등)를 만들고, 저녁에 `daily-down.ps1`이 destroy로 약 278개를 지운다. 학생 프로젝트의 비용을 시간당 과금 리소스가 떠 있는 시간에 비례하도록 만든 설계인데, 이 사이클 하나가 이 루트의 수많은 결정을 지배한다. RDS 계정을 아침마다 배스천에서 재프로비저닝하는 것, S3 버킷에 `force_destroy`를 켜 두는 것, ECR·KMS·시크릿을 별도의 상시 루트(`../persistent`)로 빼내고 여기서는 data source로만 조회하는 것, 최종 스냅샷을 일부러 남기지 않는 것 — 전부 "내일 아침에도 어제와 같은 상태로 다시 태어나야 하고, 죽을 때 비용 잔재를 남기면 안 된다"는 같은 전제에서 나온다.

이 루트는 Workload 계정(828885965304) 전용이다. 프로젝트 전체는 management(조직·SSO) / log-archive(로그 중앙 수집) / account-baseline(상시 보안) / persistent(ECR·KMS·시크릿 상시) / cloudwatch-notifications / discord-notifications / terraform(이 루트)로 나뉘고, 이 문서는 그중 terraform 루트의 **기반 계층** — 백엔드·가드·변수, 네트워크(VPC·SG·NACL·엔드포인트·Flow Logs·DNS), 데이터(S3·EFS·Redis·RDS와 그 초기화·제로트러스트 계정 체계), 컴퓨트 권한(IAM·Pod Identity) 20개 파일을 담당한다. 엣지(CloudFront·WAF), K8s 배포(k8s-deploy.tf·argocd.tf 등), 관측 파일은 다른 섹션이 다룬다.

읽는 순서는 실행 흐름과 같다. backend/account-guard/variables가 실행의 전제 조건을 깔고, persistent-data가 상시 계층 산출물을 끌어오고, main이 VPC·EKS·배스천·NAT를 세우고, securitygroups~dns가 네트워크 경계를 조이고, s3~rds가 데이터 계층을 만들고, rds-schema-init·db-zero-trust가 배스천을 통해 DB 내부 상태(스키마·계정)를 코드로 재현하며, iamRole·eks-pod-identity가 "누가 무엇을 할 수 있는가"를 못박는다.

---

## terraform/backend.tf (20줄)

tfstate를 어디에 어떻게 저장하고 잠글지를 정의하는 파일이다. 백엔드 블록은 변수 보간이 불가능하므로 버킷명·리전·프로파일이 전부 하드코딩되어 있고, 그 값들은 terraform 밖의 부트스트랩 스크립트(`scripts/bootstrap-state.ps1`)가 만든 실체와 일치해야 한다.

### L1–20 · terraform { backend "s3" { ... } }

- `bucket = "gochuchamchi-tfstate-828885965304"` — Workload 계정 소유의 상태 버킷. 계정 ID를 접미사로 붙여 전역 유일성을 확보한다. 이 버킷 자체는 terraform 관리 밖(부트스트랩 스크립트 생성)이다 — 자기 상태를 담는 그릇을 자기 상태로 관리하면 destroy가 자기 발밑을 지우는 순환이 생기기 때문이다.
- `key = "eks/terraform.tfstate"` — 같은 버킷을 쓰는 다른 루트(persistent 등)와 state 파일 경로로 구분한다.
- `region = "ap-northeast-2"`, `profile = "workload-admin"` — 서울 리전, SSO 기반 workload-admin 프로파일. provider의 `var.aws_profile` 기본값과 같은 값이지만 백엔드는 변수를 못 쓰므로 별도로 적는다.
- `encrypt = true` — state 객체 서버측 암호화 요구.
- `use_lockfile = true` — 파일 첫 줄 주석이 말하는 핵심이다. Terraform 1.10+의 **S3 네이티브 잠금**으로, 예전처럼 DynamoDB 테이블을 따로 만들지 않고 같은 버킷에 `.tflock` 객체를 조건부 PUT하여 동시 apply를 막는다. 일일 재생성 체제에서 잠금용 DynamoDB라는 상시 리소스를 하나 줄인 선택이기도 하다.
- `kms_key_id = "arn:...:alias/gochuchamchi-tfstate"` — 2026-08-13에 추가된 SSE-S3 → SSE-KMS 전환의 실체다. 주석이 함정을 정확히 기록하고 있다: `encrypt = true`만 있고 `kms_key_id`가 비어 있으면 terraform이 PUT 요청에 **AES256을 명시적으로** 실어 보내서, 버킷 기본 암호화를 KMS로 바꿔 놓아도 state는 계속 SSE-S3로 저장된다. 즉 "버킷 설정만 바꾸면 되겠지"가 통하지 않고 백엔드 설정에 키를 적어야 실제로 적용된다. 키는 부트스트랩 스크립트가 terraform 밖에서 만든다 — 자기 state를 암호화하는 키를 자기가 관리하면, 키를 실수로 지웠을 때 복구 수단(state)까지 함께 잠기는 순환 의존이 생긴다. 키 ARN이 아니라 **별칭(alias) ARN**을 쓰는 이유는 키를 재생성해도 별칭만 새 키로 옮기면 이 파일을 고칠 필요가 없게 하기 위해서다.

이 전환의 배경에는 알려진 이슈가 있다: SSE-S3에서는 버킷 읽기 권한이 곧 복호화 능력이라(별도 KMS 권한 검사가 없다) state에 담긴 민감값 방어선이 버킷 정책 하나뿐이었다. SSE-KMS로 바꾸면 "버킷 읽기 + KMS Decrypt" 두 권한이 모두 있어야 state를 읽을 수 있다.

---

## terraform/account-guard.tf (10줄)

멀티 계정 프로젝트의 고전적 사고 — "프로파일을 잘못 잡고 다른 계정에 apply" — 를 plan 단계에서 차단하는 안전핀이다.

### L1–10 · resource "terraform_data" "account_guard"

- `terraform_data`는 실 리소스를 만들지 않는 내장 placeholder 타입이다. 여기서는 `lifecycle.precondition`을 걸 지지대로만 쓴다.
- `input = data.aws_caller_identity.current.account_id` — 현재 자격증명의 계정 ID(s3.tf에 선언된 data source)를 입력으로 받는다.
- `precondition`의 `condition`은 계정 ID가 정확히 `"828885965304"`(Workload 계정)인지 검사하고, 아니면 `error_message`("terraform/은 Workload 계정 828885965304에서만 실행할 수 있습니다")로 plan이 즉시 실패한다. 3계정(Management/Log/Workload) 체제에서 management용 admin 프로파일로 이 루트를 돌리는 실수는 리소스 278개를 엉뚱한 계정에 만드는 대형 사고가 되는데, 그 가능성을 코드 10줄로 봉쇄한 것이다. 다른 루트(management, log-archive 등)에도 같은 패턴의 가드가 각자의 계정 ID로 존재한다.

---

## terraform/variables.tf (304줄)

이 루트의 모든 입력 변수와, "지워진 변수의 무덤"까지 담고 있는 파일이다. 주석으로 남은 삭제 이력(B2 key_name, B3 argocd_git_pat)도 설계 결정의 기록이므로 함께 읽는다.

### L1–5 · variable "aws_profile"

AWS CLI 프로파일명. 기본값 `workload-admin` — PowerShell 환경에서 SSO 로그인으로 관리하는 프로파일이다. provider(aws)·local-exec의 aws CLI 호출·kubernetes/helm provider의 `aws eks get-token` 인자에까지 일관되게 흘러 들어간다.

### L7–10 · variable "region"

기본값 `ap-northeast-2`(서울). ARN 조립(db-zero-trust.tf), VPC 엔드포인트 service_name, SSM 명령 등 리전이 필요한 모든 곳이 이 변수를 참조한다.

### L12–15 · variable "azs"

`["ap-northeast-2a", "ap-northeast-2c"]` — 2AZ 구성. 이 리스트의 길이와 순서가 NAT 인스턴스 개수(`count = length(var.azs)`), 서브넷 배치, EFS mount target 커버리지의 기준이 된다. "azs 순서 = private_route_table_ids 순서 = public_subnets 순서"라는 vpc 모듈의 정렬 규약(main.tf 주석)이 AZ별 1:1 매칭의 전제다.

### L17–20 · variable "cluster_name"

`gochuchamchi-eks`. EKS 모듈, kubeconfig 갱신 userdata, Cluster Autoscaler 태그, ExternalDNS `txtOwnerId` 등에서 재사용된다.

### L22–26 · variable "domain_name"

기본값 `kycj.click` — 사용자 개인 소유 도메인으로, Route53 호스팅 존이 이미 존재하고 등록기관에서 NS 위임까지 끝난 상태다. dns.tf가 이 이름으로 존을 **조회**(생성이 아님)하고 ACM 인증서의 도메인으로 쓴다.

### L28–29 · (주석) key_name 변수 제거 기록

2026-08-04 백로그 B2. 노드·NAT·배스천 전부 SSM 접속만 쓰므로 SSH 키페어를 붙일 리소스가 없어졌고, 변수도 함께 삭제됐다. "SSH를 안 연다"가 SG 규칙만이 아니라 키페어라는 존재 자체의 삭제로 관철된 것이다.

### L31–35 · variable "bastion_ami" / L37–41 · variable "nat_ami"

둘 다 같은 AL2023 AMI `ami-0f93dc65265863858`(2026-07-27 기준 서울 리전 최신 확인값). data source로 최신 AMI를 자동 조회하지 않고 고정한 이유는 일일 재생성 체제와 관련이 깊다 — 최신 자동 조회면 AWS가 AMI를 갱신한 날 아침에 배스천·NAT가 예고 없이 다른 이미지로 뜨고, `user_data_replace_on_change`와 결합해 예측 불가능한 재생성이 섞인다. 고정값이면 갱신 시점을 사람이 통제한다.

### L43–46 · variable "node_instance_types"

`["t3.medium"]`. 과거 t3.small일 때 ENI 기반 max-pods가 노드당 11개뿐이라 시스템 파드만으로 소진되던 문제(main.tf vpc-cni 주석)가 있었고, prefix delegation과 함께 여유를 확보한 크기다.

### L48–61 · variable "node_min_size" / "node_max_size" / "node_desired_size"

2 / 4 / 2. managed node group의 스케일 범위이며, Cluster Autoscaler가 이 min/max 안에서 실제 증감을 수행한다. min=desired=2는 2AZ에 노드 1대씩이라는 최소 HA 형태다.

### L66–70 · variable "argocd_github_owner" / L72–76 · variable "argocd_gitops_repo"

GitOps 저장소 좌표(`landoll9999` / `gochuchamchi-gitops`). ArgoCD가 감시할 저장소로, Deployment/Service/HPA 매니페스트만 담는다(인프라와 앱 배포의 관심사 분리).

### L78–80 · (주석) argocd_git_pat 변수 제거 기록

백로그 B3. PAT가 Terraform 변수 → tfstate 경로를 아예 타지 않도록, Secrets Manager에 CLI로 1회 주입하고 ESO(External Secrets Operator)가 클러스터로 동기화하는 구조로 바꿨다. "시크릿은 state에 넣지 않는다"는 이 루트의 일관된 원칙(db-zero-trust.tf와 동일)의 한 사례다.

### L87–96 · variable "argocd_admin_password_bcrypt"

ArgoCD admin 비밀번호의 **bcrypt 해시**(평문 아님)를 받는 변수. 매일 재구축되는 환경에서 UI로 비밀번호를 바꿔도 다음 날 초기 비밀번호로 회귀하는 문제를 코드로 고정하기 위한 것이다(백로그 B4). `validation`이 `^\$2[aby]\$` 정규식으로 bcrypt 형식만 허용해서 실수로 평문을 넣는 사고를 막고, 에러 메시지에 해시 생성 명령(`htpasswd -nbBC 10 "" '<비밀번호>' | tr -d ':\n'`)까지 안내한다. 기본값 `""`이면 initial-admin-secret 동작을 유지한다. 해시는 원문 복원이 안 되므로 state에 남아도 등급이 낮다.

### L105–112 · variable "endpoint_public_access_cidrs"

EKS 퍼블릭 엔드포인트 접속 허용 CIDR(집·현재 작업 네트워크의 /32 두 개). 앞의 긴 주석이 이 변수의 운영 함정 두 가지를 기록한다. (1) 목록에 없는 네트워크에서 apply하면 kubernetes/helm 프로바이더가 인증 에러가 아니라 **TCP 타임아웃**으로 실패하는데, AWS API만 쓰는 리소스는 정상 진행되므로 "절반만 성공한 apply"라는 진단하기 어려운 상태가 된다. (2) 유동 IP는 나중에 타인에게 재할당되므로 안 쓰는 /32를 방치하면 **그 사람에게 엔드포인트를 열어주는 셈**이다 — 허용 목록은 추가만이 아니라 삭제도 관리 대상이다.

### L118–122 · variable "container_insights_log_retention_days"

Container Insights 로그 보존 30일. 관측 파일(다른 섹션)에서 소비된다.

### L148–160 · variable "enable_edge"

CloudFront + Route53 전환 스위치(기본 false). 2단계 apply가 필요한 이유가 description에 있다: ALB는 aws-load-balancer-controller가 **비동기로** 만들기 때문에 최초 apply 시점에는 `data.aws_lb` 조회가 실패한다. 그래서 1차 apply(false)는 us-east-1 인증서 + WAF까지만 만들고, ALB가 뜬 뒤 2차 apply(true)로 CloudFront를 만들고 도메인을 전환한다. "Terraform 밖에서 생기는 리소스"와의 시차를 플래그로 다루는 패턴이다. 실제 소비처는 edge.tf(다른 섹션).

### L162–171 · variable "waf_rate_limit_per_5min"

단일 IP의 5분당 최대 요청 수 2000. validation이 WAFv2 rate-based rule의 하한(100)을 강제한다.

### L173–182 · variable "waf_login_rate_limit_per_5min"

`POST /auth/login` 전용 rate limit 50 — 전역 한도와 별개로 로그인 대입 공격만 훨씬 낮은 임계로 조인다. 최소 10 검증.

### L184–193 · variable "waf_login_rate_limit_action"

로그인 rule의 동작. 기본 `COUNT`(관찰 모드) — 오탐으로 실제 사용자를 차단하기 전에 로그로 임계 적정성을 검증하고, 확신이 서면 `BLOCK`으로 올리는 단계적 도입이다. validation이 두 값만 허용한다.

### L195–204 · variable "cloudfront_origin_header_rotation_version"

CloudFront → ALB 오리진 검증 헤더 값의 회전 버전(1 이상). 숫자를 올리면 비밀 헤더 값이 재생성되는데, CloudFront 전파와 ALB 규칙 갱신 사이의 짧은 불일치가 가능하므로 "점검 시간에 apply"하라는 운영 주의가 description에 박혀 있다.

### L220–224 · variable "enable_dr"

AWS Backup(RDS/EFS → 도쿄 크로스리전 복사) + S3 CRR 스위치. 기본 false — 비용 절감을 위해 평소엔 끄고, 재해복구 시연·검증이 필요할 때만 켠다.

### L226–230 · variable "dr_backup_retention_days"

복구 지점 보존 7일. 서울 원본과 도쿄 사본에 동일 적용.

### L245–249 · variable "superadmin_username"

앱의 SuperAdminBootstrap이 기동 시 superadmin으로 승격할 아이디(앱 ConfigMap의 `APP_SUPERADMIN_USERNAME`). 계정을 만들어주지는 않으므로 해당 아이디로 회원가입이 선행돼야 하고, 비워두면 superadmin이 0명이라 admin 임명 기능을 쓸 수 없다는 동작까지 주석이 명시한다.

### L255–264 · variable "pss_enforce_level"

gochuchamchi 네임스페이스의 Pod Security Standards enforce 레벨. 기본 `baseline` — gitops의 Deployment에 securityContext를 먼저 갖춘 뒤 `restricted`로 올리는 순서를 description이 안내한다(순서를 바꾸면 파드가 스케줄 거부된다). validation은 세 표준 레벨만 허용.

### L271–275 · variable "rds_skip_final_snapshot"

destroy 시 최종 스냅샷 생략 여부, 기본 **true**. 직관에 반하는 기본값의 이유가 v8 주석에 있다: 매일 destroy하는 체제에서 false면 스냅샷이 매일 1개씩 쌓여 월 ~$12가 되는데, DB 데이터는 rds-schema-init.tf가 복원하는 재현 가능한 시드라서 스냅샷 누적 비용이 데이터 가치보다 크다. 운영 전환 시에만 false + 스냅샷 수명 관리가 세트다.

### L283–287 · variable "enable_vpc_endpoints"

인터페이스형 VPC 엔드포인트 7종 스위치, 기본 **false**. 8/7 비용 분류에서 1위 항목(7종×2AZ ≈ 월 $133)이었기 때문이다. 꺼진 동안 ECR pull·Secrets Manager·SSM 트래픽은 NAT 인스턴스 2대를 경유한다 — 동작은 하지만 NAT가 그 경로의 단일 실패점이 되므로, 시연·검증일에만 `-var enable_vpc_endpoints=true`로 켠다. 무료인 S3 Gateway 엔드포인트는 main.tf에서 상시 유지한다.

### L295–304 · variable "log_archive_account_id"

Log 계정 ID `564186750363`. flow-logs.tf와 log-archive-subscriptions.tf가 크로스 계정 버킷·KMS ARN을 **조립**할 때 쓴다 — data source로 조회하려면 로그 계정 자격증명이 필요해서 조립을 택했다. validation은 12자리 숫자(또는 빈 값) 형식만 허용하고, 비어 있으면 소비처의 precondition이 plan에서 명확한 메시지로 실패하게 설계돼 있다.

이 밖에 L130–131, L210–213 등의 주석 구획은 삭제되었거나 다른 파일로 이관된 변수들의 흔적이다. 특히 L210–213은 iam-security.tf의 MFA 강제 그룹에 Terraform 실행 계정을 넣으면 CLI 액세스 키(MFA 없음)로 도는 Terraform 전체가 AccessDenied가 되는 07/29 '3pro' 그룹 사고 유형을 경고한다.

---

## terraform/persistent-data.tf (55줄)

상시 계층(`../persistent`)이 소유한 리소스를 이 루트에서 **읽기 전용으로 조회**하는 파일이다. L1–21의 헤더 주석이 분리의 논리를 완결적으로 설명한다: ECR(이미지)·서명 KMS 키·CI용 OIDC/IAM 역할·PAT 시크릿은 "메인 인프라를 destroy해도 살아남아야 하는 것들"인데, 메인 state에 있으면 저녁 destroy가 함께 지워 매번 503이 났다. 그리고 이 넷은 한 묶음이어야 한다 — 이미지만 살려도 CI가 못 돌면 갱신이 안 되고, CI가 돌아도 PAT가 없으면 배포가 안 된다. remote state 참조가 아니라 data source 조회를 택한 이유도 명시돼 있다: 전부 이름이 고정된 리소스라 결합도가 낮고, persistent 쪽 output 구성이 바뀌어도 여기가 깨지지 않는다.

운영 순서 제약이 여기서 나온다: **data source는 대상이 없으면 plan이 즉시 실패**하므로, 완전 신규 구축이라면 반드시 `../persistent`를 먼저 apply해야 한다(주석의 ※가 그 순서를 적어 놓았다). 일일 사이클에서도 persistent는 항상 살아 있으므로 아침 apply가 무사히 조회에 성공하는 구조다.

### L23–25 · data "aws_ecr_repository" "gochuchamchi"

이름 `gochuchamchi`로 ECR 저장소를 조회. destroy가 `force_delete`로 이미지까지 지워 ImagePullBackOff를 만들던 문제를 persistent 이관으로 끊었고, 여기서는 `repository_url`만 재노출(ecr.tf)한다.

### L28–30 · data "aws_kms_key" "image_signing"

컨테이너 이미지 서명용 KMS 키를 `alias/gochuchamchi-image-signing` **별칭으로** 조회한다. 키를 교체해도 별칭만 옮기면 이 코드는 그대로 동작한다 — backend.tf의 별칭 ARN과 같은 원칙이다. 키가 재생성되면 GitHub 변수와 어긋나 CI 서명 잡이 실패하던 것이 persistent 이관의 이유였다.

### L32–34 / L36–38 · data "aws_iam_role" "github_actions_ecr_push" / "github_actions_image_signer"

GitHub Actions OIDC로 assume되는 CI 역할 2개(이미지 push용 / 서명용)를 이름으로 조회. 역할이 재생성되면 GitHub 쪽 trust 설정과 어긋나 CI가 AWS를 assume하지 못하므로 상시 계층에 있다.

### L40–42 / L44–46 / L48–50 · data "aws_secretsmanager_secret" — PAT 시크릿 3개

`gochuchamchi/argocd/git-pat`(구 통합 PAT), `gochuchamchi/argocd/gitops-read-pat`(ArgoCD가 GitOps 저장소를 읽는 read-only PAT), `gochuchamchi/argocd/image-updater-write-pat`(Image Updater가 이미지 태그 갱신 커밋을 push하는 write PAT). 읽기와 쓰기를 별도 토큰으로 분리해 각 컴포넌트가 필요한 최소 권한의 토큰만 갖게 한 구조다. 값(`secret_string`)이 아니라 시크릿 **컨테이너의 ARN**만 조회한다는 점이 중요하다 — 값은 ESO가 클러스터에서 직접 동기화하므로 tfstate를 거치지 않는다.

### L53–55 · data "aws_kms_key" "data"

워크로드 데이터 CMK를 `alias/gochuchamchi-data` 별칭으로 조회. 원래 이 루트(kms.tf)에 있던 키인데 2026-08-07 persistent로 옮겼다 — 이유는 kms.tf 해설 참조. RDS·EFS의 `kms_key_id`가 이 data를 소비한다.

---

## terraform/main.tf (350줄)

이 루트의 척추다. 프로바이더 선언, VPC, EKS 클러스터+노드그룹, 배스천, AZ별 NAT 인스턴스, 프라이빗 라우팅, S3 Gateway 엔드포인트, 핵심 output까지 — 하루의 apply에서 가장 오래 걸리고 가장 많은 것이 딸려 나오는 파일이다.

### L1–29 · terraform { required_providers }

aws `~> 6.0`, helm `~> 3.0`, kubernetes `~> 2.35`, time `~> 0.11`, tls `~> 4.0`, random `~> 3.6`. 전부 pessimistic 제약(`~>`)으로 major를 고정한다 — L45 주석이 이유를 대신 말해준다: **매일 init하는 구조**라 버전을 안 고정하면 major 업그레이드가 무경고로 유입된다. 보통 프로젝트라면 가끔 있는 init이 여기서는 매일이므로, 버전 제약이 곧 일일 안정성이다. random은 redis.tf의 AUTH 토큰 생성용으로 뒤늦게 추가됐다(추가 시 init 1회 필요하다는 주석).

### L31–34 · provider "aws"

`region`/`profile`을 변수로 받는 단순 선언. 자격증명 하드코딩이 없고, SSO 프로파일에 위임한다. kubernetes/helm 프로바이더는 EKS 산출물이 필요해서 eks-pod-identity.tf에 있다.

### L43–70 · module "vpc" (terraform-aws-modules/vpc/aws ~> 6.0)

- `name = "gochuchamchi-vpc"`, `cidr = "172.30.0.0/16"` — 흔한 10.0.0.0/16 대신 172.30을 쓴 것은 기존/가정 네트워크와의 충돌 회피 겸 식별 편의.
- `azs = var.azs` — 2AZ. 서브넷 리스트들의 인덱스가 이 순서에 정렬된다.
- `enable_dns_support` / `enable_dns_hostnames = true` — VPC 내부 DNS 해석 활성화. 인터페이스 엔드포인트의 `private_dns_enabled`(vpc-endpoints.tf)와 EKS 내부 통신의 전제다.
- `private_subnets = ["172.30.40.0/23", "172.30.60.0/23"]` — 주석이 크기의 이유를 명시한다: EKS 노드/파드 IP가 여기서 할당되므로 /24(251개)가 아닌 **/23(507개)**로 잡아 prefix delegation으로 파드가 늘어도 IP 고갈 없이 스케일하게 했다.
- `public_subnets = ["172.30.10.0/24", "172.30.30.0/24"]` — ALB·NAT 인스턴스용.
- `database_subnets = ["172.30.12.0/24", "172.30.32.0/24"]` + `create_database_subnet_group = true` — RDS·ElastiCache가 곧바로 쓸 서브넷 그룹까지 모듈이 만든다.
- `create_database_subnet_route_table = true` — 중요한 한 줄. DB 서브넷의 라우팅 테이블을 private 서브넷과 **분리**해서 NAT 라우트가 아예 없는 "진짜 isolated 서브넷"으로 만든다. DB가 인터넷으로 나갈 경로 자체를 라우팅 레벨에서 제거하는 것 — nacl.tf의 스테이트리스 차단과 겹겹의 방어를 이룬다.
- `map_public_ip_on_launch = true` — 퍼블릭 서브넷에 뜨는 인스턴스(NAT)에 공인 IP 자동 부여.
- `public_subnet_tags`의 `kubernetes.io/role/elb = 1` / `private_subnet_tags`의 `kubernetes.io/role/internal-elb = 1` — aws-load-balancer-controller가 인터넷 대면/내부 ALB를 각각 어느 서브넷에 만들지 찾는 **디스커버리 태그**다. 이 태그가 없으면 Ingress를 만들어도 컨트롤러가 서브넷을 못 찾아 ALB 생성이 실패한다.

### L75–190 · module "eks" (terraform-aws-modules/eks/aws ~> 21.0)

- `name = var.cluster_name`, `kubernetes_version = "1.35"` — 버전 명시로 예기치 않은 마이너 업그레이드를 차단.
- `create_cloudwatch_log_group = true`, `cloudwatch_log_group_retention_in_days = 90` — 컨트롤플레인 로그 그룹. 이 두 값은 모듈 기본값과 동일해서 plan diff를 만들지 않는데도 **일부러 명시**돼 있다. cloudwatch-log-archive.tf가 이 로그 그룹을 Firehose로 구독해 S3 장기 보관하므로(`module.eks.cloudwatch_log_group_name` 참조), false로 바꾸면 아카이브가 같이 깨진다는 의존관계를 코드에 드러내려는 것이다 — "지우지 말 것"이라는 주석까지 붙어 있다.
- `enabled_log_types`를 지정하지 않은 것도 결정이다: 기본값(api/audit/authenticator)을 쓰되, controllerManager/scheduler를 추가하면 `aws_eks_cluster` 변경 → `data.aws_eks_addon_version`이 apply 시점 조회로 밀려 애드온 6개가 전부 "known after apply"로 떠 plan이 지저분해지는 연쇄를 주석이 경고한다.
- `vpc_id` / `subnet_ids = module.vpc.private_subnets` — 노드는 프라이빗 서브넷에만 둔다.
- `endpoint_public_access = true` + `endpoint_private_access = true` + `endpoint_public_access_cidrs = var.endpoint_public_access_cidrs` — 하이브리드 엔드포인트. 로컬 kubectl/terraform은 허용 CIDR로 퍼블릭 엔드포인트에 붙고, 노드·배스천은 프라이빗 엔드포인트로 통신한다.
- `enable_cluster_creator_admin_permissions = true` — apply를 실행한 IAM 주체에 클러스터 admin access entry를 자동 부여. kubernetes/helm 프로바이더가 별도 설정 없이 인증되는 근거다(eks-pod-identity.tf 주석).
- `eks_managed_node_groups.initial` — 노드그룹 하나:
  - `instance_types` / `min_size` / `max_size` / `desired_size` — 변수 그대로(t3.medium, 2/4/2).
  - `metadata_options` — IMDSv2 강제 세트. `http_tokens = "required"`(세션 토큰 없는 IMDSv1 호출 거부), `http_put_response_hop_limit = 1`(파드가 노드를 한 홉 거쳐 노드 IAM 자격증명을 훔쳐가는 경로 차단 — 워크로드 권한은 Pod Identity로만), `instance_metadata_tags = "disabled"`.
  - `vpc_security_group_ids = [module.add_node_sg.id]` — 규칙이 비어 있는 추가 SG(securitygroups.tf 해설 참조).
  - `iam_role_additional_policies`의 `AmazonSSMManagedInstanceCore` — 노드 접속은 SSM으로만. key_name 제거(B2)와 세트이며, launch template 변경이라 적용 시 노드 롤링이 발생하므로 트래픽 적은 시간대에 apply하라는 운영 주의가 있다.
  - `tags`의 `k8s.io/cluster-autoscaler/enabled` / `k8s.io/cluster-autoscaler/<cluster>` — managed node group 태그는 AWS가 내부 생성하는 ASG로 전파되고, Cluster Autoscaler의 auto-discovery가 이 태그로 스케일 대상 ASG를 찾는다.
- `addons` — 관리형 애드온 6종: `coredns`, `eks-pod-identity-agent`(`before_compute = true` — 노드가 뜨기 전에 설치돼야 노드 위 파드들이 처음부터 자격증명을 받는다), `kube-proxy`, `vpc-cni`(역시 before_compute + `configuration_values`로 `ENABLE_PREFIX_DELEGATION=true`(노드당 max-pods 11 → 110, /23 서브넷과 결합)와 `enableNetworkPolicy=true`(eBPF NetworkPolicy 시행 엔진 — 켜는 것만으로는 아무것도 차단 안 되고 실제 정책은 k8s-network-policies.tf) 설정), `aws-efs-csi-driver`, `metrics-server`(없으면 HPA가 "cpu: <unknown>/70%"로 멈춘다 — 2026-07-29 FailedGetResourceMetric 이벤트로 실증).
- `access_entries.bastion` — 배스천 역할의 K8s 권한. 2026-08-04 제로트러스트 조치로 ClusterAdmin(클러스터 전역)에서 **gochuchamchi 네임스페이스 한정 `AmazonEKSEditPolicy`**로 축소했다. 배스천이 클러스터에 하는 일은 DB Secret 업서트와 cm/secret 조회뿐이므로, 배스천이 침해돼도 kube-system·argocd 네임스페이스의 Secret은 못 읽는다. 타 네임스페이스 디버깅이 필요하면 배스천 권한을 넓히지 말고 로컬 kubectl 경로(허용 CIDR 추가)를 쓰라는 우선순위까지 주석이 정해 놓았다.
- `additional_security_group_ids = [module.add_cluster_sg.id]` — 배스천→API용 추가 클러스터 SG.

### L196–247 · module "bastion_host" (terraform-aws-modules/ec2-instance/aws ~> 6.0)

- `depends_on = [module.eks]` — userdata가 `update-kubeconfig`를 수행하므로 클러스터가 먼저 있어야 한다.
- `name` / `ami = var.bastion_ami` / `instance_type = "t3.micro"` / `monitoring = true`(상세 모니터링).
- `associate_public_ip_address = false` + `subnet_id = module.vpc.private_subnets[0]` — **2026-08-12에 퍼블릭 서브넷+공인 IP에서 프라이빗 서브넷으로 이전**한 결과다. L207–219 주석이 판단 과정을 그대로 담고 있다: 공인 IP가 하던 일은 SSM 접속용 아웃바운드 인터넷 하나뿐이었다. SG 인바운드가 0건이라 그 IP로 들어올 수 있는 것은 애초에 없었고(인바운드 표면 문제가 아니라 아웃바운드 경로 문제), 그 경로는 프라이빗 서브넷의 NAT 인스턴스로 대체된다. 트레이드오프도 명시돼 있다 — 배스천 도달성이 NAT에 묶이지만, EKS 노드가 이미 같은 NAT에 의존하므로 NAT 장애 시점엔 클러스터가 이미 비정상이라 한계 손실이 작다. 이 의존까지 끊으려면 SSM 3종 엔드포인트만 켜면 되지만 현재 `enable_vpc_endpoints`는 7종 일괄이라 비용이 붙는다는 한계까지 적혀 있다. (참고: 과거 문서·주석에 "사설 이전은 SendCommand 의존성 때문에 보류"라는 기록이 있었다면 그것은 이전 시점의 상태다 — 현재 코드는 이전이 완료된 형태이며, rds-schema-init.tf·db-zero-trust.tf의 SendCommand는 SSM 채널로 동작하므로 배스천의 서브넷 위치와 무관하게 NAT 아웃바운드만 있으면 성립한다.)
- `metadata_options` — 노드와 동일한 IMDSv2 강제 세트. 주석이 논리를 못박는다: SSRF로 인스턴스 크리덴셜을 긁어가는 경로는 서브넷 위치와 무관하게 성립하므로, 공인 IP를 뗐다고 완화할 이유가 없다.
- `user_data_replace_on_change = true` — userdata 스크립트가 바뀌면 인스턴스를 재생성한다. cloud-init은 첫 부팅에만 돌기 때문에, 이 옵션이 없으면 스크립트 수정이 기존 인스턴스에 반영되지 않는다.
- `root_block_device = { size = 20, type = "gp3" }`.
- `vpc_security_group_ids = [module.bastion_host_sg.id]` — 인바운드 0개 SG.
- `iam_instance_profile` — iamRole.tf의 배스천 프로파일.
- `user_data = templatefile("userdata.sh.tpl", { cluster_name, region })` — 부팅 시 kubectl 설치와 `aws eks update-kubeconfig`까지 자동 실행. 매일 새로 태어나는 배스천이 손대지 않아도 즉시 작업 가능 상태가 되게 하는 장치다.

### L267–303 · module "nat_instance" (ec2-instance ~> 6.0, count = length(var.azs))

L250–265의 긴 주석이 설계 전체를 요약한다. 기존 NAT 인스턴스 1대는 죽으면 프라이빗 서브넷 **전체**가 아웃바운드 불능이 되는 SPOF였다. AZ마다 1대씩 두고 각 AZ의 프라이빗 라우트 테이블을 같은 AZ의 NAT로 연결하면 NAT 1대 장애는 해당 AZ만 영향(장애 반경 격리)이고, AZ 자체 장애면 어차피 그 AZ 노드도 같이 죽으므로 반대쪽 AZ는 무영향이다. 한계도 정직하게 적혀 있다 — NAT Gateway와 달리 인스턴스 방식은 AZ 간 자동 페일오버가 없고, 대신 비용이 1/5이며 VPC 엔드포인트가 이중 안전망이다. "프로덕션 기준이면 NAT Gateway 2대가 정답"이라는 결론까지.

- `count = length(var.azs)` — AZ 수만큼. 라우팅의 전제는 vpc 모듈의 정렬 규약이다: single_nat_gateway가 아니면 AZ별로 프라이빗 라우트 테이블이 1개씩 생기고, azs 순서 = private_route_table_ids 순서 = public_subnets 순서라서 `count.index`로 같은 AZ끼리 1:1 매칭이 된다.
- `subnet_id = module.vpc.public_subnets[count.index]` — AZ별 퍼블릭 서브넷 배치.
- `source_dest_check = false` — NAT의 필수 조건. EC2는 기본적으로 자기 IP가 아닌 트래픽을 버리므로, 남의 트래픽을 중계하려면 이 검사를 꺼야 한다.
- `create_security_group = false` + `vpc_security_group_ids = [module.nat_sg.id]` — 모듈 자동 생성 SG 대신 명시 SG.
- `metadata_options` — IMDSv2 세트 동일.
- `user_data = templatefile("nat_install.tpl", {})` + `user_data_replace_on_change = true` — iptables MASQUERADE 등 NAT 설정 스크립트.
- `iam_instance_profile` — SSM 접속용 nat 프로파일(iamRole.tf).
- `maintenance_options = { auto_recovery = "default" }` — 시스템 상태 검사 실패 시 자동 복구. 인스턴스 NAT가 가질 수 있는 최소한의 자가 치유다.

### L307–310 · moved (module.nat_instance → module.nat_instance[1])

단일 NAT에서 count 방식으로 전환할 때의 state 수술 기록. 기존 NAT는 public_subnets[1]에 있었으므로 count의 [1]번으로 **주소만 이동**시키면 재생성 없이 인수되고, [0]번(AZ-a)만 새로 뜬다. `moved` 블록은 이런 리팩터링에서 "지웠다 다시 만들기"를 피하는 정석 도구다.

### L313–318 · resource "aws_route" "private_subnet"

각 프라이빗 라우트 테이블의 `0.0.0.0/0`을 같은 인덱스(=같은 AZ) NAT 인스턴스의 **primary ENI**(`network_interface_id`)로 보낸다. instance_id가 아닌 ENI를 지정하는 것이 라우트 대상으로 더 정확하다. vpc 모듈이 NAT Gateway를 만들지 않는 구성이므로 이 라우트가 프라이빗 서브넷의 유일한 인터넷 경로다.

### L322–329 · resource "aws_vpc_endpoint" "s3" (Gateway)

S3 Gateway 엔드포인트를 프라이빗 라우트 테이블 전체에 붙인다. 이유가 실질적이다: ECR pull에서 이미지 레이어 바이트는 실제로 **S3에서** 전송되므로, 이 무료 엔드포인트 하나로 가장 무거운 트래픽이 t3.micro NAT를 우회한다 — NAT의 부하와 SPOF 영향을 동시에 줄인다. 유료인 인터페이스형 7종은 vpc-endpoints.tf에서 스위치로 관리하지만, 이건 무료라서 상시 유지다.

### L334–350 · output 4개

- `bastion_private_ip` — 공인 IP 제거로 `public_ip`를 노출하면 null이 나와 "값이 왜 안 나오나"를 디버깅하게 되므로 프라이빗 IP로 교체(2026-08-12). 접속은 어차피 SSM 경유라 이 IP로 붙을 일은 없고, 세션 로그·flow log 대조용 식별자다.
- `bastion_id` — SSM `start-session --target`과 검증 스크립트가 쓰는 인스턴스 ID.
- `cluster_name` / `cluster_endpoint` — kubeconfig 구성과 스크립트용.

---

## terraform/securitygroups.tf (98줄)

EKS 모듈이 자체 생성하는 SG들 **바깥**에서 이 스택이 직접 관리하는 SG 4개다. 공통적으로 terraform-aws-modules/security-group/aws `~> 6.0`을 쓰고, 2026-08-04 백로그 B1에서 "VPC CIDR 전체 허용"류 규칙을 전부 워크로드 정체성(SG 참조) 기반으로 조인 흔적이 주석으로 남아 있다.

### L1–28 · module "add_cluster_sg"

EKS 컨트롤플레인에 붙는 추가 SG. 존재 이유는 이름 그대로 "배스천 → 컨트롤플레인" 하나뿐이다.

- `ingress_rules.https_from_bastion` — 443/tcp를 `referenced_security_group_id = module.bastion_host_sg.id`로만 허용. B1 이전에는 소스가 VPC CIDR 전체였는데, 노드/파드의 API 통신은 EKS 모듈의 자체 cluster SG 규칙(노드 SG 참조)이 담당하므로 VPC 전체를 열 이유가 없다는 논리로 축소했다. CIDR은 "네트워크 위치"를 신뢰하지만 SG 참조는 "워크로드 정체성"을 신뢰한다는, rds_sg와 같은 원칙이다.
- `egress_rules.all` — 전체 허용(아웃바운드는 관례적 개방).

### L30–55 · module "add_node_sg"

노드에 붙는 추가 SG인데 **인그레스가 비어 있다**(`ingress_rules = {}`). B1에서 "VPC 전체 모든 프로토콜·포트 허용"을 제거한 결과다. 필요한 노드 통신은 전부 다른 곳이 커버한다: 노드↔노드·컨트롤플레인→kubelet(10250)/webhook은 EKS 모듈 기본 규칙이, ALB→파드(8080)는 aws-load-balancer-controller가 클러스터 태그 붙은 모듈 노드 SG에 타겟그룹용 규칙을 동적으로 추가/삭제하며 담당한다. 이 SG가 열려 있던 시절에는 NAT/배스천 등 VPC 내 아무 자원이 침해되면 kubelet·NodePort로 측면이동이 가능했다 — "네트워크 위치는 신뢰 근거가 아니다"라는 제로트러스트 문장이 주석에 그대로 있다. 빈 SG를 삭제하지 않고 유지하는 이유도 명시돼 있다: eks-pod-identity.tf의 destroy 순서 고정(depends_on)이 이 모듈을 참조하고 있고, 나중에 노드에 정말 필요한 규칙이 생기면 "정확한 소스 SG 참조"로만 추가하는 자리다.

### L57–75 · module "bastion_host_sg"

**인바운드 0개**가 이 SG의 전부다. SSM Session Manager는 인스턴스 쪽에서 아웃바운드 443으로 세션 채널을 만들기 때문에 SSH 인바운드 자체가 필요 없다 — 포트를 좁히는 수준이 아니라 인바운드라는 개념을 삭제한 것이다. 접속 명령(`aws ssm start-session --target <id>`)까지 주석으로 안내한다. egress는 전체 허용(SSM·dnf·EKS API·RDS 접속 등 아웃바운드 작업이 많다).

### L77–98 · module "nat_sg"

- `ingress_rules.vpc_all` — `module.vpc.vpc_cidr_block`에서 오는 모든 트래픽 허용. NAT는 VPC 내부 모두의 중계자이므로 내부 전체 허용이 역할 정의 그 자체다. 단, 소스가 VPC CIDR로 한정되므로 인터넷에서 NAT로 직접 들어오는 것은 불가.
- `egress_rules.all` — 중계 트래픽이 나가는 경로.

---

## terraform/nacl.tf (71줄)

database 서브넷에만 커스텀 NACL을 씌우는 파일이다. 헤더 주석이 계층 방어의 논리를 요약한다: SG(rds_sg/redis_sg)가 이미 워크로드 정체성 기반으로 좁혀져 있지만, NACL은 그와 **독립적인 서브넷 경계** 방어선이다. SG 오설정·침해가 나도 DB 서브넷은 (1) 인터넷으로 나가는 경로가 아예 없고(exfiltration 차단), (2) VPC 내부에서도 DB 포트 외에는 못 들어온다는 것을 스테이트리스 레이어에서 한 번 더 보장한다. public/private 서브넷은 기본 NACL(전체 허용)을 일부러 유지한다 — 파드 레이어는 NetworkPolicy가 담당하고, NACL로 노드 트래픽까지 조이면 prefix delegation·헬스체크 등에서 진단이 어려운 장애가 나기 쉽다는 실용 판단이다.

### L20–34 · locals database_nacl_rules

NACL은 스테이트리스라서 SG처럼 "응답은 자동 허용"이 없다 — 그래서 규칙 목록에 ephemeral 포트 규칙이 반드시 들어간다. ingress: 3306/tcp(RDS MariaDB), 6379/tcp(Redis), 1024–65535/tcp(DB가 내보낸 요청의 응답 수신), 1024–65535/udp(DNS 응답). egress: 1024–65535/tcp(클라이언트 파드/배스천으로 돌아가는 DB 응답), 53/udp·53/tcp(VPC 리졸버 DNS 질의). rule_no 100~130의 간격은 나중에 사이에 규칙을 끼워 넣을 여지다.

### L36–71 · resource "aws_network_acl" "database"

- `subnet_ids = module.vpc.database_subnets` — DB 서브넷 2개에 연결. 커스텀 NACL을 연결하면 기본 NACL(전체 허용)이 대체된다.
- `dynamic "ingress"` / `dynamic "egress"` — locals의 규칙 목록을 순회하며 블록 생성. 모든 규칙의 `cidr_block`이 `module.vpc.vpc_cidr_block`으로 고정돼 있다는 점이 핵심이다 — **인터넷 방향 규칙이 하나도 없으므로**(NACL은 default deny) 인터넷 in/out은 전부 암묵 차단된다. main.tf의 `create_database_subnet_route_table = true`(NAT 라우트 없음)와 합치면 라우팅과 NACL 양쪽에서 인터넷 경로가 이중으로 없다.
- `action = "allow"` 고정, 포트는 locals 값. tags로 이름·프로젝트·관리 주체 표기.

---

## terraform/vpc-endpoints.tf (95줄)

인터페이스형 VPC 엔드포인트 7종을 **비용 스위치 뒤에** 두는 파일이다. 헤더 주석이 트레이드오프를 3축으로 정리한다 — 보안(AWS API 트래픽이 인터넷 구간을 아예 안 탐 + 엔드포인트 정책이라는 추가 통제 지점), 가용성(NAT가 전부 죽어도 이미지 pull·비밀 조회·SSM 접속은 동작하는 독립 경로), 비용(인터페이스형 1개 = AZ당 시간당 $0.0125, 2AZ×7종이면 상당액 — AZ 1곳만 쓰면 반값이지만 그 AZ 장애 시 엔드포인트도 같이 죽으므로 풀 이중화 취지에 맞춰 2AZ 전부 배치, 대신 NAT 처리비가 줄어 실효 증가분은 더 작다). "ECR pull 경로를 Gateway(S3)+Interface(ecr.api/dkr) 조합으로 VPC 안에 완전히 넣었고 private_dns_enabled로 앱 코드 수정 없이 전환했다"는 면접용 요약까지 주석에 있다.

### L27–42 · locals vpc_interface_endpoints

7종의 목록과 각각의 존재 이유: `ecr.api`(인증/매니페스트)·`ecr.dkr`(레이어 다운로드 시작 — 실제 바이트는 S3 Gateway가 마무리), `ssm`·`ssmmessages`·`ec2messages`(Session Manager 3종 세트 — 배스천/노드 접속), `secretsmanager`(비밀 조회), `logs`(Fluent Bit/Container Insights 로그 전송).

### L45–71 · module "vpc_endpoints_sg"

엔드포인트 ENI에 붙는 SG. `create = var.enable_vpc_endpoints` — 엔드포인트가 꺼져 있으면 SG도 안 만든다(v8, 생명주기 일치). `ingress_rules.https_from_vpc`는 VPC CIDR에서 오는 443만 허용 — 엔드포인트는 인바운드 전용 수신자이므로 이거면 충분하다. egress 전체 허용.

### L73–90 · resource "aws_vpc_endpoint" "interface" (for_each)

- `for_each = var.enable_vpc_endpoints ? toset(local.vpc_interface_endpoints) : toset([])` — 스위치가 꺼져 있으면 빈 set이라 0개 생성. 기본값이 꺼짐인 이유는 variables.tf에 있다(월 $133로 이 스택 최대 시간당 비용 항목).
- `service_name = "com.amazonaws.${var.region}.${each.value}"` — 리전별 서비스 이름 조립.
- `subnet_ids = module.vpc.private_subnets` — 2AZ 전부에 ENI 배치 = AZ 장애 내성.
- `security_group_ids = [module.vpc_endpoints_sg.id]`.
- `private_dns_enabled = true` — 이 파일의 기술적 핵심. 켜면 `ecr.ap-northeast-2.amazonaws.com` 같은 기존 퍼블릭 DNS 이름이 VPC 안에서는 엔드포인트 ENI의 프라이빗 IP로 풀린다. kubelet·aws-cli·SDK 어느 쪽도 설정 변경 없이(같은 도메인 그대로) 경로만 VPC 내부로 바뀐다.

### L92–95 · output "vpc_endpoint_ids"

for_each 결과를 `{서비스명 = 엔드포인트 ID}` 맵으로 노출. 검증 명령(`aws ec2 describe-vpc-endpoints`)이 description에 있다.

---

## terraform/flow-logs.tf (65줄)

VPC Flow Logs를 **Log 계정의 중앙 버킷**으로 직송하는 파일이다. 헤더가 파일의 위치 논리를 설명한다: Glue 테이블·Athena 쿼리 같은 분석 자산은 `../log-archive`로 옮겼고, 여기 남은 `aws_flow_log`는 VPC에 붙는 리소스라 VPC와 함께 매일 사라지는 게 맞다(재생성 비용도 사실상 0 — 과금은 S3 저장분뿐). 대상 버킷은 로그 계정 소유라 data source로 읽을 수 없으므로(크로스 계정 조회엔 저쪽 자격증명이 필요) ARN을 **조립**하고, 쓰기 인가는 저쪽 버킷 정책(AWSLogDeliveryWrite + SourceAccount 조건)이 맡는다. 버킷 이름 규칙이 `../log-archive/log-archive.tf`와 반드시 일치해야 한다는 암묵 계약도 명시돼 있다.

### L16–27 · locals

`vpc_flow_logs_s3_prefix = "vpc-flow-logs"`(버킷 내 경로), `log_archive_bucket_arn` — `arn:aws:s3:::gochuchamchi-log-archive-${var.log_archive_account_id}` 형태의 조립, 공통 태그 맵.

### L29–60 · resource "aws_flow_log" "vpc"

- `traffic_type = "ALL"` — ACCEPT/REJECT 모두 기록. 포트스캔·차단 흔적 분석에는 REJECT가 특히 중요하다.
- `log_destination` — 중앙 버킷 ARN + prefix. `log_destination_type = "s3"` — CloudWatch Logs 경유보다 장기 보관 비용이 싸고, Athena 분석 대상이 되는 경로다.
- `lifecycle.precondition` — `log_archive_account_id`가 비어 있으면 "로그 계정 생성 후 계정 ID를 변수에 넣어야 합니다(../log-archive 먼저 apply)"라는 명확한 메시지로 plan 실패. 빈 문자열로 ARN이 조립돼 이상한 대상에 배달 시도하는 것을 막는다.
- `max_aggregation_interval = 600` — 기본 600초 집계. 포트스캔 타임라인 분석엔 충분한 해상도이면서 S3 객체 수(=PUT 비용·소파일 문제)를 줄인다.
- `destination_options` — `file_format = "parquet"`(Athena 스캔 비용·속도에 유리한 컬럼 포맷), `hive_compatible_partitions = false` + `per_hour_partition = false` — CloudTrail 테이블과 같은 partition projection 방식(yyyy/MM/dd 경로)을 쓰기 위해 hive 호환 경로를 일부러 끈 것이다. 분석 스키마와 저장 경로 규약이 한 세트라는 것을 보여준다.

### L62–65 · output "vpc_flow_logs_id"

Flow Log ID 노출(검증용).

---

## terraform/dns.tf (53줄)

Route53 존 조회와 ACM 인증서(서울 리전, ALB TLS 종단용) 발급·검증을 담당한다. 한 가지 바로잡을 것: L1–5와 L44의 주석은 "gochuchamchi.shop 호스팅 영역을 **새로 생성**", "Gabia NS 재지정 필요"라고 말하지만 이는 예전 도메인 시절의 서술이 남은 것이다. 현재 코드는 존을 생성하지 않고 `data`로 **조회**하며, 대상 도메인은 `var.domain_name`의 기본값 `kycj.click`(NS 위임 완료)이다. L12의 output description("변경 불필요 — 존을 재생성하지 않으므로 고정됨")이 현재 상태를 정확히 반영한다.

### L6–8 · data "aws_route53_zone" "this"

`name = var.domain_name`으로 기존 호스팅 존 조회. 존을 리소스로 만들지 않는 것이 중요하다 — 존을 매일 재생성하면 NS 레코드 4개가 매일 바뀌어 등록기관 위임을 매일 다시 해야 하는 지옥이 된다. 존은 사실상 상시 리소스이므로 이 루트 밖에 두고 조회만 한다.

### L10–13 · output "name_servers"

조회된 존의 NS 목록. 존을 재생성하지 않으므로 이 값은 고정이고, 등록기관 쪽 변경도 불필요하다.

### L18–26 · resource "aws_acm_certificate" "this"

- `domain_name = var.domain_name` + `subject_alternative_names = ["www.", "argocd.", "grafana."]` — 앱 본체와 www, ArgoCD UI, Grafana UI까지 한 장으로 커버하는 SAN 인증서.
- `validation_method = "DNS"` — 이메일 검증과 달리 사람 개입 없이 자동화 가능하고, 아래 레코드 리소스와 결합해 전 과정이 코드가 된다.
- `lifecycle.create_before_destroy = true` — 인증서 교체 시 새 것을 먼저 만들고 옛 것을 지워, ALB 리스너가 인증서 없는 순간을 겪지 않게 한다.

### L28–42 · resource "aws_route53_record" "cert_validation" (for_each)

`domain_validation_options`(도메인+SAN마다 하나씩 나오는 검증 챌린지)를 도메인명 키의 맵으로 변환해 CNAME 검증 레코드를 만든다. for_each를 count가 아닌 맵으로 쓰는 것은 SAN 목록 순서가 바뀌어도 리소스 주소가 안정적이도록 하는 정석 패턴이다. `ttl = 60` — 검증 레코드는 빨리 전파될수록 좋다.

### L45–48 · resource "aws_acm_certificate_validation" "this"

실제 발급 완료(ISSUED)까지 기다리는 대기 리소스. `validation_record_fqdns`로 위 레코드들과 순서를 건다. 검증은 퍼블릭 DNS에서 레코드가 조회되어야 끝나므로 NS 위임이 선행 조건인데, kycj.click은 이미 위임이 끝나 있어 매일 아침 재발급·검증이 몇 분 안에 자동 통과한다.

### L50–53 · output "acm_certificate_arn"

서울 리전 인증서 ARN — ALB TLS 종단용. CloudFront용 us-east-1 인증서는 별개(edge 담당 파일)다.

---

## terraform/kms.tf (17줄)

이름과 달리 이제 KMS 키를 만들지 않는 파일이다. 헤더 주석이 이관의 역사를 기록한다: logs 키는 `../account-baseline/kms-logs.tf`로, data 키는 `../persistent/kms-data.tf`로 갔다(2026-08-07). data 키를 persistent로 옮긴 이유가 이 프로젝트에서 가장 교훈적인 실패 모드 중 하나다 — **일일 destroy가 키를 매일 죽이면서(7일 삭제 대기 예약) ARN이 매일 바뀌었고, DR 백업 복구 지점이 키보다 오래 살아 "백업은 있는데 복호화 키가 소멸"하는 상태**가 생길 수 있었다. 암호화 키는 그것으로 암호화된 데이터의 수명보다 오래 살아야 한다는 원칙이 계층 분리(상시 persistent에 1회 생성, 여기서는 별칭 조회)로 귀결됐다.

### L14–17 · output "kms_data_key_arn"

외부 스크립트·문서가 이 루트의 output을 읽던 호환성을 유지하기 위한 재노출 — 값은 persistent 키(`data.aws_kms_key.data.arn`)다. 리소스를 옮겨도 소비자 인터페이스는 유지하는 배려다.

---

## terraform/s3.tf (198줄)

상품 이미지 버킷 `images`와 그것을 외부에 서빙하는 CloudFront(OAC) 파이프라인 전체를 담는다. 참고로 배경에서 언급되는 세 버킷 중 이 파일에 있는 것은 `images`뿐이다 — `k8s_manifests`는 k8s-deploy.tf(L12), 도쿄 DR 대상 `images_dr`과 CRR 설정은 dr.tf(enable_dr 스위치 뒤) 소관으로 각각 다른 섹션에서 다룬다. 셋 모두 `force_destroy = true`라는 공통점이 있다.

### L1–4 · data "aws_caller_identity" "current"

현재 자격증명의 계정 정보 조회. 버킷명 접미사와 account-guard, db-zero-trust의 ARN 조립까지 루트 전체가 이 data를 공유한다. 파일 첫 주석이 버킷 명명의 사연을 설명한다 — S3 버킷명은 AWS 전역 유일이어야 하는데 예전 계정이 이미 `gochuchamchi-images`를 쓰고 있어, 새 계정에서는 계정 ID를 붙여 충돌을 피한다.

### L6–13 · resource "aws_s3_bucket" "images"

- `bucket = "gochuchamchi-images-<account_id>"`.
- `force_destroy = true` — L9–11 주석이 이 프로젝트에서 가장 정직한 트레이드오프 선언이다: 객체가 남아 있으면 destroy가 BucketNotEmpty로 막히는 일이 "실제로 매번 걸렸"고, destroy/apply를 반복하는 구조라 자동 비우기를 켠다. 그리고 ※ 경고 — **destroy 시 사용자가 업로드한 상품 이미지까지 전부 삭제된다**. 즉 이 버킷은 매일 밤 업로드분째 지워진다. 학생 프로젝트의 시연 데이터라는 성격상 "매일의 destroy 확실성 > 이미지 영속성"으로 판단한 의도적 선택이며, 운영이라면 이 한 줄이 절대 있어서는 안 되는 자리다.

### L15–17 · (주석) 계정 수준 퍼블릭 차단의 이관

계정 수준 S3 Public Access Block은 account-baseline으로 옮겼다 — 계정 싱글턴 리소스를 일일 destroy 계층에 두면 매일 껐다 켜는 사이클이 되기 때문. "리소스의 수명 등급에 맞는 계층에 둔다"는 이 루트의 반복 원칙이다.

### L19–25 · resource "aws_s3_bucket_ownership_controls" "images"

`BucketOwnerEnforced` — ACL을 완전히 비활성화하고 모든 객체 소유권을 버킷 소유자로 강제. 접근 제어를 버킷 정책 하나로 단일화하는 현행 권장값이다.

### L29–35 · resource "aws_s3_bucket_versioning" "images"

`status = "Enabled"`. 목적은 복구가 아니라 **CRR의 전제 조건**이다(주석: 복제는 원본/대상 모두 버전관리 필수 — dr.tf의 도쿄 CRR이 소비). 버전이 쌓이는 비용은 아래 라이프사이클이 통제한다.

### L38–46 · resource "aws_s3_bucket_server_side_encryption_configuration" "images"

`sse_algorithm = "AES256"`(SSE-S3) 명시. 기본 동작에 의존하지 않고 IaC로 암호화 의도를 드러낸다. 공개 서빙되는 이미지라 KMS까지는 과하다는 균형 감각 — tfstate(SSE-KMS 전환)와 대비되는 데이터 등급 판단이다.

### L48–65 · resource "aws_s3_bucket_lifecycle_configuration" "images"

`noncurrent_version_expiration.noncurrent_days = 7` — 덮어쓰기·삭제로 비활성이 된 이전 버전을 7일 뒤 삭제해 버전관리의 저장 비용을 상한한다. `filter { prefix = "" }`로 전체 적용. `depends_on = [aws_s3_bucket_versioning.images]` — 버전관리가 먼저 켜져 있어야 하는 순서 명시.

### L70–77 · resource "aws_s3_object" "texture"

메인 페이지가 배경으로 참조하는 `texture.png`를 terraform이 직접 업로드한다. 주석의 사연: 버킷은 코드로 만들지만 내용물은 관리 밖이라, 재생성 때마다 수동 업로드를 잊으면 배경이 403으로 깨졌다 — 일일 재생성 체제에서 "아침마다 필요한 정적 자산"은 코드에 넣는 게 답이었다. `etag = filemd5(...)`로 파일이 바뀔 때만 재업로드, `cache_control = "public, max-age=31536000"`으로 1년 캐시(CloudFront·브라우저 캐시 효율).

### L79–88 · resource "aws_s3_bucket_public_access_block" "images"

버킷 수준 4중 퍼블릭 차단 전부 true — 이 버킷은 CloudFront를 통해서만 읽힌다. `depends_on = [aws_s3_bucket_policy.images_cloudfront_read]`가 미묘한데, `block_public_policy = true`가 걸린 뒤에는 정책 PUT이 퍼블릭으로 오판되면 거부될 수 있으므로 정책을 먼저 붙이는 순서를 고정한 것이다(cloudfront_read 정책은 퍼블릭 정책이 아니라 계정 차단과 충돌하지 않는다는 L17 주석과 세트).

### L90–96 · resource "aws_cloudfront_origin_access_control" "images"

OAC — 구식 OAI를 대체하는 현행 방식. `signing_behavior = "always"` + `signing_protocol = "sigv4"`로 CloudFront가 S3에 보내는 모든 요청에 SigV4 서명을 실어, S3 쪽에서 "서명된 CloudFront 요청"만 인가할 수 있게 한다.

### L98–100 · data "aws_cloudfront_cache_policy" "caching_optimized"

AWS 관리형 `Managed-CachingOptimized` 정책 조회 — 정적 자산에 맞는 표준 캐시 정책(쿼리스트링·쿠키 무시, 압축 지원)을 직접 정의하는 대신 ID로 참조한다.

### L102–111 · resource "aws_cloudfront_response_headers_policy" "images_security"

응답에 `X-Content-Type-Options: nosniff`(`content_type_options`, `override = true`)를 강제한다. 대상이 **사용자 업로드** 이미지라는 점에서 의미가 있다 — 이미지로 위장해 업로드된 콘텐츠를 브라우저가 스니핑으로 HTML/JS 취급해 실행하는 류의 공격을 헤더 수준에서 차단한다.

### L113–150 · resource "aws_cloudfront_distribution" "images"

- `enabled` / `is_ipv6_enabled = true`, `price_class = "PriceClass_200"` — 북미·유럽·아시아 엣지까지 포함(한국 사용자에게 필요한 등급이면서 전체 등급보다 저렴).
- `origin` — 오리진은 버킷의 `bucket_regional_domain_name`(리전 도메인 — 글로벌 도메인은 리다이렉트 이슈가 있어 리전 도메인이 정석), `origin_access_control_id`로 위 OAC 연결.
- `default_cache_behavior` — `viewer_protocol_policy = "redirect-to-https"`, `allowed_methods = GET/HEAD/OPTIONS`·`cached_methods = GET/HEAD`(읽기 전용 배포), 관리형 캐시 정책 + 보안 헤더 정책 연결, `compress = true`.
- `restrictions.geo_restriction = "none"`, `viewer_certificate.cloudfront_default_certificate = true` — 이미지 서빙은 `*.cloudfront.net` 기본 도메인·기본 인증서를 그대로 쓴다(커스텀 도메인이 필요한 앱 본체 배포는 edge.tf 소관).

### L152–188 · resource "aws_s3_bucket_policy" "images_cloudfront_read"

두 문장짜리 정책. (1) `AllowCloudFrontReadOnly` — Principal이 `cloudfront.amazonaws.com` 서비스이되 `Condition`의 `AWS:SourceArn`이 **이 배포의 ARN**과 일치할 때만 `s3:GetObject` 허용 — OAC 시대의 정석 패턴으로, 다른 계정의 CloudFront 배포가 이 버킷을 오리진으로 삼는 confused deputy를 차단한다. (2) `DenyInsecureTransport` — `aws:SecureTransport = false`인 모든 요청(평문 HTTP)을 전면 Deny. Deny는 어떤 Allow보다 우선하므로 전송 암호화가 정책 수준에서 강제된다.

### L190–193 · moved (images_public_read → images_cloudfront_read)

퍼블릭 읽기 정책 시절에서 CloudFront 전용 정책으로 전환할 때 state 주소를 이동한 기록 — 이름이 바뀌어도 리소스를 지웠다 다시 만들지 않게 한다. 버킷의 공개 방식이 "퍼블릭 → OAC 사설"로 진화한 역사가 이 블록 하나에 남아 있다.

### L195–198 · output "images_cloudfront_domain_name"

앱이 이미지 URL 구성에 쓰는 CloudFront 도메인.

---

## terraform/ecr.tf (24줄)

리소스가 하나도 없는 파일이다 — 그 자체가 설계의 결과다. 헤더 주석이 두 번의 이관을 기록한다: (1) 저장소와 CI push 권한(OIDC/IAM)은 2026-08-06 `../persistent`로 — destroy가 이미지를 지워 매번 503을 만들던 문제를 끊기 위해. (2) 계정 단위 스캔 설정(Inspector2 enabler / ENHANCED 스캔)은 2026-08-07 `../account-baseline`으로 — **Inspector2의 destroy가 15분 타임아웃 후 tainted로 남아 다음 apply를 망가뜨리던** 문제(8/4 §5.2)를 일일 destroy 경로에서 빼내기 위해. "destroy가 매일 도는 계층에는 destroy가 잘 되는 리소스만 남긴다"는 운영 규율이다.

### L16–19 · output "ecr_repository_url"

persistent가 소유한 저장소 URL 재노출 — gitops 저장소의 이미지 참조와 CI 워크플로 push 대상이 읽는다.

### L21–24 · output "github_actions_ecr_role_arn"

CI 워크플로의 `role-to-assume` 값 재노출. 둘 다 "실체는 ../persistent 관리"임을 description에 명시해 소비자가 소유권을 오해하지 않게 한다.

---

## terraform/efs.tf (84줄)

EKS 파드가 PVC로 마운트하는 공유 스토리지 계층이다. 파일시스템 → SG → mount target → StorageClass 순으로 AWS와 K8s를 관통한다.

### L8–21 · resource "aws_efs_file_system" "this"

- `creation_token = "gochuchamchi-efs"` — 생성 멱등성 보장용 토큰.
- `encrypted = true` + `kms_key_id = data.aws_kms_key.data.arn` — 전 구간 KMS CMK 원칙(2026-08-07 복원). 주석의 핵심: 키가 persistent 계층에 있어 일일 destroy와 무관하게 ARN이 고정된다 — "키 변경 = 파일시스템 교체" 리스크는 키가 매일 순환하던 구조의 문제였고 이제 구조적으로 소멸했다. EFS는 암호화 설정·키가 생성 시 고정이라(변경 = 재생성) 키 안정성이 곧 파일시스템 안정성이다.
- `performance_mode = "generalPurpose"`(저지연 기본 모드), `throughput_mode = "bursting"`(저장량 비례 버스트 — 소규모엔 프로비저닝 처리량보다 경제적).

### L23–46 · module "efs_sg"

NFS 2049/tcp를 `referenced_security_group_id = module.eks.node_security_group_id`(EKS 모듈이 만든 노드 SG)로만 허용. rds_sg·redis_sg와 동일한 "워크로드 정체성" 패턴 — 노드가 아닌 어떤 것도 NFS에 닿을 수 없다. egress는 전체 허용.

### L49–55 · resource "aws_efs_mount_target" "this" (count)

프라이빗 서브넷마다 하나씩(count = 2). 주석대로 private_subnets[0]/[1]이 var.azs[0]/[1]에 대응하므로 두 AZ가 자동으로 커버된다 — 노드가 어느 AZ에 있든 같은 AZ의 mount target으로 붙어 AZ 간 데이터 요금과 지연을 피한다.

### L60–79 · resource "kubernetes_storage_class_v1" "efs"

- `storage_provisioner = "efs.csi.aws.com"`, `parameters`: `provisioningMode = "efs-ap"`(PVC마다 EFS 액세스포인트를 자동 생성 — PVC별 독립 디렉터리), `fileSystemId`(위 파일시스템), `directoryPerms = "700"`.
- `reclaim_policy = "Retain"` — PVC를 지워도 데이터 디렉터리는 남긴다(실수 방어).
- `depends_on = [aws_efs_mount_target.this, module.efs_csi_pod_identity, module.eks]` — 마지막 `module.eks`(모듈 **전체**)가 이 블록의 교훈이다. mount target·pod identity는 금방 끝나는 리소스라, 이게 없으면 access entry가 API 서버 인증 웹훅에 전파되기 전에 StorageClass 생성 요청이 먼저 나가 403 Forbidden이 났다(2026-07-29 실제 발생: "cannot create resource storageclasses ... at the cluster scope"). "모듈 output 참조만으로는 모듈 내부 전체와 순서가 잡히지 않는다"는, eks-pod-identity.tf destroy 교착과 같은 계열의 문제를 apply 방향에서 겪은 사례다.

### L81–84 · output "efs_file_system_id"

PVC volumeAttributes·StorageClass 파라미터로 참조되는 파일시스템 ID.

---

## terraform/redis.tf (77줄)

세션 스토어 Redis다. 첫 주석이 존재 이유를 요약한다 — ALB가 요청을 다른 파드로 분산해도 로그인 상태가 유지되도록 여러 파드가 세션을 공유한다. 2026-08-04 제로트러스트 전환의 결과로 `aws_elasticache_cluster`가 아니라 replication_group 리소스를 쓴다: cluster 리소스는 전송 암호화·AUTH를 API 레벨에서 지원하지 않기 때문이다. 교체 시 캐시가 재생성되어 기존 세션이 초기화됐지만, 세션 스토어라 실질 피해는 "재로그인이 전부"라는 판단까지 주석에 있다.

### L16–35 · module "redis_sg"

6379/tcp를 EKS 노드 SG 참조로만 허용. 그리고 **egress 블록이 아예 없다** — 2026-08-04 제로트러스트 조치로 전면 제거했다. 캐시는 아웃바운드 커넥션을 시작할 일이 없고, 클라이언트 요청에 대한 응답은 SG의 stateful 특성으로 자동 허용된다. 만약 캐시가 밖으로 나가려 한다면 그 자체가 침해 신호다(rds_sg와 동일 논리).

### L37–40 · resource "aws_elasticache_subnet_group" "this"

`subnet_ids = module.vpc.database_subnets` — RDS와 같은 isolated 서브넷. NACL·라우팅 차단의 보호를 함께 받는다.

### L47–50 · resource "random_password" "redis_auth"

AUTH 토큰 32자, `special = false` — ElastiCache 제약(16~128자, `/`·`"`·`@`·공백 불가)을 피해 영숫자만 생성한다. 주석이 이 값의 보안 등급을 정확히 매긴다: `auth_token`은 리소스 인자로만 설정 가능해서 **Terraform(state) 경유가 불가피**하다 — 감사보고서 #1이 정의한 ESO 이관 트리거에 해당하는 값이다. state가 S3 암호화+잠금 뒤에 있어 등급은 낮지만 ESO 도입 시 이 값부터 이관 대상이고, 대비되는 사례로 DB 앱 자격증명은 배스천 런타임 생성(현재는 IAM 토큰)이라 state에 안 남는다.

### L55–77 · resource "aws_elasticache_replication_group" "this"

- `replication_group_id = "gochuchamchi-redis"`, `engine = "redis"`, `engine_version = "7.1"`, `node_type = "cache.t3.micro"`, `parameter_group_name = "default.redis7"`.
- `num_cache_clusters = 1` — 이름은 replication_group이지만 1노드면 복제본 없는 단일 노드라 비용은 cluster 리소스 시절과 동일하다. 운영 전환 시 2노드 + `automatic_failover_enabled = true`가 세트라는 이행 경로가 주석에 있다. `automatic_failover_enabled = false` / `multi_az_enabled = false`는 1노드의 필연.
- `transit_encryption_enabled = true` — 세션 데이터(로그인 상태)가 VPC 안이라도 평문으로 다니지 않는다. 앱은 rediss(TLS)로 접속(`SPRING_DATA_REDIS_SSL_ENABLED`, k8s-deploy.tf).
- `at_rest_encryption_enabled = true` — 성능 영향·추가 비용이 없으므로 "켜지 않을 이유가 없다".
- `auth_token = random_password.redis_auth.result` — SG가 뚫린 뒤의 측면이동을 가정한 인증 요구. 네트워크 도달만으로 세션 저장소를 읽을 수 없다.
- `apply_immediately = true` — 실습용이라 변경 즉시 반영. 운영에선 유지보수 윈도우 검토. rds.tf가 이 값을 설정하지 않는 것(기본 false)과 대비되는데, 세션 캐시는 잠깐의 재접속 영향이 작고 DB는 크다는 등급 차이다.

---

## terraform/rds.tf (182줄)

MariaDB RDS 본체다. SG → RDS 모듈 → 마스터 시크릿 output 순서이고, 제로트러스트 조치(전송 암호화·감사 로그·IAM 인증)의 주석 밀도가 이 루트에서 가장 높다.

### L5–35 · module "rds_sg"

- `ingress_rules.mariadb_from_nodes` / `mariadb_from_bastion` — 3306/tcp를 EKS 노드 SG와 배스천 SG **참조**로만 허용. L13–14 주석이 이 루트의 보안 어휘를 정의한다: "CIDR 허용은 '네트워크 위치'를 신뢰하지만, referenced_security_group_id는 '워크로드 정체성'을 신뢰함 → NAT/같은 VPC의 다른 자원이 침해돼도 DB 접근 불가". 배스천 인그레스는 스키마 초기화(rds-schema-init.tf)와 IAM 계정 생성(db-zero-trust.tf)용이다.
- egress 전면 제거(2026-08-04) — DB는 아웃바운드를 "시작"할 일이 없고, 응답은 stateful로 자동 허용되며, DB가 밖으로 나가려 하면 그 자체가 침해 신호. Multi-AZ 복제·managed rotation은 AWS 내부 경로라 고객 SG를 타지 않으므로 이 제거로 깨지지 않는다는 확인까지 주석에 있다.

### L37–177 · module "rds" (terraform-aws-modules/rds/aws ~> 6.0)

- `identifier = "gochuchamchi-db"`, `engine = "mariadb"`, `engine_version = "10.11"`, `family = "mariadb10.11"`(파라미터 그룹 패밀리), `major_engine_version = "10.11"`(옵션 그룹용), `instance_class = "db.t3.micro"`.
- `allocated_storage = 20` + `max_allocated_storage = 100` — 20GB 시작, 스토리지 오토스케일링 상한 100GB(가득 차서 멈추는 사고 방지).
- `db_name = "gochuchamchi"`, `username = "admin"`, `port = 3306`.
- `parameters`의 `require_secure_transport = 1`(apply_method = immediate) — 평문 접속을 TLS 핸드셰이크 단계에서 거부한다. "같은 VPC 안이니까 평문이어도 괜찮다"는 네트워크 위치 신뢰를 버리는 조치이며, 접속하는 모든 쪽(앱 sslMode, 배스천 스크립트의 `--ssl`, 앱 계정의 REQUIRE SSL)을 TLS로 맞춰둔 것과 세트다. 동적 파라미터라 원칙상 재부팅 불필요이나, 기존 인스턴스 적용 시 ParameterApplyStatus가 pending-reboot로 남으면 reboot 1회가 필요하다는 운영 절차도 주석에 있다.
- **L68–76 정정 주석** — 이 자리에 원래 "MariaDB는 IAM DB 인증 미지원이라 제외"라고 적혀 있었으나 **사실이 아니었다**. `aws rds describe-orderable-db-instance-options`로 실제 엔진·버전·클래스를 조회해 `SupportsIAMDatabaseAuthentication = true`를 확인했고(같은 조건의 MySQL과 차이 없음), Aurora가 MySQL/PostgreSQL만 지원하는 제약과 혼동한 오류로 판정해 커밋으로 정정했다. 같은 오류가 있던 문서 2건도 함께 고쳤다. "잘못된 근거로 배제된 기능은 근거를 재검증해 되살린다"는 좋은 사례다.
- `options`의 `MARIADB_AUDIT_PLUGIN` — 감사 로그 축. `SERVER_AUDIT_EVENTS = "CONNECT,QUERY_DDL,QUERY_DCL,QUERY_DML_NO_SELECT"` — 접속(실패 포함)과 DDL/DCL에 더해 2026-08-12 DML(SELECT 제외)을 추가했다. 그전에는 "누가 들어왔다"만 보이고 "들어와서 뭘 했다"가 안 보였는데, 앱 계정이 DML만 가능한 최소권한이라 DDL/DCL 로그는 사실상 비어 있었다 — 침해 시 실제로 남는 흔적은 DML이므로 이걸 켜야 감사 축이 완성된다. SELECT를 뺀 이유도 명확하다: 앱의 상시 조회로 로그량·비용이 급증하는 데 비해 "누가 데이터를 바꿨는가"라는 감사 질문에 기여하지 않는다(유출 탐지가 필요해지면 QUERY_DML로 승급). `SERVER_AUDIT_EXCL_USERS = "rdsadmin"` — AWS 내부 헬스체크 계정의 노이즈 제외. 쿼리 텍스트는 기본 1024자까지만 기록된다는 한계 인지도 주석에 있다.
- `enabled_cloudwatch_logs_exports = ["audit", "error"]` — audit는 GuardDuty/Athena 연계·무단접속 추적용으로 `/aws/rds/instance/gochuchamchi-db/audit`에, error는 Grafana의 aws-errors-overview 대시보드가 조회하는 로그 그룹 의존성 때문에 켠다.
- `manage_master_user_password = true` — 마스터 비밀번호를 코드·변수·state에 두지 않고 RDS가 Secrets Manager에서 자동 생성·관리(rds!로 시작하는 관리형 시크릿). 이 값의 소비자는 배스천뿐이다(iamRole.tf).
- `iam_database_authentication_enabled = true` — 2026-08-12 활성화. L131–144 주석이 이행 전략의 핵심을 담는다: 켜는 것 자체는 기존 접속에 무영향(비밀번호 인증 그대로, IAM 토큰이 "추가로 가능"해질 뿐)이지만, AWSAuthenticationPlugin으로 만든 계정은 비밀번호 인증이 불가능해지므로 기존 계정을 그대로 전환하면 앱이 즉시 접속 실패한다. 그래서 "IAM 전용 계정 추가 → 앱 전환 → 구계정 제거" 3단계 순서가 필수였다(db-zero-trust.tf에서 완결). 토큰 수명 15분 고정(AWS 사양), IAM 인증 연결은 SSL 필수(이미 require_secure_transport=1이라 충족)라는 제약도 명시.
- `vpc_security_group_ids = [module.rds_sg.id]`, `create_db_subnet_group = true` + `subnet_ids = module.vpc.database_subnets` — isolated 서브넷 배치.
- `multi_az = false` — 학습용 단일 AZ(비용 절반). 운영 전환 시 true.
- `publicly_accessible = false`.
- `storage_encrypted = true` — 모듈 기본값이지만 보안 리뷰 때 바로 보이도록 명시. 주석의 함정 경고: 기존 인스턴스에서 이 항목이 plan에 "변경"으로 뜬다면 실제로는 암호화가 꺼져 있던 것이고, 그대로 apply하면 재생성(데이터 삭제)이므로 중단하고 스냅샷 경유로 전환하라.
- `kms_key_id = data.aws_kms_key.data.arn` — 관리형 키(aws/rds)에서 우리 CMK로 전환(2026-08-07). kms.tf 주석은 "RDS/EFS 전용 키"라 했지만 실제로는 지정이 없어 관리형 키를 쓰고 있었다는 코드-문서 불일치를 해소한 것. CMK는 키 정책·CloudTrail 추적·교체 주기를 우리가 통제한다는 차이가 있고, 키 변경은 인스턴스 교체를 유발하므로 전체 재구축 시점에만 적용한다는 조건이 붙었다.
- `backup_retention_period = 1` — 자동 백업 1일. 매일 재생성되는 DB라 장기 보존은 무의미하다.
- `skip_final_snapshot = var.rds_skip_final_snapshot`(기본 true) — variables.tf 해설 참조. `final_snapshot_identifier_prefix = "gochuchamchi-final"` — false로 바꿀 경우를 대비한 prefix 방식(모듈이 유니크 suffix를 붙임). timestamp() 기반 이름은 매 plan마다 값이 바뀌어 상시 diff를 만들므로 쓰지 않는다(8/7 결정).
- `deletion_protection = false` — 매일 destroy하는 체제의 필연. 운영이라면 true가 정석이다.
- 함정 하나: `apply_immediately`를 설정하지 않으므로 모듈 기본 false다 — 무재부팅 변경도 다음 유지보수 윈도우까지 `PendingModifiedValues`에 잠시 머물 수 있다. 일일 재생성 체제에선 다음 날 아침 새 인스턴스가 최신 설정으로 뜨므로 실질 문제는 없지만, 당일 반영을 기대하면 어긋난다.

### L179–182 · output "rds_secret_arn"

마스터(admin) 관리형 시크릿 ARN. description이 권한 경계를 선언한다 — 배스천의 스키마 초기화·운영 작업 전용이며, **앱은 이 시크릿에 접근 권한이 없다**(앱은 IAM 토큰, db-zero-trust.tf).

---

## terraform/rds-schema-init.tf (84줄)

"매일 새로 태어나는 빈 DB"에 스키마를 자동 적용하는 파일 — 일일 사이클의 필수 부품이다. 로컬에서 DB에 직접 붙을 수 없으므로(isolated 서브넷 + SG) 배스천에 SSM SendCommand를 보내 배스천이 DB에 붙게 하는 2단 구조이며, local-exec 인터프리터는 이 프로젝트의 작업 환경인 PowerShell이다.

### L5–84 · resource "null_resource" "apply_db_schema"

- `triggers` — `schema_hash = filemd5(schema.sql)`(스키마 파일이 바뀌면 재실행)과 `rds_id = data.aws_db_instance.this.db_instance_identifier`(DB가 재생성되면 재실행 — data source는 k8s-deploy.tf L30에 있다). 매일 아침 DB가 새로 뜨므로 사실상 매일 실행된다.
- `depends_on` — module.rds(DB), module.bastion_host(실행 주체), `aws_s3_object.schema_sql`(k8s-deploy.tf가 `k8s_manifests` 버킷에 올려두는 schema.sql — 배스천은 S3에서 받아간다).
- provisioner 스크립트는 실패 경험이 켜켜이 쌓인 형태다:
  1. **배스천 SSM 온라인 대기** — `describe-instance-information`의 PingStatus를 15초 간격 최대 20회 폴링. 갓 부팅한 배스천의 SSM 에이전트 등록 전에 명령을 보내는 실패를 막는다.
  2. **RDS available 대기** — L29–33 주석이 이 프로젝트에서 가장 값진 교훈 중 하나다: `depends_on`은 리소스 "생성 순서"만 보장할 뿐 "접속 가능" 상태까지 기다려주지 않는다. 2026-08-03에 스키마 적용이 RDS 완료보다 5분 먼저 실행돼 통째로 실패했는데, 상태 검사가 없어 terraform은 성공으로 기록했고, 이후 filemd5 트리거가 그대로라 재apply해도 재시도되지 않아 "테이블 없는 DB"(회원가입 500)가 계속 남았다. 그래서 `DBInstanceStatus`를 최대 40회 폴링하고 실패 시 exit 1로 명시 실패시킨다.
  3. **SSM 명령 구성** — mysql 클라이언트 설치(`mariadb105`), S3에서 schema.sql 다운로드, 마스터 시크릿을 Secrets Manager에서 조회해 python으로 password 필드 추출. 비밀번호 취급이 정교하다: `mysql -p"$PASS"` 형태는 ps 목록·SSM 커맨드 로그에 비밀번호가 남으므로 **`MYSQL_PWD` 환경변수 접두**로 넘긴다(어느 쪽에도 안 남음). 구 방식이던 `.my.cnf`는 비밀번호에 `#`이 섞이면 옵션 파일 파서가 주석으로 잘라 **조용히 실패**하는 함정이 있어 폐기했다(RDS 관리형 비밀번호는 `#` 포함 가능).
  4. `mysql --ssl` — require_secure_transport=1 이후에도 접속되도록 명시(mariadb 클라이언트 기본이 평문 시도). 그리고 `mysql ...; rc=$?; rm ...; exit $rc` — `mysql; rm`으로 두면 그 줄의 종료코드가 항상 성공하는 rm의 것이 되어 mysql 실패가 SSM Success로 가려지므로, 종료코드를 보존해 내보낸다.
  5. **결과 폴링과 검증** — 고정 Sleep 후 출력만 하는 방식이면 SSM이 실패해도 local-exec이 exit 0으로 끝나 terraform이 성공으로 기록하므로, 완료까지 폴링하고 Status가 Success가 아니면 stderr를 출력하고 exit 1. 재시도 방법(`terraform taint null_resource.apply_db_schema`)까지 에러 메시지에 안내한다.

이 파일 전체가 "명령형 절차를 선언형 도구에 얹을 때는 성공 판정을 스스로 엄격하게 해야 한다"는 원칙의 구현체다.

---

## terraform/db-zero-trust.tf (165줄)

앱 전용 DB 계정 체계의 현재형이다. L1–37 헤더는 역사 기록으로 남겨둔 것인데 요지는 이렇다 — 원래 앱 파드가 마스터(admin)로 접속했고(앱 침해 = 즉시 DBA 권한), 마스터 비밀번호가 tfstate에 평문으로 들어가는 문제까지 있었다. 이를 [최소권한] DML만 가능한 앱 전용 계정, [명시적 검증] REQUIRE SSL, [침해 가정] 비밀번호를 배스천 런타임에서 생성해 state에 단 한 번도 넣지 않는 구조로 바꿨다. 그리고 **2026-08-13(커밋 dbae59c), 그 비밀번호 계정 `gochuchamchi_app` 자체를 제거했다** — Secrets Manager 시크릿, K8s Secret, 배스천 프로비저닝 112줄까지 일체. 이유가 명문이다: 토큰 전환의 목적이 "상시 유효한 자격증명을 없애는 것"인데 비밀번호 계정을 남기면 목적이 반감된다. 앱이 토큰을 쓰기 시작한 뒤에도 DB_PASS는 파드 환경변수에 계속 앉아 있었고, 쓰이지도 않으면서 파드 침해 시 그대로 읽히는 무기한 유효 값이었다 — "안 쓰는 문이라도 열려 있으면 문이다." 청소가 간단했던 이유도 일일 사이클 덕분이다: DB가 매일 재생성되므로 계정은 매일 아침 새로 만들어지던 것이고, 만드는 코드를 지우면 다음 아침부터 그 계정은 태어나지 않는다. DROP USER로 쫓아다닐 잔재가 없다.

L39–61의 두 번째 헤더는 IAM 토큰 계정 도입(2026-08-12)의 논리다: AWSAuthenticationPlugin 계정은 비밀번호 인증이 불가능해지므로(둘 중 하나만 됨) "전환"이 아니라 "추가"로 시작해 서비스 영향 0으로 들어갔고, 순서는 (1) 계정 추가 → (2) 앱 전환(Spring 저장소) → (3) 구계정 제거였다. 비밀번호 대비 이점: 자격증명이 15분 뒤 만료(유출 수명 최소화), dbuser ARN이 DB 리소스 ID/유저명까지 못박혀 "값만 알면 누구나"가 아니라 그 IAM 역할 보유자만 접속 가능, 저장할 비밀번호가 아예 없어 보관·회전 부담 소멸. 앱 접속 URL은 `credentialType=AWS-IAM&sslMode=verify-full&serverSslCert=/app/rds-ca.pem` 형태이고, 토큰 수명 15분(AWS 고정)에 드라이버 플러그인이 10분 캐시로 발급 빈도를 줄인다.

### L63–77 · resource "aws_iam_policy" "app_db_iam_auth"

앱 파드용 `rds-db:connect` 정책. Resource가 `arn:aws:rds-db:<region>:<account>:dbuser:<db_resource_id>/gochuchamchi_app_iam`으로 **유저명까지 리소스에 박혀 있다** — 이 역할로는 다른 DB 유저가 될 수 없고, 유저명을 바꾸면 그 즉시 권한이 끊긴다. `db_instance_resource_id`는 인스턴스 식별자가 아닌 내부 리소스 ID(db-XXXX)라는 점에 주의 — DB가 재생성되면 이 ID가 바뀌므로 정책도 함께 갱신되는데, 둘 다 매일 아침 같은 apply에서 만들어지므로 자연히 정합이 맞는다.

### L79–82 · resource "aws_iam_role_policy_attachment" "app_db_iam_auth"

위 정책을 앱 역할(`gochuchamchi_app_role`, eks-pod-identity.tf)에 부착.

### L87–99 · resource "aws_iam_role_policy" "bastion_db_iam_auth"

배스천에도 같은 `rds-db:connect`를 인라인 정책으로 부여. 목적은 아래 프로비저닝의 마지막 검증 단계 — 실제로 토큰을 발급받아 접속되는지 확인하기 위해서다. 주석이 권한 셈법을 정리한다: 배스천은 이미 마스터 비밀번호를 읽을 수 있으므로(iamRole.tf) 이것은 권한 **확대**가 아니라 같은 수준의 다른 경로다.

### L101–165 · resource "null_resource" "provision_app_db_iam_user"

매일 아침 배스천 SendCommand로 IAM 계정을 다시 만드는 실행부다.

- `triggers` — `rds_id`(DB 재생성 시), `policy_arn`(정책 변경 시), `namespace_uid`(네임스페이스 재생성 = 전체 재구축 신호로 삼음 — 계정은 K8s 리소스가 아니지만 함께 재실행), `script_version`(스크립트 수정 시 수동으로 올려 재실행).
- `depends_on` — module.rds, `null_resource.apply_db_schema`(**GRANT 대상 스키마가 먼저 있어야 한다**), module.bastion_host, `aws_iam_role_policy.bastion_db_iam_auth`(검증 단계에서 배스천이 토큰을 발급하므로 권한이 먼저 붙어 있어야 한다).
- SSM 스크립트: `set -e`(중간 실패 즉시 중단), `umask 077`(생성 파일 600), 마스터 시크릿 조회 → `MYSQL_PWD` 환경변수 인증(rds-schema-init.tf와 동일 원칙) → SQL 파일 생성: `CREATE USER IF NOT EXISTS 'gochuchamchi_app_iam'@'%' IDENTIFIED WITH AWSAuthenticationPlugin AS 'RDS' REQUIRE SSL` + `GRANT SELECT, INSERT, UPDATE, DELETE ON gochuchamchi.*`. 주석이 짚듯 저장되는 비밀값이 없으니 재실행해도 로테이션 개념 자체가 없어 **완전 멱등**이고, 권한은 구 계정과 동일하게 DML만(DDL/DCL 불가 — 인젝션이 터져도 스키마 파괴·권한 상승 원천 차단)이다.
- **검증 단계** — `aws rds generate-db-auth-token`으로 실제 토큰을 발급받아 `gochuchamchi_app_iam`으로 접속하고, `CURRENT_USER()`(정체), `SHOW GRANTS`(권한이 DML뿐인지), `Ssl_cipher`(TLS로 붙었는지)를 확인한다. 토큰도 비밀값이므로 argv가 아닌 env로만 넘긴다(ps 노출 차단). "만들었다"가 아니라 "만든 계정으로 실제 인증·인가·암호화가 성립한다"까지 아침마다 증명하는 것이다.
- 이후 SSM Status 폴링과 실패 시 exit 1, taint 재시도 안내는 rds-schema-init.tf와 같은 패턴.

---

## terraform/iamRole.tf (103줄)

배스천과 NAT 인스턴스의 IAM 역할·인스턴스 프로파일이다. EC2에 붙는 "인프라 운영 주체"의 권한만 있고, 워크로드(파드) 권한은 eks-pod-identity.tf로 분리돼 있다.

### L2–17 · resource "aws_iam_role" "bastion_role"

`ec2.amazonaws.com`이 sts:AssumeRole 할 수 있는 신뢰 정책 — EC2 인스턴스 역할의 표준형. 이 역할 ARN이 main.tf의 EKS access entry(네임스페이스 한정 Edit)에도 연결된다.

### L20–34 · resource "aws_iam_role_policy" "bastion_eks_describe"

`eks:DescribeCluster` 단일 액션 — `aws eks update-kubeconfig`가 클러스터 엔드포인트·CA를 조회하는 데 필요한 **최소 권한**이다. K8s 내부 권한은 IAM이 아니라 access entry가 결정하므로 IAM 쪽은 이거면 충분하다.

### L43–62 · resource "aws_iam_role_policy" "bastion_secrets_read"

`secretsmanager:GetSecretValue`를 **마스터 시크릿 ARN 딱 하나**로 한정한 정책. 주석이 축소의 역사를 담는다: 원래 `rds!*` 와일드카드였는데 이는 "리전 안의 모든 RDS 관리형 마스터 시크릿"을 읽는 과잉 권한이었고, 배스천이 털려도 다른 DB 시크릿으로 번지지 않게 폭발 반경을 좁혔다(2026-08-04). 그리고 2026-08-13, 앱 시크릿 항목(AppSecretManage — 배스천이 앱 비밀번호를 만들어 Put하던 쓰기 권한)이 IAM 토큰 전환으로 시크릿째 사라지면서 **읽기 하나만 남았다**. 쓰기(Put) 권한이 통째로 소멸한 것이 이 변경의 부수 효과라고 주석이 자평한다 — 자격증명 체계를 바꾸자 권한 표면이 저절로 줄어든, 제로트러스트 전환의 이상적인 부작용이다.

### L65–68 · resource "aws_iam_role_policy_attachment" "bastion_ssm"

관리형 정책 `AmazonSSMManagedInstanceCore` — SSM 에이전트가 등록·세션·SendCommand 수신을 하는 데 필요한 권한. SSH 없는 접속 체계의 IAM 측 절반이다(네트워크 측 절반은 인바운드 0의 bastion_host_sg).

### L70–73 · resource "aws_iam_instance_profile" "bastion_instance_profile"

역할을 EC2에 붙이기 위한 래퍼. main.tf의 배스천 모듈이 이름으로 참조한다.

### L78–103 · NAT 쪽 3종 (nat_role / nat_ssm / nat_instance_profile)

배스천과 같은 구조이되 정책은 SSM 하나뿐이다 — NAT는 시크릿을 읽을 일도 EKS를 조회할 일도 없고, 디버깅용 SSM 접속만 필요하다. 역할을 배스천과 공유하지 않고 분리한 것 자체가 최소권한이다(NAT가 침해돼도 마스터 시크릿 읽기 권한이 없다).

---

## terraform/eks-pod-identity.tf (277줄)

"어떤 파드가 어떤 AWS 권한을 갖는가"를 전부 모아둔 파일이다. kubernetes/helm 프로바이더 선언, 플랫폼 컴포넌트 4종(ALB Controller·ExternalDNS·Cluster Autoscaler·EFS CSI)과 Image Updater의 Pod Identity, 그리고 앱 파드의 권한까지. IRSA(OIDC 연동)가 아니라 **EKS Pod Identity**(eks-pod-identity-agent 애드온 + association) 방식이며, terraform-aws-modules/eks-pod-identity/aws `~> 2.0` 모듈을 반복 사용한다.

### L4–17 · provider "helm"

EKS 산출물(endpoint, CA)로 클러스터에 접속한다. 핵심은 `exec` 블록이다 — L1–3 주석: `data.aws_eks_cluster_auth` 토큰은 plan 시점에 1회 발급되고 **15분 만료**라, helm_release가 여러 개에 timeout 600초까지 겹치면 apply 도중 Unauthorized가 났다. exec 플러그인은 프로바이더 호출 시마다 `aws eks get-token`으로 새 토큰을 받아 이 문제를 구조적으로 없앤다. db-zero-trust의 15분 토큰과 같은 "단명 자격증명" 세계의 운영 요령이다.

### L22–33 · provider "kubernetes"

같은 인증 구성. 배스천 없이 로컬에서 K8s 오브젝트를 직접 적용하기 위한 프로바이더로, `enable_cluster_creator_admin_permissions = true` 덕에 apply 실행 주체가 이미 클러스터 admin이라 별도 access entry가 불필요하다는 근거가 주석에 있다.

### L38–52 · module "aws_lb_controller_pod_identity"

- `attach_aws_lb_controller_policy = true` — 모듈이 유지관리하는 ALB Controller 권장 정책(ELB·타겟그룹·SG 조작 등) 부착.
- `associations.alb_controller` — kube-system 네임스페이스의 `aws-load-balancer-controller` ServiceAccount에 역할을 연결. Pod Identity의 신원 단위는 "클러스터+네임스페이스+SA"다.

### L54–95 · resource "helm_release" "aws_load_balancer_controller"

Ingress를 ALB로 실체화하는 컨트롤러. `cleanup_on_fail = true`(실패 시 새로 만든 리소스 정리). 이 블록의 백미는 **destroy 순서를 고정하는 depends_on 7개**와 그 주석이다 — destroy 시 이 컨트롤러가 살아 있는 동안 AWS API에 닿아야 ALB·타겟그룹을 정리하고 Ingress finalizer를 뗄 수 있는데, 경로가 하나라도 먼저 끊기면 교착이 생긴다. 세 번의 실제 교착이 각각 한 줄씩을 낳았다:

1. `module.nat_instance` / `aws_route.private_subnet` — 프라이빗 서브넷 → NAT 경로가 먼저 끊긴 2026-07-29 1차 교착.
2. `module.vpc`(모듈 **전체**) — set 블록의 `module.vpc.vpc_id` 참조는 VPC "리소스"와만 순서를 잡을 뿐, 모듈 안의 퍼블릭 라우트 테이블은 먼저 삭제될 수 있다 → NAT가 인터넷으로 못 나가 API 호출 전부 타임아웃(같은 날 2차 교착).
3. `module.nat_sg` / `module.add_node_sg`(모듈 전체) — SG "그룹"과 SG "규칙"은 별개 리소스다. `nat_sg.id` 참조는 aws_security_group에만 순서를 걸고, 같은 모듈의 `aws_vpc_security_group_*_rule`은 아무도 참조하지 않아 먼저 삭제된다 → 규칙 0개가 된 NAT가 트래픽을 못 받아 타임아웃(2026-07-30 3차 교착).

"모듈 output 참조는 모듈 내부 전체에 대한 의존이 아니다"라는 Terraform 그래프의 미묘함을 세 번의 destroy 교착으로 배운 기록이며, 매일 destroy하는 이 프로젝트에서는 이 depends_on이 곧 매일 저녁의 안정성이다. `set` 값들은 clusterName, SA 생성·이름, vpcId, region — 컨트롤러가 IMDS 없이도 환경을 알게 하는 표준 세팅이다.

### L100–118 · module "external_dns_pod_identity"

`attach_external_dns_policy = true` + `external_dns_hosted_zone_arns`를 **우리 존 하나로 한정** — 계정 내 모든 호스팅존이 아니라 이 도메인 존만 수정할 수 있다. 연결 대상은 external-dns 네임스페이스의 `external-dns` SA.

### L120–141 · resource "helm_release" "external_dns"

Ingress가 생기면 도메인 레코드를 Route53에 자동 등록하는 컨트롤러. `create_namespace = true`. depends_on의 `helm_release.aws_load_balancer_controller`에 붙은 주석이 특유의 함정을 기록한다 — ALB Controller의 mutating webhook이 클러스터 전역 Service 생성을 가로채므로, 컨트롤러 파드가 준비되기 전에 Service를 만들면 "no endpoints available for service aws-load-balancer-webhook-service" 에러가 난다. set 값 중 `domainFilters[0] = var.domain_name`(이 도메인만 관리), `policy = "upsert-only"`(생성·수정만 하고 **삭제는 수동** — 레코드 오삭제 사고 방지), `txtOwnerId = 클러스터명`(TXT 레코드로 소유권 표시 — 여러 클러스터가 같은 존을 쓸 때 서로의 레코드를 건드리지 않게 함)이 안전장치다.

### L146–161 · module "cluster_autoscaler_pod_identity"

`attach_cluster_autoscaler_policy = true` + `cluster_autoscaler_cluster_names = [클러스터명]` — ASG 조작 권한을 이 클러스터 소유 ASG로 조건 한정. kube-system의 `cluster-autoscaler` SA에 연결.

### L168–184 · module "image_updater_ecr_pod_identity"

argocd-image-updater가 `aws ecr get-login-password`로 ECR 인증 토큰을 발급받기 위한 권한. 전용 attach 옵션이 없는 케이스라 `additional_policy_arns`로 관리형 `AmazonEC2ContainerRegistryReadOnly`를 부착 — 새 이미지 태그 감시에는 읽기면 충분하다. argocd 네임스페이스의 `argocd-image-updater` SA에 연결.

### L186–202 · resource "helm_release" "cluster_autoscaler"

`autoDiscovery.clusterName`으로 main.tf 노드그룹의 `k8s.io/cluster-autoscaler/*` ASG 태그를 찾아 스케일 대상을 자동 발견한다. depends_on에 NAT·라우트가 들어간 이유는 ALB Controller와 동일 — destroy 시 NAT보다 먼저 정리되도록 순서 고정.

### L208–222 · module "efs_csi_pod_identity"

`attach_aws_efs_csi_policy = true`. SA 이름 `efs-csi-controller-sa`는 aws-efs-csi-driver 애드온의 기본값과 일치해야 한다는 계약이 주석에 있다 — 어긋나면 권한 연결이 조용히 빗나간다.

### L230–250 · resource "aws_iam_policy" "gochuchamchi_app_policy"

앱(Spring Boot 파드)의 AWS 권한. 현재 남은 문장은 `S3ProductImageUploadOnly` **하나** — `s3:PutObject`를 `images` 버킷의 `products/*` 경로로만 허용한다. 액션도 경로도 최소다(Get/Delete도, 다른 prefix도 없다). L242–247 주석이 두 번째 문장(AppDbSecretRead)의 제거를 기록한다: 원래 앱 DB 비밀번호 시크릿을 읽는 권한이었는데(8/4에 `rds!*` 와일드카드를 시크릿 1개로 좁힌 흔적), IAM 토큰 전환으로 시크릿 자체가 없어져 읽을 대상이 존재하지 않는다 — 앱의 DB 자격증명은 이제 secretsmanager가 아니라 `rds-db:connect`(db-zero-trust.tf)로 받는다. 참고로 L225–228의 구획 헤더 주석에는 "RDS 비밀번호가 들어있는 Secrets Manager 조회 권한"이라는 문구가 아직 남아 있는데, 이는 삭제 전 상태의 서술이 헤더에 잔존한 것으로 현재 정책 내용과 다르다 — 실제 권한은 S3 업로드 + (별도 정책의) rds-db:connect뿐이다. 결과적으로 앱 파드의 전체 AWS 권한은 "products/ 업로드 + 지정 유저명으로 DB 접속" 두 가지로, 앱이 침해돼도 계정 장악으로 이어질 통로가 없다.

### L252–265 · resource "aws_iam_role" "gochuchamchi_app_role"

Principal이 `pods.eks.amazonaws.com`이고 Action에 `sts:TagSession`이 포함된 신뢰 정책 — Pod Identity 방식의 표식이다(IRSA라면 OIDC provider가 Principal이었을 것). 에이전트가 세션에 클러스터·네임스페이스·SA 태그를 붙이므로 TagSession이 필수다.

### L267–270 · resource "aws_iam_role_policy_attachment" "gochuchamchi_app_attach"

S3 정책을 앱 역할에 부착(DB 정책 부착은 db-zero-trust.tf에서).

### L272–277 · resource "aws_eks_pod_identity_association" "gochuchamchi_app"

gochuchamchi 네임스페이스의 `gochuchamchi-app` SA와 역할을 연결하는 마지막 조각. 플랫폼 컴포넌트들은 모듈이 이 리소스까지 만들어 줬지만, 앱은 정책·역할·부착·연결을 직접 조립해 권한의 내용이 코드에 그대로 드러난다.

---

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| backend.tf | 20 | 1 | 전체 |
| account-guard.tf | 10 | 1 | 전체 |
| variables.tf | 304 | 28 (variable 28 + 삭제 이력 주석) | 전체 |
| persistent-data.tf | 55 | 8 (data 8) | 전체 |
| main.tf | 350 | 13 (terraform 1, provider 1, module 4, moved 1, resource 2, output 4) | 전체 |
| securitygroups.tf | 98 | 4 (module 4) | 전체 |
| nacl.tf | 71 | 2 (locals 1, resource 1) | 전체 |
| vpc-endpoints.tf | 95 | 4 (locals 1, module 1, resource 1, output 1) | 전체 |
| flow-logs.tf | 65 | 3 (locals 1, resource 1, output 1) | 전체 |
| dns.tf | 53 | 6 (data 1, resource 3, output 2) | 전체 |
| kms.tf | 17 | 1 (output 1) | 전체 |
| s3.tf | 198 | 15 (data 2, resource 11, moved 1, output 1) | 전체 |
| ecr.tf | 24 | 2 (output 2) | 전체 |
| efs.tf | 84 | 5 (resource 3, module 1, output 1) | 전체 |
| redis.tf | 77 | 4 (module 1, resource 3) | 전체 |
| rds.tf | 182 | 3 (module 2, output 1) | 전체 |
| rds-schema-init.tf | 84 | 1 (resource 1) | 전체 |
| db-zero-trust.tf | 165 | 4 (resource 4) | 전체 |
| iamRole.tf | 103 | 8 (resource 8) | 전체 |
| eks-pod-identity.tf | 277 | 14 (provider 2, module 5, resource 7) | 전체 |


---

# terraform (2) — 런타임 루트: 엣지·배포 파이프라인·K8s 정책

이 문서는 런타임 루트(`go/terraform/`) 중 "엣지 보안 · 배포 파이프라인 · K8s 정책" 담당 파일 16개를 해설한다. 이 루트는 매일 아침 daily-up(apply)으로 태어나고 매일 밤 daily-down(destroy)으로 사라지는 일일 계층이다. 그래서 이 파일들 곳곳에 "상시 계층(`../persistent`)이 소유하고 여기서는 data로 읽기만 한다", "destroy가 막히지 않게 force_destroy를 켠다" 같은 결정이 반복해서 나타난다. 반대로 매일 재생성돼도 괜찮은 것(CloudFront, WAF Web ACL, ArgoCD 설치 자체)은 이 루트가 소유한다. 도메인은 `var.domain_name` = kycj.click이다(일부 주석에 남은 gochuchamchi.shop은 이전 도메인 시절의 흔적이니 읽을 때 주의).

이 루트의 apply는 2단계다. ALB는 Terraform이 만드는 게 아니라 클러스터 안의 aws-load-balancer-controller가 Ingress 리소스를 보고 비동기로 만들기 때문에, 최초 apply 시점에는 `data "aws_lb"`가 조회할 대상이 아직 없다. 그래서 1차 apply는 `enable_edge=false`(기본값)로 EKS·앱 배포 체계·ALB까지 약 235개 리소스를 만들고, ALB가 뜬 것을 확인한 뒤 2차 apply를 `enable_edge=true`로 돌려 CloudFront 배포·Route53 전환·ALB SG 교체 등 +15개 수준을 얹는다. edge.tf의 거의 모든 CloudFront 관련 리소스에 `count = var.enable_edge ? 1 : 0`이 붙어 있는 이유가 이것이다.

배포 파이프라인의 전체 흐름은 다음과 같다. GitHub Actions CI(gochuchamchi-spring 저장소)가 이미지를 빌드해 `candidate-<SHA>`로 ECR에 올리고, 보호된 GitHub Environment에서만 assume 가능한 서명 역할이 KMS 키로 cosign 서명을 붙여 `signed-<SHA>` 태그를 만든다. ArgoCD Image Updater가 이 `signed-` 태그를 감지해 gitops 저장소(landoll9999/gochuchamchi-gitops)에 write-back 커밋을 넣고, ArgoCD가 그 커밋을 sync해서 클러스터에 배포하며, Kyverno의 이미지 서명 검증 정책이 미서명 이미지를 걸러낸다. Terraform은 이 파이프라인의 "부품"들(ArgoCD·ESO·Kyverno 설치, 시크릿 배선, 검증 장치)을 관리하고, Deployment/Service/HPA 같은 앱 매니페스트는 gitops 저장소가 관리한다 — 두 저장소 사이의 인터페이스를 코드로 못박은 것이 contract.tf이고, apply가 끝난 뒤 "서비스가 실제로 사는지"를 확인하는 것이 ci-sync.tf·smoke-test.tf다.

---

## terraform/edge.tf (511줄)

L1 경계 방어 파일이다. 기존에는 internet-facing ALB가 아무 필터 없이 인터넷에 직접 노출되어 SQLi/XSS/Rate 공격이 애플리케이션까지 그대로 도달했다. 이 파일이 그 앞에 `인터넷 → CloudFront(+WAF) → ALB → 파드` 밴드를 세운다. 구성 요소는 넷이다: (1) CloudFront 뷰어 TLS용 us-east-1 ACM 인증서, (2) CLOUDFRONT scope WAFv2 Web ACL, (3) CloudFront 배포와 Route53 전환, (4) ALB 인바운드를 CloudFront에서 온 트래픽으로만 좁히는 SG. 파일 머리 주석(L19–22)이 핵심 설계를 요약한다 — CloudFront origin-facing 관리형 prefix list만으로는 "CloudFront 서비스에서 왔다"까지만 증명되고 "우리 배포에서 왔다"는 증명되지 않으므로, 이 배포만 아는 Origin Custom Header를 ALB listener rule에서 추가로 검증한다.

### L25–29 · provider "aws" (alias = us_east_1)

CloudFront 뷰어 인증서(ACM)와 CLOUDFRONT scope WAF는 AWS 제약상 반드시 us-east-1에 있어야 해서 별도 provider alias를 둔다. `profile = var.aws_profile`로 서울 리전 기본 provider와 같은 SSO 프로파일을 쓴다. 파일 머리 주석(L15–17)이 지적하듯 iam-security.tf의 Region Guard 정책이 글로벌 서비스(acm/cloudfront/waf 등)를 NotAction으로 빼두었기 때문에 us-east-1 발급이 리전 제한에 막히지 않는다.

### L38–48 · resource "aws_acm_certificate" "cloudfront"

CloudFront 뷰어 TLS 종료용 인증서다. `domain_name = var.domain_name`(kycj.click)에 `subject_alternative_names = ["www.${var.domain_name}"]`로 www까지 한 장으로 커버하고, `validation_method = "DNS"`로 자동 갱신이 가능한 DNS 검증을 쓴다. `lifecycle { create_before_destroy = true }`는 인증서 교체 시 새 것을 먼저 만들고 옛것을 지워 CloudFront가 인증서 없는 순간을 겪지 않게 하는 ACM 정석 패턴이다. 서울 리전에도 같은 도메인 인증서(dns.tf, ALB용)가 있지만 리전이 달라 별도 발급이 필요하다.

### L50–68 · resource "aws_route53_record" "cloudfront_cert_validation"

ACM DNS 검증 레코드다. `for_each`로 `domain_validation_options`를 도메인명 키의 맵으로 변환해 apex/www 각각의 CNAME을 만든다. `ttl = 60`은 검증을 빨리 끝내기 위한 짧은 TTL. 핵심은 `allow_overwrite = true`(L67)다 — 같은 도메인의 ACM DNS 검증 레코드는 리전과 무관하게 이름·값이 완전히 동일하므로, dns.tf의 서울 리전 인증서가 이미 만든 레코드와 충돌하는 대신 덮어쓰기를 허용한다(L65–66 주석). 이 옵션이 없으면 두 번째 apply에서 "레코드가 이미 존재함" 에러가 난다.

### L70–75 · resource "aws_acm_certificate_validation" "cloudfront"

실제 리소스를 만들지 않는 "검증 완료 대기" 리소스다. `validation_record_fqdns`에 위 레코드들의 FQDN을 넘겨, ACM이 ISSUED 상태가 될 때까지 apply를 붙잡는다. CloudFront 배포(L396)가 인증서 ARN을 이 리소스의 `certificate_arn` 속성으로 참조하므로 "검증 안 된 인증서를 CloudFront에 붙이려다 실패"하는 순서 문제가 구조적으로 차단된다.

### L82–119 · locals waf_managed_rule_groups

AWS 관리형 룰 그룹 5종을 맵으로 선언한다. 항목을 추가/제거하면 아래 `dynamic "rule"`(L258)에 그대로 반영되는 데이터 주도 구조다. 각 항목:

- **aws-managed-ip-reputation** (priority 5, `override_action = "none"` = 그룹의 BLOCK 그대로 적용): `AWSManagedRulesAmazonIpReputationList`. Amazon 위협 인텔리전스 기반의 알려진 악성 IP 차단. 최근 PR #7에서 BLOCK으로 추가된 룰이다.
- **aws-managed-anonymous-ip** (priority 6, `override_action = "count"`): `AWSManagedRulesAnonymousIpList`. VPN/Tor/프록시 등 익명화 IP. 정상 사용자도 VPN을 쓸 수 있어 차단 대신 COUNT로 관찰만 한다 — 같은 PR #7의 보수적 선택.
- **aws-managed-common** (priority 10, none): `AWSManagedRulesCommonRuleSet`. OWASP 계열 공통 룰(XSS, LFI, 프로토콜 위반 등). **함정**: 이 그룹의 `NoUserAgent_HEADER` 룰이 살아 있어서 User-Agent 헤더가 없는 요청은 403이 난다. curl을 UA 없이 날리거나 헬스체크 도구가 UA를 안 붙이면 차단되는데, 증상만 보면 rate limit로 오진하기 쉽다. 디버깅 시 WAF 로그의 terminatingRuleId를 먼저 볼 것.
- **aws-managed-known-bad-inputs** (priority 20, none): Log4Shell JNDI, 경로 조작 등 알려진 악성 입력.
- **aws-managed-sqli** (priority 30, none): SQLi 전용 룰. 앱이 MariaDB 기반 회원/게시판이라 직접 해당된다(L111 주석).

metric 이름은 전부 `gochuchamchi-` 접두사로 통일해 edge-logs.tf의 알람 dimension과 짝을 맞춘다.

### L125–129 · data "aws_wafv2_ip_set" "guardduty_blocklist"

`../persistent`가 소유한 자동대응 차단 IP set(`gochuchamchi-guardduty-blocklist`, CLOUDFRONT scope)을 이름으로 조회한다. 격리 Lambda가 네트워크 기반 GuardDuty finding의 공격자 IP를 이 set에 넣고, 아래 WAF rule(priority 3)이 참조해 엣지에서 차단한다. IP set을 상시 계층에 둔 이유가 중요하다(L121–124 주석): 이 일일 WAF는 매일 재생성되지만 차단 목록은 상시 계층 소유라 daily-down/up을 건너 유지된다. 참조 방향은 항상 "일일 → 상시" 한 방향이다.

### L131–302 · resource "aws_wafv2_web_acl" "edge"

CLOUDFRONT scope Web ACL 본체다. `description`은 영문인데, WAF description에 한글이 안 들어간다는 것을 2026-08-03 apply에서 실제로 검증했기 때문이다(L135 주석). `default_action { allow {} }` — 어느 룰에도 안 걸린 요청은 통과시키는 블랙리스트 방식이다. 룰을 우선순위 순서로:

- **rate-limit-per-ip (priority 1, action BLOCK)** L144–164: `rate_based_statement`로 단일 소스 IP의 5분당 요청 수가 `var.waf_rate_limit_per_5min`을 넘으면 차단. `aggregate_key_type = "IP"`는 소스 IP 기준 집계. L7 rate 공격/무차별 대입의 1차 완화 장치다.
- **login-rate-limit-per-ip (priority 2, action은 변수로 결정)** L168–232: 로그인 엔드포인트만 훨씬 낮은 임계값(`var.waf_login_rate_limit_per_5min`, 기본 50)으로 따로 본다. `scope_down_statement`의 `and_statement`가 (uri_path EXACTLY `/auth/login`) AND (method EXACTLY `POST`)로 대상을 좁힌다 — 즉 로그인 POST만 세고 GET 페이지 조회는 안 센다. action은 `dynamic "action"` 두 개로 `var.waf_login_rate_limit_action`(기본 COUNT)에 따라 block/count 중 하나만 렌더링된다. "COUNT로 적용해 CloudWatch 지표를 확인한 뒤 BLOCK으로 전환한다"는 운영 절차(L166–167 주석)를 변수 하나로 구현한 것. `text_transformation type = "NONE"`은 변형 없이 원문 그대로 매칭한다는 뜻이다.
- **guardduty-auto-blocklist (priority 3, action BLOCK)** L237–256: 위 data source의 IP set을 `ip_set_reference_statement`로 참조. rate-limit(1,2) 다음, 관리형 룰(5,6,10,20,30) 앞에 두어 이미 확인된 악성 IP를 관리형 룰 평가 비용 없이 최우선 차단한다(L234–236 주석). IP 추가·만료 해제는 Lambda의 일이고 이 rule은 참조만 한다.
- **dynamic "rule" (관리형 룰 그룹 5종)** L258–290: locals 맵을 순회하며 룰을 생성한다. 관리형 룰 그룹은 자체 action을 갖기 때문에 `action`이 아니라 `override_action`을 쓴다 — `none`은 그룹의 판정(BLOCK 포함)을 그대로, `count`는 그룹이 차단 판정을 내려도 기록만 하고 통과시킨다. dynamic 블록 두 개(`none`/`count`)로 맵의 `override_action` 문자열을 HCL 블록으로 변환하는 패턴이다. `managed_rule_group_statement`의 `vendor_name = "AWS"` + `name`으로 그룹을 지정한다.

각 rule과 ACL 전체에 `visibility_config`(CloudWatch 지표 + 샘플 요청 저장)를 켜서, edge-logs.tf의 알람이 rule 단위 `BlockedRequests` 지표를 물 수 있게 한다.

### L311–318 · data "aws_lb" "ingress_edge"

aws-load-balancer-controller가 만든 앱 ALB를 태그(`elbv2.k8s.aws/cluster` = 클러스터명, `ingress.k8s.aws/stack` = "gochuchamchi-web" = IngressGroup 이름)로 조회한다. `count = var.enable_edge ? 1 : 0` — 2단계 apply의 핵심 장치로, 1차 apply(ALB가 아직 없음)에서는 이 조회 자체가 실행되지 않는다. cloudwatch-managed-metrics.tf와 같은 태그 조회 방식이다.

### L324–330 · data "aws_cloudfront_cache_policy" / "aws_cloudfront_origin_request_policy"

AWS 관리형 정책 `Managed-CachingDisabled`와 `Managed-AllViewer`를 이름으로 조회한다. 동적 웹앱이라 캐시는 끄고, 헤더/쿠키/쿼리스트링을 전부 오리진으로 전달한다. AllViewer로 Host 헤더가 그대로 전달되는 것이 중요하다(L320–323 주석) — ALB의 ACM 인증서와 오리진 TLS 검증(SNI)이 일치하고, Ingress의 host 기반 라우팅 규칙도 CloudFront 뒤에서 그대로 동작한다.

### L336–345 · resource "random_password" "cloudfront_origin_verify"

Origin 검증 헤더의 값이 되는 48자 랜덤 문자열이다. `special = false`는 HTTP 헤더 값에 특수문자가 들어갔을 때의 인용/이스케이프 문제를 피하기 위함. `keepers.rotation_version = tostring(var.cloudfront_origin_header_rotation_version)` — 이 변수를 올리면 random_password가 재생성되어 CloudFront custom header와 Ingress listener 조건이 함께 새 값으로 교체된다. 단 CloudFront 전파와 ALB 규칙 갱신의 순서에 따라 짧은 불일치(=일시 차단)가 생길 수 있어 회전 apply는 점검 시간에 수행한다(L332–335 주석). **알려진 리스크**: 이 값은 output으로는 노출하지 않지만 tfstate에는 평문으로 저장되고, state 버킷이 현재 SSE-S3라 KMS 수준의 접근 통제가 없다. SSE-KMS 전환이 백로그에 있다.

### L347–405 · resource "aws_cloudfront_distribution" "edge"

CloudFront 배포 본체(`count`로 2차 apply에서만 생성). 인자별로:

- `enabled = true`, `is_ipv6_enabled = true`: 배포 활성 + IPv6. IPv6를 켰기 때문에 Route53에 AAAA 레코드도 필요하다(L419의 setproduct와 연결).
- `price_class = "PriceClass_200"`: 서울 포함 아시아 엣지까지 커버하는 최소 가격 클래스. PriceClass_100은 북미/유럽만이라 한국 사용자가 미국 엣지로 가게 된다.
- `web_acl_id = aws_wafv2_web_acl.edge.arn`: 위 WAF를 뷰어 요청에 연결. 이 한 줄이 "모든 요청이 WAF를 거친다"를 만든다.
- `aliases`: apex와 www. **grafana 서브도메인은 여기 없다** — 그래서 Grafana는 CloudFront를 안 거치고 ALB로 직접 간다(아래 SG의 관리자 CIDR 인바운드가 필요한 이유).
- `origin` 블록: `domain_name`은 data로 조회한 ALB DNS. `custom_header`로 `X-Gochuchamchi-Origin-Verify: <48자 랜덤>`을 모든 오리진 요청에 부착 — ALB 쪽 listener 조건(k8s-deploy.tf의 conditions 어노테이션)이 이 헤더를 검사해 CloudFront 우회 직접 접근을 차단한다. `custom_origin_config`는 `origin_protocol_policy = "https-only"` + `origin_ssl_protocols = ["TLSv1.2"]`로 CloudFront→ALB 구간도 TLS 강제.
- `default_cache_behavior`(캐시 동작은 이 하나뿐이다): `viewer_protocol_policy = "redirect-to-https"`로 HTTP 뷰어를 301 리다이렉트 — ALB SG가 443만 열기 때문에 HTTP→HTTPS 리다이렉트를 CloudFront가 대신 수행한다(L454–455 주석과 연결). `allowed_methods`는 7개 전부(동적 앱이라 POST/PUT/DELETE 필요), `cached_methods`는 GET/HEAD뿐. `cache_policy_id = CachingDisabled` + `origin_request_policy_id = AllViewer` 조합으로 "캐시는 안 하지만 CDN 엣지 종단·WAF·압축은 쓴다". `compress = true`는 gzip/브로틀리 압축.
- `restrictions.geo_restriction = "none"`: 지역 차단 없음.
- `viewer_certificate`: 검증 완료 대기 리소스를 거친 ACM ARN, `ssl_support_method = "sni-only"`(전용 IP 비용 회피), `minimum_protocol_version = "TLSv1.2_2021"`(구식 TLS 차단).

### L419–435 · resource "aws_route53_record" "edge_alias"

apex/www × A/AAAA = 4개 Alias 레코드를 `setproduct`로 만든 맵 하나로 관리한다(`"kycj.click-A"` 같은 키). `alias` 블록이 CloudFront 배포의 `domain_name`/`hosted_zone_id`(CloudFront 고정 zone Z2FDTNDATAQYW2)를 가리키고, `evaluate_target_health = false`는 CloudFront alias의 표준 설정. 핵심은 `allow_overwrite = true`(L428)다 — 기존에 ExternalDNS가 만들어둔 ALB Alias 레코드를 에러 없이 "인수"한다. 파일 주석(L408–416)이 전제 조건을 설명한다: ExternalDNS는 upsert-only라 레코드를 지우진 않지만 Ingress의 spec host를 계속 보면 ALB로 되돌리는 upsert가 발생하므로, enable_edge=true일 때 k8s-deploy.tf의 Ingress에 `ingress-hostname-source: annotation-only` 어노테이션을 함께 넣어 ExternalDNS가 이 호스트를 더 이상 관리하지 않게 한다. 이 두 파일의 변경이 한 세트다.

### L458–461 · data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing"

AWS가 자동 갱신하는 CloudFront origin-facing IP 목록(`com.amazonaws.global.cloudfront.origin-facing`)을 조회한다. SG에서 CIDR을 하드코딩하는 대신 이 prefix list를 참조하면 CloudFront IP가 바뀌어도 손댈 게 없다.

### L463–497 · resource "aws_security_group" "alb_edge"

CloudFront 우회 차단용 ALB 프론트 SG다. 기본 상태에서는 컨트롤러가 자동 생성한 SG가 0.0.0.0/0:80,443을 열기 때문에, 공격자가 ALB의 `*.elb.amazonaws.com` DNS를 알아내면 WAF를 건너뛸 수 있다(L441–443 주석). 이 SG를 Ingress 어노테이션으로 ALB에 붙이면 인바운드가 둘로 좁혀진다:

- ingress 1 (L470–476): 443/tcp, `prefix_list_ids`로 CloudFront origin-facing만 허용.
- ingress 2 (L478–484): 443/tcp, `cidr_blocks = var.endpoint_public_access_cidrs`(관리자 IP). grafana 서브도메인이 같은 ALB(IngressGroup gochuchamchi-web)에 있는데 CloudFront aliases는 apex/www뿐이라, 이걸 안 열면 Grafana 접속이 끊긴다(L448–450 주석).
- egress: 전체 개방(응답 + 타겟 통신).

**443만 여는 이유**(L453–455 주석)가 실전적이다: prefix list 참조 규칙은 목록 엔트리 수(약 55개)만큼 SG 규칙 쿼터(기본 60)를 소비하므로 80까지 열면 쿼터 초과로 apply가 실패한다. HTTP→HTTPS 리다이렉트는 CloudFront의 viewer_protocol_policy가 대신한다. CloudFront 오리진 연결 자체도 https-only라 80이 필요 없다.

### L503–511 · output "waf_web_acl_arn" / "cloudfront_domain_name"

WAF ARN(로그 설정·검증 스크립트용)과 CloudFront 도메인. 후자는 `var.enable_edge ? ... : null`로 1차 apply에서 인덱스 에러가 나지 않게 한다.

---

## terraform/edge-logs.tf (296줄)

edge.tf가 만든 WAF/CloudFront의 관측 파일이다. 배포나 Web ACL을 또 만들지 않고(L4 주석), (1) WAF 요청 로그를 us-east-1 CloudWatch Logs로, (2) WAF 차단 알람 4종, (3) us-east-1 알람 상태 변경을 서울 리전 알림 허브(SNS→Discord)로 중계하는 EventBridge 배선, (4) CloudFront 액세스 로그 v2를 상시 계층 소유 S3 버킷으로 전달하는 설정을 담는다. CloudFront WAF의 지표·로그가 전부 us-east-1에 있다는 제약이 이 파일 구조 전체를 결정했다.

### L9–16 · locals edge_log_tags

공통 태그 맵. 각 리소스에서 `merge(local.edge_log_tags, { Component = ... })`로 Component만 바꿔 쓴다.

### L22–30 · resource "aws_cloudwatch_log_group" "waf"

WAF 요청 로그 수신 그룹. 이름 `aws-waf-logs-gochuchamchi-edge`는 멋이 아니라 제약이다 — AWS WAF 로그 대상은 반드시 `aws-waf-logs-` 접두사로 시작해야 한다(L25 주석). `retention_in_days = var.waf_log_retention_days`(기본 90)로 보존 기간을 변수화했다.

### L32–50 · resource "aws_wafv2_web_acl_logging_configuration" "edge"

Web ACL과 로그 그룹을 연결한다. `redacted_fields` 두 개로 `authorization`·`cookie` 헤더를 로그에서 마스킹한다 — WAF 로그는 전체 요청 헤더를 담으므로, 이걸 안 빼면 세션 토큰과 자격증명이 로그 저장소에 평문으로 쌓인다. "로그 시스템이 새로운 시크릿 유출 경로가 되지 않게 한다"는 원칙의 적용이다.

### L57–79 · resource "aws_cloudwatch_metric_alarm" "waf_total_blocked"

알람 4종의 공통 골격: `namespace = "AWS/WAFV2"`, `metric_name = "BlockedRequests"`, `statistic = "Sum"`, `period = 300`(WAF 지표 주기), `evaluation_periods = 1` + `datapoints_to_alarm = 1`(한 번이라도 넘으면 즉시), `treat_missing_data = "notBreaching"`(트래픽 없어서 지표가 없으면 정상 취급 — 이걸 빼먹으면 야간에 INSUFFICIENT_DATA 소음이 난다). 이 알람은 `Rule = "ALL"` dimension으로 전체 차단 총량을 보고, 임계값은 `var.waf_total_blocked_alarm_threshold`(기본 5). alarm_description에 대응 절차(로그에서 IP/URI/terminatingRuleId 확인)를 박아 알람 수신자가 바로 움직일 수 있게 했다.

### L81–103 · resource "aws_cloudwatch_metric_alarm" "waf_rate_blocked"

`Rule = "gochuchamchi-rate-limit"` dimension — edge.tf priority 1 룰의 visibility_config metric_name과 정확히 일치해야 한다. 임계값 `var.waf_rate_blocked_alarm_threshold`(기본 1): rate limit 차단은 정상 사용자에게선 안 나오는 신호라 1건부터 알린다.

### L105–127 · resource "aws_cloudwatch_metric_alarm" "waf_sqli_blocked"

`Rule = "gochuchamchi-sqli"`, threshold 하드코딩 1. SQLi 시도는 단 1건도 "차단된 공격"으로 분류하고 앱/DB 영향을 조사하라는 설명이 붙어 있다.

### L129–151 · resource "aws_cloudwatch_metric_alarm" "waf_known_bad_blocked"

`Rule = "gochuchamchi-known-bad-inputs"`, threshold 1. Log4Shell류 알려진 악성 입력 차단 시 반복 IP와 대상 URI를 조사하라는 대응 지침 포함.

### L158–160 · data "aws_caller_identity" "edge_current"

us-east-1 provider로 계정 ID를 조회한다. 아래 크로스리전 event bus ARN 조립에 쓴다(리전만 다르고 계정은 같다).

### L162–172 · data "aws_iam_policy_document" "eventbridge_assume_role_waf"

`events.amazonaws.com`이 assume할 수 있는 신뢰 정책. EventBridge가 다른 event bus로 이벤트를 넣을 때 쓸 역할의 밑감이다.

### L174–179 · resource "aws_iam_role" "waf_alarm_region_forwarder"

위 신뢰 정책을 단 역할. 이름 그대로 "us-east-1 알람 이벤트를 서울로 전달"하는 것만이 임무다.

### L181–193 · data "aws_iam_policy_document" + resource "aws_iam_role_policy" "waf_alarm_region_forwarder"

권한은 단 하나 — 서울 리전 default event bus에 대한 `events:PutEvents`. 리소스 ARN을 `var.region` + 계정 ID로 정확히 조립해 최소권한을 지킨다.

### L195–211 · resource "aws_cloudwatch_event_rule" "waf_alarm_state_change"

us-east-1의 EventBridge rule. `event_pattern`은 source `aws.cloudwatch` + detail-type "CloudWatch Alarm State Change" + `alarmName`이 `gochuchamchi-waf-` 접두사(위 알람 4종이 전부 이 접두사) + 상태가 ALARM 또는 OK로 바뀔 때만. OK도 잡는 이유는 "복구됨" 알림까지 Discord로 보내기 위해서다.

### L213–220 · resource "aws_cloudwatch_event_target" "waf_alarm_seoul_event_bus"

rule의 타겟으로 서울 리전 default event bus ARN을 지정하고 `role_arn`으로 위 전달 역할을 붙인다. 이렇게 서울로 넘어온 이벤트는 서울 쪽 기존 알림 파이프라인(SNS→Discord)이 받아 처리한다. "us-east-1에만 존재하는 지표"라는 제약을 알림 허브를 복제하지 않고 이벤트 중계로 푼 것이다.

### L234–236 · data "aws_s3_bucket" "cloudfront_logs"

CloudFront 액세스 로그 버킷을 **읽기만** 한다. 버킷 본체는 2026-08-12에 `../persistent/cloudfront-logs.tf`로 옮겼다(커밋 5832f65). 이유가 L226–233 주석에 정확히 기록돼 있다: 이 루트는 매일 밤 destroy되는 일일 계층인데, 버킷이 여기 있으면 로그가 매일 같이 사라진다. 그걸 막으려고 걸어둔 `force_destroy = false`는 보존 장치가 아니라 teardown을 실패시키는 장치였고, 실제로 8/12 저녁 daily-down이 BucketNotEmpty로 멈췄다. 증적 보존이 목적이므로 상시 계층으로 이관 — 따라서 `../persistent`를 먼저 apply해야 한다는 계층 계약(ecr.tf, kms-data.tf와 동일)이 생겼다.

### L241–248 · resource "aws_cloudwatch_log_delivery_source" "cloudfront"

CloudFront 표준 로그 v2의 소스 선언. `log_type = "ACCESS_LOGS"`, `resource_arn`은 CloudFront 배포 ARN. v2 로깅은 S3 대상 버킷이 다른 리전에 있어도 us-east-1의 CloudWatch Logs API로 구성한다(L239–240 주석) — provider 지정이 그래서 필요하다. `count = var.enable_edge ? 1 : 0`: 배포가 있어야 소스도 있다.

### L250–259 · resource "aws_cloudwatch_log_delivery_destination" "cloudfront_s3"

전달 대상 선언. `output_format = "parquet"` — Athena 분석을 전제로 컬럼 지향 포맷을 고른 것이다(텍스트 대비 스캔 비용이 크게 준다). destination_resource_arn은 data로 읽은 상시 버킷.

### L261–277 · resource "aws_cloudwatch_log_delivery" "cloudfront_s3"

소스와 대상을 잇는 delivery. `s3_delivery_configuration`의 `enable_hive_compatible_path = true` + `suffix_path = "/{distributionid}/{yyyy}/{MM}/{dd}/{HH}"`로 Hive 파티션 호환 경로를 만들어 Athena 파티션 프루닝이 가능하게 했다. L273–276 주석이 사라진 depends_on의 사연을 남긴다: 예전에는 버킷 정책(delivery.logs.amazonaws.com 허용)이 같은 루트에 있어 depends_on으로 순서를 강제했지만, 정책이 `../persistent`로 옮겨간 지금은 "상시 먼저 apply"라는 계층 순서가 그 보장을 대신한다.

### L283–296 · output 3종

`cloudfront_distribution_id`는 `try(..., null)`로 enable_edge=false에서도 안전하게, `waf_log_group_name`·`cloudfront_log_bucket_name`은 검증 스크립트와 운영 조회용.

---

## terraform/edge-logs-variables.tf (39줄)

edge-logs.tf 전용 변수 3개. 파일 중간(L15–17)의 주석이 네 번째 변수의 부재를 설명한다 — `cdn_log_retention_days`는 버킷과 수명주기 규칙이 `../persistent`로 이관되면서 같이 옮겼다. 여기 남겨두면 아무도 참조하지 않는 죽은 설정이 되기 때문이다. "리소스가 이사 가면 변수도 따라간다"는 위생 원칙.

### L1–13 · variable "waf_log_retention_days"

기본 90일. validation이 CloudWatch Logs가 실제로 허용하는 이산값 목록(1, 3, 5, 7, 14, ... 3653)에 `contains`로 대조한다 — 91 같은 값을 넣으면 apply가 아니라 plan에서 즉시 잡힌다.

### L19–28 · variable "waf_total_blocked_alarm_threshold"

기본 5. 전체 차단 알람은 관리형 룰의 산발적 차단(인터넷 배경 소음)까지 합산하므로 1로 두면 시끄럽다 — rate/sqli 알람(기본 1)보다 높게 둔 이유. validation은 1 이상.

### L30–39 · variable "waf_rate_blocked_alarm_threshold"

기본 1. rate limit 차단은 그 자체가 이상 신호라는 판단.

---

## terraform/dr.tf (294줄)

Tokyo(ap-northeast-1) DR 파일이다. pilot light 이전 단계인 "백업 기반 DR": (1) AWS Backup 중앙 플랜으로 RDS+EFS 일일 스냅샷을 도쿄 볼트로 크로스리전 복사, (2) 상품 이미지 버킷을 S3 CRR로 도쿄에 실시간 복제. 머리 주석(L8–17)의 "의도적으로 뺀 것"이 면접 대비 핵심이다 — Route53 페일오버 레코드는 도쿄에 상시 기동 standby가 없으면 health check 대상이 없어 무의미하고(전략은 "재해 시 도쿄에서 terraform apply 재구축 + 백업 복원", DNS는 복구 시점 수동 전환), RDS Multi-AZ는 리전 내 가용성 항목이라 리전 장애 DR과 별개다. RTO 공표값 4h는 재구축 apply ~40분 + RDS 스냅샷 복원(20GB) ~20분 + DNS 전파/검증 ≤1h로 2h 이내 실측을 목표로 하고 여유를 둔 값. 전체가 `enable_dr` 스위치로 on/off된다.

### L23–27 · provider "aws" (alias = tokyo)

도쿄 리전 provider. 같은 SSO 프로파일.

### L29–37 · locals dr_count / dr_tags

`dr_count = var.enable_dr ? 1 : 0`을 한 번만 계산해 파일 전체 리소스의 count에 일괄 적용한다. 스위치 로직이 한 곳에 모여 있어 조건이 바뀌어도 수정 지점이 하나다.

### L46–59 · resource "aws_kms_key" "dr"

도쿄 볼트 암호화용 CMK. 크로스리전 복사본은 대상 리전 키로 재암호화되므로 대상 리전에도 CMK가 있어야 "전 구간 CMK" 원칙(kms.tf)이 유지된다(L44–45 주석). `enable_key_rotation = true`(연 1회 자동 회전), `deletion_window_in_days = 7`(실습 환경이라 최소 대기).

### L61–71 · resource "aws_backup_vault" "seoul"

원본(서울) 볼트. `kms_key_arn = data.aws_kms_key.data.arn` — 서울 쪽은 상시 계층의 기존 데이터 CMK를 재사용한다. `force_destroy = true`: 볼트 안에 복구 지점이 남아 있으면 destroy가 막히는데, 매일 destroy되는 실습 환경이라 자동 정리를 택했다(L67 주석). 운영이라면 이 값은 보존 요건과 충돌하므로 그대로 못 쓴다.

### L73–82 · resource "aws_backup_vault" "tokyo"

사본(도쿄) 볼트. 위에서 만든 도쿄 CMK로 암호화, 마찬가지로 force_destroy.

### L85–108 · resource "aws_iam_role" "backup" + aws_iam_role_policy_attachment "backup"

Backup 서비스 역할. 신뢰 주체는 `backup.amazonaws.com`, 권한은 AWS 관리형 정책 2종(`AWSBackupServiceRolePolicyForBackup`/`ForRestores`)을 `for_each = toset([...])`로 붙인다. attachment의 for_each가 `var.enable_dr ? toset([...]) : toset([])`인 점 — count 리소스와 for_each 리소스가 섞여 있어도 둘 다 enable_dr 하나로 꺼진다.

### L110–137 · resource "aws_backup_plan" "daily"

백업 플랜. rule 하나 "daily-with-tokyo-copy": `schedule = "cron(0 18 * * ? *)"`는 UTC 18:00 = KST 03:00, 트래픽 최저 시간대(L118 주석). `start_window = 60`(60분 안에 시작 못 하면 실패 처리), `completion_window = 180`(3시간 안에 완료). `lifecycle.delete_after = var.dr_backup_retention_days`로 원본 보존 기간을, `copy_action` 블록으로 도쿄 볼트로의 크로스리전 복사와 사본 보존 기간(동일 변수)을 선언한다. 이 copy_action 한 블록이 이 파일의 존재 이유 — "리전이 통째로 죽어도 백업은 다른 리전에 있다".

### L139–150 · resource "aws_backup_selection" "rds_efs"

플랜의 백업 대상 지정: `module.rds.db_instance_arn`(DB)과 `aws_efs_file_system.this.arn`(EFS). 태그 셀렉터 대신 ARN 명시로 대상을 못박았다 — 실수로 다른 리소스가 백업 대상에 끼는 일이 없다.

### L158–168 · resource "aws_s3_bucket" "images_dr"

도쿄 이미지 복제 버킷. 이름에 계정 ID를 붙여 전역 유일성 확보. `force_destroy = true`는 원본과 같은 사유(BucketNotEmpty로 daily-down이 막히는 것 방지).

### L170–179 · resource "aws_s3_bucket_versioning" "images_dr"

CRR은 원본·대상 모두 버전관리가 켜져 있어야 동작한다(L155 주석 — 이 요구 때문에 s3.tf 원본 버킷에도 versioning이 추가됐다). 대상 쪽을 여기서 켠다.

### L183–193 · resource "aws_s3_bucket_public_access_block" "images_dr"

복제본은 평시 접근할 일이 없으므로 4개 플래그 전부 true로 전면 차단. 실제 페일오버 때 원본과 같은 public-read 정책을 적용하는 절차는 복구 런북에 있다(L181–182 주석) — "평시 최소 노출, 유사시 절차로 개방".

### L195–208 · resource "aws_iam_role" "s3_replication"

CRR 실행 역할. 신뢰 주체 `s3.amazonaws.com`.

### L210–250 · resource "aws_iam_role_policy" "s3_replication"

CRR 최소권한 3문: ReadSource(원본 버킷의 `GetReplicationConfiguration`/`ListBucket`), ReadSourceObjects(원본 객체의 버전/ACL/태그 읽기 — `GetObjectVersionForReplication` 등), WriteDestination(대상 버킷에 `ReplicateObject`/`ReplicateDelete`/`ReplicateTags`). 읽기는 원본에만, 쓰기는 대상에만 — 방향이 정확히 분리돼 있다.

### L252–279 · resource "aws_s3_bucket_replication_configuration" "images"

원본 버킷(`aws_s3_bucket.images`, s3.tf 소유)에 복제 규칙을 붙인다. `filter {}`(빈 필터) = 전체 객체 복제, `delete_marker_replication = Enabled`로 삭제까지 미러링(원본에서 지운 이미지가 DR에 유령으로 남지 않게), `destination.storage_class = "STANDARD_IA"`는 평시 읽지 않는 복제본이라 저장 단가를 낮춘 것. `depends_on`으로 양쪽 versioning 리소스를 명시 — 복제 구성은 versioning보다 먼저 만들어질 수 없다는 API 제약을 그래프에 반영했다.

### L286–294 · output 2종

도쿄 볼트 ARN과 복제 버킷 이름. 둘 다 `var.enable_dr ? ... : null` 패턴.

---

## terraform/k8s-deploy.tf (295줄)

Terraform이 직접 관리하는 K8s 리소스(Namespace/ServiceAccount/ConfigMap/Secret/Ingress)의 파일이다. 관리 경계가 머리 주석(L1–10)에 선언돼 있다: apply를 실행하는 IAM 주체가 이미 클러스터 admin이므로(`enable_cluster_creator_admin_permissions`) kubernetes provider로 직접 적용하고, Deployment/Service/HPA는 여기서 관리하지 않는다 — 이미지 태그가 바뀌는 리소스라 인프라 재생성 주기와 분리해 gitops 저장소+ArgoCD에 맡겼다. 반대로 재생성마다 바뀌는 값(RDS/Redis 엔드포인트, ACM ARN)은 gitops에 하드코딩할 수 없으므로 Terraform이 ConfigMap/Ingress로 주입한다. 이 "누가 무엇을 소유하는가"가 contract.tf 계약의 바탕이다.

### L12–18 · resource "aws_s3_bucket" "k8s_manifests"

schema.sql 전달용 버킷. `force_destroy = true` — 객체가 남아 destroy가 막히는 것 방지, 배포 산출물 전달용이라 지워져도 재생성 시 다시 올라간다(L15–16 주석).

### L20–26 · resource "aws_s3_bucket_public_access_block" "k8s_manifests"

4개 플래그 전부 true. 내부 전달용 버킷의 기본 위생.

### L30–33 · data "aws_db_instance" "this"

RDS 엔드포인트를 `db_instance_identifier = "gochuchamchi-db"`로 직접 조회한다. module 내부 output 이름에 의존하지 않기 위한 선택이고, `depends_on = [module.rds]`가 필수다 — 없으면 RDS가 만들어지기 전에 조회가 돌아 실패한다(L28–29 주석).

### L36–51 · resource "aws_iam_role_policy" "bastion_s3_manifests"

배스천 역할에 이 버킷 한정 `s3:GetObject`/`s3:ListBucket`을 부여한다. rds-schema-init.tf가 배스천 경유로 schema.sql을 읽어가는 경로의 권한이다.

### L54–59 · resource "aws_s3_object" "schema_sql"

`../k8s/gochuchamchi/schema.sql`을 `db/schema.sql` 키로 업로드. `etag = filemd5(...)`가 파일 내용 변경을 감지해 내용이 바뀔 때만 재업로드한다 — 이게 없으면 로컬 수정이 S3에 반영되지 않는다.

### L64–83 · resource "kubernetes_namespace_v1" "gochuchamchi"

앱 네임스페이스 + Pod Security Standards 라벨(컨테이너 보안 레이어 1/3). `enforce = var.pss_enforce_level`(기본 baseline) — 위반 파드는 생성 자체가 거부된다. 앱 이미지가 root로 도는지 검증 전이라 baseline(privileged/hostPath/hostNetwork 등 컨테이너 탈출 벡터 차단)으로 시작하고, gitops Deployment에 securityContext를 넣은 뒤 restricted로 올린다는 로드맵(L69–74 주석). `warn`/`audit`는 restricted로 고정해 "enforce를 올리면 무엇이 걸릴지"를 kubectl 경고와 감사로그로 미리 보이게 했다. `depends_on = [module.eks]`.

### L85–93 · resource "kubernetes_service_account_v1" "gochuchamchi_app"

앱 SA. 이름 `gochuchamchi-app`은 eks-pod-identity.tf의 `aws_eks_pod_identity_association`이 지정한 namespace/service_account와 **정확히 일치해야** IAM 권한이 파드에 붙는다(L87–89 주석). 오타 하나로 조용히 권한이 빠지는 지점이라 주석으로 결합을 명시했다.

### L100–156 · resource "kubernetes_config_map_v1" "gochuchamchi_config"

앱 설정 주입의 중심. 키별로:

- `DB_HOST`/`DB_PORT`: data로 조회한 RDS 주소와 3306. 재생성마다 바뀌는 값이라 gitops가 아닌 여기서 관리(L97–98 주석).
- `DB_USER = "gochuchamchi_app_iam"`: 제로트러스트 전환의 종착점. 마스터(admin) → 앱 전용 최소권한 계정 → (2026-08-12) IAM 토큰 계정. 이 계정은 AWSAuthenticationPlugin으로 만들어져 **비밀번호가 아예 없다**. 접속마다 15분짜리 토큰을 받아야 하고, 토큰 발급은 `rds-db:connect`가 붙은 파드 역할만 가능하다. IAM 정책 Resource에 유저명이 박혀 있어(db-zero-trust.tf) 이 이름을 바꾸면 즉시 권한이 끊긴다(L109–113 주석).
- `SPRING_DATASOURCE_URL`: 이 파일에서 가장 밀도 높은 한 줄이다. 환경변수 `SPRING_DATASOURCE_URL`은 이미지 안 application.yml의 `spring.datasource.url`보다 우선하므로(Spring 프로퍼티 우선순위) 앱 코드 수정/리빌드 없이 접속 방식을 전환할 수 있다. JDBC 파라미터 각각의 사유(L123–136 주석): `credentialType=AWS-IAM`은 mariadb-java-client 3.x의 AwsIamCredentialPlugin이 접속마다 토큰을 발급해 비밀번호 자리에 넣게 한다(토큰 유효 15분/드라이버 캐시 10분이라 앱·HikariCP 갱신 로직 불필요, 단 이미지에 `software.amazon.awssdk:rds` v2가 있어야 하고 v1은 안 된다 → **이미지 배포가 이 ConfigMap 변경보다 반드시 먼저**라는 순서 제약). `region=${var.region}`은 EKS Pod Identity가 자격증명만 주입하고 리전을 보장하지 않아 명시. `sslMode=verify-full`은 암호화+서버 신원 검증(운영 기준 2단계), `serverSslCert=/app/rds-ca.pem`은 ap-northeast-2 RDS가 JDK cacerts에 없는 리전 루트로 서명돼 있어 CA 번들 없이는 verify-full이 반드시 실패하기 때문 — 경로는 Dockerfile이 이미지에 구운 위치다.
- `SPRING_DATASOURCE_HIKARI_*`: 풀 최대 5/최소 유휴 2 — t3.small 급 리소스와 RDS max_connections에 맞춘 소형 풀.
- `CLOUD_AWS_S3_BUCKET`/`CLOUD_AWS_S3_PUBLIC_BASE_URL`/`CLOUD_AWS_REGION_STATIC`: 이미지 업로드 버킷과 이미지 전용 CloudFront(`aws_cloudfront_distribution.images` — edge.tf의 배포와 별개) 도메인.
- `SPRING_SESSION_STORE_TYPE = "redis"` + `SPRING_DATA_REDIS_HOST/PORT/SSL_ENABLED`: 세션 외부화. Redis 호스트는 replication_group 전환(redis.tf)으로 `primary_endpoint_address` 속성을 쓰고, `SSL_ENABLED=true`는 ElastiCache 전송 암호화와 세트로 lettuce가 rediss(TLS)로 붙게 한다(Boot 3.1+ 프로퍼티).
- `APP_SUPERADMIN_USERNAME`: 기동 시 이 아이디를 superadmin으로 승격(SuperAdminBootstrap). 환경변수가 프로퍼티를 직접 덮으므로 설정 파일과 무관하게 동작.

### L158–174 · (기록 주석) DB Secret 제거의 3단계

리소스가 아니라 "왜 지웠는지"의 기록이다. 1단계: 마스터 비밀번호를 K8s Secret(gochuchamchi-db-secret)으로 만들던 구조 — 앱이 마스터 계정으로 돌았고 tfstate에 평문이 남아 감사 #1의 ESO 트리거가 발동된 상태였다. 2단계(8/4~8/12): 배스천이 앱 전용 자격증명을 생성해 K8s Secret(gochuchamchi-db-app)으로 직접 주입 — state에서 비밀번호 제거. 3단계(2026-08-13, gitops `853a6a4` → terraform `dbae59c`): IAM 토큰 전환으로 그 Secret도 제거 — DB 비밀번호가 state에 안 남는 정도가 아니라 **아예 존재하지 않는다**. gitops의 `secretRef: gochuchamchi-db-app` 제거가 먼저여야 하는 이유(참조가 남으면 CreateContainerConfigError)까지 적혀 있고, 이 금지가 contract.tf의 forbidden_refs로 코드화됐다.

### L180–189 · resource "kubernetes_secret_v1" "gochuchamchi_redis_secret"

Redis AUTH 토큰 Secret. DB와 달리 auth_token은 `aws_elasticache_replication_group`의 **리소스 인자**라 Terraform(state) 경유가 구조적으로 불가피하다 — 이미 state에 있는 값이므로 K8s Secret으로 만들어도 "추가" 노출은 없다는 판단(L176–179 주석). 키 이름을 Spring 환경변수명(`SPRING_DATA_REDIS_PASSWORD`) 그대로 두어 gitops에서 `envFrom secretRef` 한 줄로 끝나게 했다. ESO 도입 시 최우선 이관 대상으로 표시돼 있다.

### L196–295 · resource "kubernetes_ingress_v1" "gochuchamchi_web"

aws-load-balancer-controller가 이걸 보고 ALB를 만들고, ExternalDNS가 host를 보고 Route53 레코드를 만든다. 어노테이션이 두 층의 merge다.

기본 어노테이션(L201–224): `ingress.class=alb`, `scheme=internet-facing`, `target-type=ip`(파드 IP 직결 — NodePort 홉 제거), listen-ports 80/443, `ssl-redirect=443`, `certificate-arn`(재생성마다 바뀌므로 여기서 주입), `ssl-policy=ELBSecurityPolicy-TLS13-1-2-2021-06`(미지정 시 기본 2016-08 정책이 deprecated TLS 1.0/1.1을 허용하고 1.3을 미지원하는 것을 실제 확인해 고정), `group.name=gochuchamchi-web` + `group.order=10`(Grafana Ingress가 group.order=30으로 같은 그룹에 합류해 ALB 1개 유지 — 이 값은 cloudwatch-managed-metrics.tf의 태그 조회와도 결합돼 있어 바꾸면 거기도 바꿔야 한다), `load-balancer-attributes`로 ALB 액세스 로그를 **Log 계정의 불변 버킷**에 직접 적재(`../log-archive` 먼저 apply 필요 — 3계정 분리가 로그 무결성으로 이어지는 지점).

enable_edge 조건부 어노테이션(L236–252): 2차 apply에서만 merge된다. `external-dns.../ingress-hostname-source=annotation-only`(ExternalDNS가 이 호스트의 레코드 소유를 놓게 해 edge.tf의 Route53 인수와 충돌 방지), `security-groups=aws_security_group.alb_edge[0].id`(컨트롤러 자동 SG 대신 CloudFront+관리자 IP 한정 SG), `manage-backend-security-group-rules=true`(커스텀 SG를 쓸 때 컨트롤러가 ALB→타겟 허용 규칙을 백엔드 SG에 자동 관리 — 이걸 빼면 타겟 통신이 끊긴다), 그리고 `conditions.gochuchamchi-web-svc` — listener rule 조건으로 `X-Gochuchamchi-Origin-Verify` 헤더 값이 `random_password.cloudfront_origin_verify[0].result`와 일치하는 요청만 앱 Target Group으로 보낸다. 헤더가 없거나 틀리면 listener default action으로 떨어져 애플리케이션에 도달하지 못한다 — SG(네트워크 레벨)와 헤더 검증(L7 레벨)의 이중 차단이 완성되는 지점이다.

spec(L256–292): apex와 www 두 rule, 둘 다 `/` Prefix로 `gochuchamchi-web-svc:80`에 연결한다. 이 Service 이름은 gitops가 만드는 것이라 contract.tf의 "gitops가 만들어야 하는 것" 항목과 짝이다. `depends_on = [helm_release.aws_load_balancer_controller]` — 컨트롤러 webhook이 준비되기 전에 Ingress를 만들면 실패한다.

---

## terraform/argocd.tf (192줄)

GitOps 축의 설치 파일이다. ArgoCD가 gitops 저장소를 감시해 클러스터를 동기화하고, Image Updater가 ECR의 새 이미지를 감지해 gitops에 write-back한다(예전 Docker Hub에서 ECR로 마이그레이션). helm_release 3개(ArgoCD 본체, Application CR 래퍼, Image Updater)와 운영 output 2개로 구성된다.

### L9–14 · locals

`gitops_repo_url`: owner/repo 변수로 gitops 저장소 URL 조립(landoll9999/gochuchamchi-gitops). `ecr_registry_host`: `repository_url`("<account>.dkr.ecr.<region>.amazonaws.com/<repo>")을 `split("/", ...)[0]`으로 잘라 레지스트리 호스트만 뽑는다 — Image Updater 레지스트리 등록에서 호스트와 저장소 경로를 분리해야 하기 때문(L142–144 주석과 연결).

### L16–83 · resource "helm_release" "argocd"

argo-helm 차트로 ArgoCD 설치. `create_namespace = true`, `cleanup_on_fail = true`(실패 시 반쯤 만든 릴리스 정리), `depends_on`으로 EKS와 LB 컨트롤러 뒤에 서게 한다 — server.ingress가 만드는 ALB도 컨트롤러 webhook을 타기 때문(L24–26 주석). values를 키별로:

- `configs.params."server.insecure" = true`: ALB가 TLS를 종단하므로 argocd-server는 평문 HTTP로 서빙(앱 Deployment와 동일 패턴). 이 값 때문에 아래 port-forward output이 "http로 붙어라"가 된다.
- `configs.secret.argocdServerAdminPassword`(조건부 merge): admin 비밀번호를 bcrypt **해시**로 코드화(백로그 B4). UI에서 바꾼 비밀번호는 코드 밖 수동 조치라 재구축마다 초기 비밀번호로 회귀했던 문제(7/30 이력)를 해결한다 — 해시를 values로 넣으면 재구축에도 유지되고, state에는 평문이 아니라 bcrypt 해시만 남는다. 해시 생성 명령(`htpasswd -nbBC 10`)과 주입 방법(`TF_VAR_argocd_admin_password_bcrypt`)이 주석에 있고, 미설정("")이면 initial-admin-secret 동작 그대로다.
- `server.ingress`: `enabled=true`에 **`scheme=internal`** — ArgoCD는 클러스터 admin급 권한과 gitops write-back PAT를 쥔 최고 가치 타겟이라 인터넷 노출 대신 internal ALB로 전환했다(L57–59 주석). 접근은 SSM 포트포워딩 + kubectl port-forward. 나머지 어노테이션(target-type ip, listen-ports, ssl-redirect, cert ARN, ssl-policy TLS13-1-2)은 앱 Ingress와 동일 기준. **함정**(L69–70 주석): 이 차트 버전은 `hosts`(list)가 아니라 `hostname`(단수 string)을 쓴다 — hosts로 넣으면 에러 없이 조용히 무시되고 global.domain 기본값(argocd.example.com)이 적용된다. 그래서 `hostname = "argocd.${var.domain_name}"`.
- `notifications.cm/secret.create = false`: argocd-notifications-cm/-secret은 별도 state(`../discord-notifications`)가 전담 관리한다. 차트가 이 둘을 만들면 helm_release 업그레이드마다 빈 기본값으로 덮어써 Discord 설정이 사라지므로 생성 자체를 껐다 — "한 리소스에 관리 주체는 하나" 원칙.

### L85–94 · (기록 주석) 저장소 자격증명 Secret 제거

기존에는 `kubernetes_secret_v1`이 `var.argocd_git_pat`를 받아 Secret을 만들면서 PAT가 tfstate에 평문 저장됐다 — gitops write 권한 PAT는 탈취 시 "gitops 커밋 → ArgoCD 자동 배포"라는 공급망 공격 경로가 열리는 최고가치 시크릿이다. 백로그 B3로 Secrets Manager+ESO 동기화로 전환(eso.tf), Secret 이름/라벨/키가 동일해 ArgoCD·Image Updater 쪽 변경은 없었다.

### L100–118 · resource "helm_release" "gochuchamchi_application"

ArgoCD Application CR을 로컬 차트(`charts/gochuchamchi-application`)로 감싸 배포한다. 왜 kubectl 계열 프로바이더가 아닌가(L96–99 주석): alekc/kubectl로 CR을 직접 만들면 클러스터가 아직 없는 첫 apply에서 host가 "known after apply"라 **plan 단계에서** 에러가 나는 것을 실제로 확인했다. 이미 검증된 helm 프로바이더 부트스트랩 패턴을 재사용한 것. `depends_on` 셋의 사유가 각각 다르다: `argocd`(Application CRD), `argocd_image_updater`(ImageUpdater CR의 CRD 제공), `eso_config`(저장소 자격증명이 ESO로 동기화된 뒤에 Application이 저장소에 붙을 수 있음). values는 repoURL/gitBranch(main)/destinationNamespace(gochuchamchi)/appImage(ECR URL) — 차트 템플릿에 주입되는 계약 값들이다.

### L120–173 · resource "helm_release" "argocd_image_updater"

Image Updater 설치. `timeout = 600` + depends_on의 사연(L127–129 주석): LB 컨트롤러 webhook이 준비되기 전에 이 차트의 Service가 생성되면 webhook 호출이 막혀 helm 기본 5분 타임아웃(context deadline exceeded)에 걸렸던 실전 문제를 순서 보장+여유 타임아웃으로 완화했다. `module.image_updater_ecr_pod_identity`도 대기 대상(ECR 읽기 권한). values:

- `config.registries[0]`: ECR은 docker.io/ghcr.io처럼 자동 인식되는 레지스트리가 아니라서(공식 문서가 "ECR이 ext: 스크립트 credential이 필요한 대표 사례"라고 명시) 커스텀 등록이 필요하다. `api_url = "https://${local.ecr_registry_host}"`/`prefix = ecr_registry_host` — repository_url을 그대로 쓰면 저장소 경로까지 API 엔드포인트에 섞여 들어가므로 호스트까지만 쓴다. `ping=true`, `insecure=false`, `credentials = "ext:/scripts/ecr-auth.sh"`(외부 스크립트로 자격증명 획득), `credsexpire = "10h"` — `aws ecr get-login-password` 토큰이 12시간짜리라 10시간마다 여유 있게 갱신.
- `authScripts`: 차트 기능으로, scripts 아래 내용을 ConfigMap으로 만들어 `/scripts`에 자동 마운트한다. 스크립트 본체는 두 줄 — `#!/bin/sh` 셔뱅과 `echo "AWS:$(aws ecr get-login-password --region ...)"`(ECR 토큰의 사용자명은 항상 고정값 "AWS"). 이미지가 alpine 기반이고 Dockerfile에서 aws-cli를 이미 설치해두므로(v1.2.2 태그에서 확인) initContainer가 필요 없고, 실제 인증 권한은 Pod Identity가 붙인 IAM에서 나온다.
- **CRLF 함정의 실증 지점**(L162–163 주석): Windows git clone(autocrlf)이 .tf 파일을 CRLF로 바꾸면 heredoc 안 셔뱅이 `/bin/sh\r`가 되어 컨테이너에서 fork/exec ENOENT로 죽는다(2026-08-11 실증). 그래서 heredoc 전체를 `replace(<<-EOT ... EOT, "\r\n", "\n")`로 감싸 LF를 강제한다. 클러스터로 들어가는 heredoc 셸 스크립트 전부가 같은 위험이라 `.gitattributes`(`*.tf eol=lf`)도 함께 도입됐다 — replace는 이미 체크아웃된 파일의 방어, gitattributes는 재발 방지.

### L181–184 · output "argocd_admin_password_command"

초기 admin 비밀번호 조회 명령을 **값이 아니라 명령으로** 내보낸다. 이유(L175–176 주석): UI에서 비밀번호를 바꾸는 순간 ArgoCD가 initial-admin-secret을 삭제하므로, data source로 값을 직접 읽으면 그 시점부터 plan이 깨진다. 명령이 PowerShell 문법인 이유(L179–180): 주 셸이 PowerShell 5.1인데 `base64` 명령이 없어 `| base64 -d` 형태가 그대로 붙여넣으면 실패했다(2026-08-05) — `[System.Convert]::FromBase64String`으로 대체.

### L189–192 · output "argocd_port_forward_command"

internal ALB라 도메인 접속이 안 되므로(사설 IP로 해석 — 의도된 동작) `kubectl port-forward svc/argocd-server -n argocd 8080:80` 명령을 내보낸다. 반드시 80 포트 + `http://` — server.insecure=true라 파드가 평문으로 떠 있어 https로 붙으면 connection reset이 난다.

---

## terraform/eso.tf (222줄)

External Secrets Operator 파일이다. 도입 트리거는 감사 #1이 정한 "state에 secret_string이 다시 들어가는 시점 = ESO 도입"이 ArgoCD PAT로 발동된 것(백로그 B3). 구조 전환의 요지(L7–11): 기존에는 `TF_VAR_argocd_git_pat` → Terraform이 K8s Secret 생성 → tfstate에 PAT 평문. 현재는 Secrets Manager(값은 사람/스크립트가 CLI로 주입) → 클러스터 안의 ESO가 직접 동기화 → Terraform은 값을 모른다. PAT 시크릿 컨테이너 자체는 2026-08-06에 `../persistent`로 옮겼다 — `recovery_window_in_days = 0`이라 destroy 때 값까지 즉시 사라져, 재구축마다 사람이 값을 다시 넣기 전까지 ESO→ArgoCD→앱 배포가 통째로 멈춰 사이트가 503이 됐기 때문(8/5, 8/6 연속 발생). 지금은 persistent-data.tf의 data source로 조회만 한다. 참고로 Redis auth_token은 ESO로 못 뺀다 — 리소스 인자라서 state 잔존이 구조적으로 불가피하며, ESO가 해결하는 것은 "Terraform이 값을 K8s Secret으로 나르면서 생기는" 노출이다.

시크릿은 용도별 2개로 분리돼 있다: `gochuchamchi/argocd/gitops-read-pat`(ArgoCD repo 인증용, Read-only)와 `gochuchamchi/argocd/image-updater-write-pat`(write-back용 RW). 권한 분리 — 읽기만 필요한 컴포넌트에 쓰기 토큰을 주지 않는다.

### L59–92 · resource "null_resource" "inject_git_pat"

구(공용) PAT 자동 주입 — 롤백용으로 남겨둔 것(L94 주석). `triggers.secret_arn`: 시크릿이 재생성되면 ARN 끝 랜덤 접미사가 바뀌므로 재구축마다 다시 돈다. local-exec(PowerShell) 스크립트를 명령 단위로:

1. 보간으로 secret-id/region/profile을 셸 변수에 담는다(값이 아니라 이름만 — PAT는 Terraform을 거치지 않는다).
2. `if (-not $env:ARGOCD_GIT_PAT)` — 환경변수가 없으면 안내 메시지(미주입 시 503이 된다는 경고 + 수동 주입 명령)를 찍고 `exit 0`으로 조용히 건너뛴다. apply를 실패시키지 않는다.
3. `aws secretsmanager get-secret-value ... 2>$null` 후 `$LASTEXITCODE -eq 0`이면 "값이 이미 있음 — 건너뜀". 컨테이너만 있고 버전이 없으면 ResourceNotFoundException이 나는 것을 "빈 상태"의 신호로 쓴다. **덮어쓰지 않는 이유**(L55–57 주석): 로테이션은 의도한 사람이 명시적으로 해야 하는 작업이고, 세션에 낡은 환경변수가 남아 있다가 운영 중 PAT를 조용히 옛 값으로 되돌리는 사고를 막기 위함이다.
4. `aws secretsmanager put-secret-value`로 주입하고 실패 시에만 `exit 1`. 성공 시 PAT 길이만 출력한다(값은 로그에도 안 남긴다).

이 설계로 PAT는 terraform 변수·state·plan 출력 어디에도 들어가지 않는다 — 셸이 환경변수를 직접 읽기 때문이다(L46–49 주석).

### L95–114 · resource "null_resource" "inject_gitops_read_pat"

같은 패턴의 Read PAT 버전. 환경변수 `ARGOCD_GITOPS_READ_PAT`, 대상은 gitops-read-pat 시크릿. 로직(없으면 스킵 → 있으면 스킵 → 빈 컨테이너면 주입)은 동일하다.

### L116–135 · resource "null_resource" "inject_image_updater_write_pat"

Write PAT 버전(`ARGOCD_IMAGE_UPDATER_WRITE_PAT`). 역시 동일 패턴.

### L140–164 · module "eso_pod_identity"

terraform-aws-modules/eks-pod-identity(`~> 2.0` 버전 핀). ESO 컨트롤러가 이 스택의 시크릿 **만** 읽도록 custom policy의 resources를 read/write PAT 두 ARN으로 정확히 제한한다(`secretsmanager:GetSecretValue`/`DescribeSecret`) — iamRole.tf에서 `rds!*` 와일드카드를 걷어낸 것과 같은 최소권한 원칙(L138–139 주석). association은 namespace `external-secrets` / SA `external-secrets`.

### L166–183 · resource "helm_release" "external_secrets"

ESO 본체 차트. depends_on에 LB 컨트롤러가 있는 이유 — 이 차트도 webhook Service를 만들므로 컨트롤러의 mutating webhook 준비 이후에 설치해야 한다(external-dns와 동일한 이유). `set`으로 `serviceAccount.name = "external-secrets"`를 고정 — 위 Pod Identity association의 SA 이름과 정확히 일치해야 IAM이 붙는다.

### L188–214 · resource "helm_release" "eso_config"

ClusterSecretStore/ExternalSecret CR을 로컬 차트(`charts/eso-config`)로 배포한다. kubectl 프로바이더 대신 helm으로 감싸는 이유는 argocd.tf의 Application과 동일(첫 apply의 "known after apply" plan 실패 회피). depends_on 순서의 근거(L193–197 주석): CRD·webhook은 external_secrets가, 대상 네임스페이스(argocd)는 argocd 차트가 만들고, **PAT 주입(null_resource 2종)을 앞에 두는 이유** — ExternalSecret CR이 배포되는 시점에 값이 이미 있어야 첫 동기화가 바로 성공한다. 값이 없는 채로 CR이 뜨면 SecretSyncedError로 떨어지고 refreshInterval이 1h라 나중에 값을 넣어도 최대 1시간을 기다린다(2026-08-05에 force-sync 어노테이션으로 수동 재촉해야 했던 실전 사유). values는 region, 두 시크릿 이름, repoURL, username — 차트가 ExternalSecret의 remoteRef와 ArgoCD repo Secret 템플릿에 꽂는 값들이다. **운영 함정**: 이 시크릿들은 property 지정 없이 통째로 읽으므로 시크릿 값 전체가 PAT 문자열이어야 한다(JSON 아님). put-secret-value 때 끝에 개행이 붙으면 그 개행까지 PAT의 일부가 되어 GitHub 인증이 **조용히** 실패한다.

### L216–222 · output "argocd_git_pat_inject_commands"

read/write PAT의 수동 주입/로테이션 명령 두 줄을 맵으로 내보낸다. 자동 주입이 안 되는 환경(환경변수 미설정)에서 복사·실행할 수 있게 한 운영 편의 장치.

---

## terraform/kyverno.tf (120줄)

정책 엔진 설치 파일. PSA와의 역할 분담이 머리 주석(L4–11)에 정리돼 있다: PSA(enforce=baseline)는 API 서버 내장 기능으로 컨테이너 탈출 벡터를 "차단"하는 1차 방어선, Kyverno(audit=restricted)는 restricted 위반을 PolicyReport로 "계량"하는 상시 준수 현황판(`kubectl get polr -A`)이다. PSA enforce를 restricted로 올리기 전에 "지금 뭐가 걸리는지"를 이 리포트로 확인한다. 머리 주석의 경고(L21–25)가 이 파일의 가장 중요한 교훈이다: `validationFailureAction`(정책을 **위반한** 요청의 처리)과 `failurePolicy`(**웹훅에 연결 자체가 안 될 때**의 처리)는 다른 것이다 — Audit으로 뒀다고 안전한 게 아니며, 차트 기본 failurePolicy=Fail이면 Kyverno가 사라졌을 때 남은 웹훅이 클러스터의 모든 변경 요청을 막는다(2026-08-04 혼동 사고).

### L33–86 · resource "helm_release" "kyverno"

Kyverno 본체(버전 3.8.2 핀). depends_on이 길다: EKS/NAT/라우트/VPC(destroy 시 NAT 경로보다 먼저 정리되는 순서), LB 컨트롤러(그 webhook이 클러스터 전역 Service 생성을 가로채므로 준비 전에 Kyverno Service를 만들면 "no endpoints available" 실패 — 2026-08-03 1차 apply 실증), `kyverno_ecr_pod_identity`(서명 검증용 ECR 권한). values 키별로:

- `admissionController.replicas = var.image_signature_validation_action == "Deny" ? 3 : 1`: Kyverno 권장 HA 최소 3대지만, 서명 정책이 Audit인 동안은 t3.small 2대의 비용 절충으로 1대를 유지하고, Deny(fail-closed)를 선택하는 순간 3대로 확장한다 — 웹훅 응답자가 전멸하면 클러스터 admission 전체가 잠기는 경로를 보호하는 조건부 HA다.
- `admissionController.podDisruptionBudget`: 같은 조건으로 enabled + `minAvailable = 2`. Deny 모드에서 노드 드레인이 admission을 죽이지 못하게.
- `admissionController.container.resources`: requests cpu 50m/mem 128Mi, limits mem 384Mi — t3.small 급 노드 예산.
- `reportsController.resources`: requests 50m/64Mi, limits 256Mi.
- `backgroundController/cleanupController.enabled = false`: mutate-existing/generate/cleanup 정책을 안 쓰므로 꺼서 파드 2개 분량의 메모리를 아낀다.

### L89–120 · resource "helm_release" "kyverno_policies"

restricted 프로파일 정책 팩(버전 3.8.1). values:

- `podSecurityStandard = "restricted"` + `validationFailureAction = "Audit"`: 위반을 차단하지 않고 PolicyReport에 기록만. PSA enforce 승격과 같은 시점에 "Enforce"로 승격 예정.
- `background = true`: 이미 떠 있는 파드도 리포트 대상에 포함 — 신규 admission만 보면 기존 위반이 안 보인다.
- `failurePolicy = "Ignore"`: 이 파일의 흉터다. 차트 기본값 Fail을 그대로 두면 Kyverno가 없을 때 API 서버가 모든 변경을 거부한다 — Kyverno의 resource webhook은 helm이 만드는 게 아니라 컨트롤러가 런타임에 등록하므로 helm uninstall 후에도 웹훅만 클러스터에 남기 때문이다. 2026-08-04 destroy가 실제로 이것 때문에 막혔다: kyverno 서비스 삭제 → 웹훅만 잔존 → "service kyverno-svc not found"로 파드 삭제 불가 → 네임스페이스 Terminating 고착 → helm uninstall 실패. Ignore면 웹훅이 고아가 돼도 요청이 통과한다. 이 차트는 Audit 계량 용도라 Ignore가 맞고, fail-closed가 필요한 이미지 서명 정책만 Deny 승격 시 failurePolicy=Fail + admission HA를 함께 적용한다(image-signing.tf).

---

## terraform/k8s-network-policies.tf (132줄)

클러스터 내부 east-west 차단(백로그 B5). 문제의식(L4–6): 모든 파드가 노드 SG를 공유하므로 RDS SG의 "EKS 노드만 허용"은 노드 단위지 파드 단위가 아니다 — grafana든 external-dns든 어떤 파드라도 RDS 3306/Redis 6379에 도달할 수 있었다. 인터넷에 노출된 최고위험 파드(웹앱)부터 잠근다. 범위는 gochuchamchi 네임스페이스만 — 시스템 네임스페이스는 컨트롤러들의 egress 요구가 넓고 깨지기 쉬워 의도적으로 제외했다. 시행 전제는 vpc-cni의 `enableNetworkPolicy=true`(main.tf)이고, 꺼져 있으면 이 리소스들은 존재해도 아무것도 차단하지 않는다. 롤백은 `kubectl -n gochuchamchi delete netpol --all` 한 줄(다음 apply가 복원). 머리 주석에 DNS부터 확인하는 검증 명령 세트까지 있다 — "여기서 막히면 나머지 규칙이 맞아도 앱은 전부 500".

### L26–36 · resource "kubernetes_network_policy_v1" "gochuchamchi_default_deny"

빈 `pod_selector {}`(= 네임스페이스 전체 파드)에 `policy_types = ["Ingress", "Egress"]` — 명시적으로 허용된 트래픽 외 전부 거부하는 기본 자세. 허용 규칙은 다음 리소스가 얹는다.

### L39–132 · resource "kubernetes_network_policy_v1" "gochuchamchi_web_allow"

`pod_selector.match_labels = { app = "gochuchamchi-web" }` — gitops Deployment의 파드 라벨과 일치해야 하며, 어긋나면 이 정책이 아무 파드에도 안 걸리고 default-deny만 남아 앱이 전부 죽는다(contract.tf pod_labels 항목의 존재 이유). 규칙별로:

- **ingress (L55–65)**: VPC CIDR → 8080/TCP 하나. ALB(target-type ip라 ALB ENI가 직접 파드로) + kubelet 헬스체크(노드 IP) 모두 VPC 대역이라 한 규칙으로 커버. 그 외 포트 전부 거부.
- **egress 1 — DNS (L75–90)**: 목적지에 **서비스 CIDR**(`module.eks.cluster_service_cidr`)과 VPC CIDR을 모두 열고 53/UDP+TCP. 이 프로젝트에서 가장 비싼 수업료를 낸 규칙이다(L67–74 주석): 파드 resolv.conf의 nameserver는 kube-dns ClusterIP(10.100.0.10, 서비스 CIDR)이고, ClusterIP→coredns 파드 IP 변환(kube-proxy DNAT)은 패킷이 파드 veth를 **떠난 뒤** 호스트에서 일어난다. vpc-cni의 eBPF 정책 엔진은 veth egress 훅에서 평가하므로 DNAT 전의 원래 목적지 ClusterIP를 본다 → VPC CIDR(172.30.0.0/16)만 열면 서비스 CIDR(10.100.0.0/16)이 빠져 DNS가 전부 막히고, 앱은 RDS/Redis 호스트명 해석 실패(UnknownHostException)로 500을 낸다. 2026-08-04 실제 장애로 확인된 내용이다. VPC 대역을 함께 두는 것은 파드 IP 직행 DNS 경로와 노드 로컬 캐시 대비.
- **egress 2 — DB/Redis (L94–106)**: VPC CIDR로 3306/TCP + 6379/TCP. "노드 SG 허용"보다 좁은 파드 단위 제한이 이 규칙의 핵심.
- **egress 3 — HTTPS (L110–118)**: 0.0.0.0/0의 443/TCP. S3 업로드·AWS API 등 앱의 외부 호출이 전부 443이고 목적지 IP가 동적이라 IP는 제한하지 않는다. 대신 443 아닌 임의 포트(리버스쉘 등)는 막힌다.
- **egress 4 — Pod Identity 에이전트 (L122–130)**: 링크로컬 고정 주소 `169.254.170.23/32`의 80/TCP. 노드 hostNetwork로 도는 EKS Pod Identity Agent 경로로, 이게 막히면 앱의 S3 자격증명 발급이 실패한다 — default-deny 도입 시 가장 자주 놓치는 경로라고 주석이 못박는다.

---

## terraform/resource-limits.tf (81줄)

리소스 폭주 방어. 문제(L3–7): t3.small(2GiB, allocatable ~1.4GiB) 2대에서 limits 없는 파드 하나가 메모리를 무한정 먹으면 kubelet이 시스템 파드까지 눌려 노드 전체가 NotReady로 떨어질 수 있다(OOMKill 순서는 QoS 클래스 기준). 2단 방어: LimitRange가 기본값을 자동 주입하고, ResourceQuota가 네임스페이스 총량을 상한한다. 주석의 admission 순서 설명(L14–17)이 면접 포인트다 — ResourceQuota가 걸린 네임스페이스에서 requests/limits 없는 파드는 원래 거부되지만, LimitRange의 기본값 주입이 먼저 실행되므로(admission 순서: LimitRange → ResourceQuota) 실제로는 거부될 일이 없다. 이 조합이 코드 수정 없이 "limits 필수화"를 달성한다.

### L29–61 · resource "kubernetes_limit_range_v1" "gochuchamchi"

Container 타입 limit 하나: `default_request`(cpu 100m/mem 256Mi — requests를 안 적은 컨테이너에 주입), `default`(cpu 500m/mem 768Mi — limits를 안 적은 컨테이너에 주입; Spring Boot의 JVM 힙+메타스페이스를 감안한 값), `max`(cpu 1/mem 1Gi — 어떤 컨테이너도 이 이상 선언 불가, 파드 하나가 노드 하나를 통째로 못 먹게). gitops Deployment가 limits를 빠뜨려도 안전값이 들어가는 안전망이다.

### L63–81 · resource "kubernetes_resource_quota_v1" "gochuchamchi"

네임스페이스 총량: pods 20, requests.cpu 3 / requests.memory 3Gi, limits.cpu 6 / limits.memory 6Gi. 산정 근거(L20–23 주석): 노드 4대 풀스케일 기준 allocatable(~5.6GiB)의 약 70%를 앱 네임스페이스에 허용하고 시스템/모니터링 몫을 남긴다. HPA가 폭주해도 노드 용량을 넘는 예약 자체가 admission에서 거부된다.

---

## terraform/image-signing.tf (134줄)

이미지 서명 검증의 "검증하는 쪽" 파일이다. 신뢰 경로(L4–8): GitHub main 브랜치 → `github_actions_ecr_push` 역할로 빌드 → `candidate-<SHA>` push, 보호된 GitHub Environment → `github_actions_image_signer` 역할 → KMS Sign → Cosign 서명 → `signed-<SHA>`. 빌드 역할은 KMS 서명 키를 쓸 수 없다(권한 분리 — 빌드가 뚫려도 서명은 못 만든다). Kyverno는 이 KMS 키로 만든 서명만 신뢰하고, 기존 워크로드를 끊지 않도록 Audit 모드로 시작한다. 2026-08-06에 KMS 키와 서명 역할은 `../persistent`로 이관됐다 — 재구축 때 키가 새로 생기면 GitHub 변수(IMAGE_SIGNING_KMS_KEY_ARN)와 어긋나 CI 서명 잡이 실패하고, ECR에 이미지가 안 올라가 사이트가 503으로 남기 때문이다. 이 파일에는 "그 키를 신뢰해서 검증하는" 쪽만 남는다.

### L18–24 · locals image_signing_tags

공통 태그.

### L27–29 · data "aws_kms_public_key" "image_signing"

상시 계층의 서명 키에서 **공개키**만 뽑는다. 개인키는 KMS 밖으로 절대 나오지 않는다 — Kyverno 정책에는 공개키(PEM)만 들어가고, 서명 생성은 CI가 KMS Sign API로 한다.

### L35–63 · resource "aws_iam_policy" "kyverno_ecr_signature_read"

Kyverno가 private ECR의 Cosign 서명 아티팩트를 읽을 권한. 문 2개: `ecr:GetAuthorizationToken`(Resource `*` — 이 액션은 리소스 지정이 불가한 계정 수준 액션), 그리고 이미지·서명 읽기 4액션(`BatchCheckLayerAvailability`/`BatchGetImage`/`DescribeImages`/`GetDownloadUrlForLayer`)을 gochuchamchi 저장소 ARN 하나로 한정. Cosign 서명은 ECR에 이미지와 나란히 OCI 아티팩트로 저장되므로 이미지 읽기 권한이 곧 서명 읽기 권한이다.

### L65–81 · module "kyverno_ecr_pod_identity"

위 정책을 Pod Identity로 kyverno namespace의 `kyverno-admission-controller` SA에 연결한다(`~> 2.0` 버전 핀). 서명 검증을 수행하는 주체가 admission controller라서 그 SA에만 붙인다.

### L87–110 · resource "helm_release" "image_signature_policy"

로컬 차트(`charts/image-signing-policy`)로 네임스페이스 범위 Kyverno ImageValidatingPolicy를 배포한다. values 키별로:

- `validationAction = var.image_signature_validation_action`: Audit(기본) 또는 Deny.
- `failurePolicy = ... == "Deny" ? "Fail" : "Ignore"`: kyverno.tf의 교훈이 코드가 된 줄이다. Deny로 승격하면 웹훅 연결 실패도 요청 거부(fail-closed)로 바뀌는데, 그 순간 kyverno.tf의 admission replicas 3 + PDB가 같은 변수로 함께 켜져 fail-closed 경로를 보호한다. Audit 동안은 Ignore로 두어 Kyverno 장애가 클러스터를 잠그지 않게 한다.
- `imageRepository`: 정책이 검사할 이미지 저장소(ECR URL).
- `publicKey = data.aws_kms_public_key.image_signing.public_key_pem`: 신뢰 앵커. 이 공개키로 검증되는 서명만 통과.
- `mutateDigest`/`verifyDigest`(Deny일 때만 true): 태그를 digest로 치환·검증해 "서명 확인 후 태그가 다른 이미지로 바뀌는" TOCTOU를 막는다. Audit에서는 꺼서 동작 변형을 피한다.

depends_on: kyverno 본체(CRD), pod identity(ECR 읽기), 네임스페이스.

### L116–134 · output 4종

`github_actions_image_signer_role_arn`(실체는 persistent 관리 — CI 설정 대조용), `image_signing_kms_key_arn`, `image_signing_kms_uri`(`awskms:///<arn>` — cosign `--key` 인자 형식 그대로), `image_signature_validation_action`(현재 모드 확인용 — 검증 스크립트가 Audit/Deny 상태를 읽는 창구).

---

## terraform/image-signing-variables.tf (21줄)

### L1–10 · variable "image_signing_github_environment"

서명 역할 assume이 허용되는 보호된 GitHub Environment 이름(기본 "production-signing"). validation은 공백 불가(trimspace 후 길이 검사). 실체(신뢰 정책의 sub 조건)는 persistent 쪽에 있고, 여기서는 참조용.

### L12–21 · variable "image_signature_validation_action"

Kyverno 서명 정책 모드. `contains(["Audit", "Deny"], ...)` validation으로 두 값만 허용. 기본 Audit. 이 변수 하나가 image-signing.tf의 failurePolicy/mutateDigest/verifyDigest와 kyverno.tf의 replicas/PDB까지 총 5곳의 동작을 일괄 전환한다 — "Deny 승격"이 원자적 한 번의 변수 변경이 되도록 설계된 것.

---

## terraform/contract.tf (103줄)

배포 계약 파일이다. 기원은 2026-08-04 장애(L4–13): terraform apply와 gitops 수정이 한 세트인 작업에서 gitops 쪽만 누락 — terraform이 K8s Secret 이름을 바꿨는데 gitops의 03-deployment-web.yml이 옛 이름을 계속 참조해 새 파드는 CreateContainerConfigError, 기존 파드는 접속 거부로 500, 이중 잠김. 교훈은 "체크리스트가 문서에 있어도 강제 장치가 없으면 누락된다" — 그래서 두 저장소 사이의 인터페이스를 사람이 기억하는 대신 코드가 선언하게 했다. 사용처 4가지(L15–21): 사람이 `terraform output -json deployment_contract`로 열람, `verify-contract.ps1` 수동 검증, smoke-test.tf가 apply 후 자동 검증, (다음 단계) gitops PR 시 GitHub Actions 머지 차단. 주의(L23–26): 이 파일에는 "값"이 아니라 "이름/키"만 넣는다 — 비밀값을 넣으면 output이 tfstate·CLI에 노출되어 애써 없앤 노출 경로가 부활한다. `kubernetes_secret_v1.data`는 provider가 sensitive로 표시해 `keys()`로 뽑으면 output 자체가 거부되므로 secrets의 keys는 의도적으로 문자열 리터럴이다.

### L29–94 · locals deployment_contract

계약 본문. 필드별로:

- `version = 1`: 깨는 변경(이름 삭제/키 변경) 시 올리는 계약 버전. gitops 쪽 검증 스크립트가 모르는 버전을 만나면 경고하게 하기 위한 장치.
- `cluster_name`/`namespace`/`service_account`: 실제 리소스 속성 참조 — 리소스가 바뀌면 계약도 자동으로 따라간다.
- `config_maps`: terraform이 만들어 주는 것(gitops는 참조만). name과 `sort(keys(...))`로 실제 ConfigMap의 키 목록을 산출 — ConfigMap은 sensitive가 아니라 keys()가 허용되고, sort로 순서 변동에 의한 가짜 diff를 막는다. owner 필드로 소유 파일까지 명시.
- `secrets`: redis secret 하나만 남았다. L49–51 주석이 변화를 기록한다 — (2026-08-13) `gochuchamchi-db-app`이 목록에서 빠졌다. IAM 토큰 전환으로 앱 DB 비밀번호가 없어졌고, 그 Secret을 만들던 배스천 프로비저닝도 제거했으며, 아래 forbidden_refs로 옮겨 gitops가 계속 참조하면 검증에서 잡히게 했다.
- `service` (name "gochuchamchi-web-svc", port 80): **반대 방향** 계약 — gitops가 만들어야 하는 것. Ingress(k8s-deploy.tf)가 이 이름으로 백엔드를 잡으므로 gitops에서 이름이 바뀌면 ALB 타겟이 사라져 503.
- `pod_labels = { app = "gochuchamchi-web" }` / `container_port = 8080`: NetworkPolicy의 pod_selector와 반드시 일치해야 한다. 라벨이 어긋나면 정책이 아무 파드에도 안 걸리고 default-deny만 남아 앱이 전부 죽는다 — "무해해 보이는" 불일치가 전면 장애가 되는 사례.
- `forbidden_refs`: 참조 금지 목록. `gochuchamchi-db-secret`(마스터 계정 시절)과 `gochuchamchi-db-app`(비밀번호 계정 시절, 2026-08-13 추가). "지운 이름을 지웠다고 기록해두지 않으면 다음 사람이 옛 문서를 보고 되살린다" — 검증 스크립트는 이 이름이 gitops에 남아 있으면 실패시킨다. db-app 주석은 gitops 수정이 terraform 커밋보다 먼저여야 하는 이유(참조 잔존 시 8/4와 정확히 같은 CreateContainerConfigError)까지 남긴다.
- `endpoints`: 재구축마다 바뀌는 값(db_host/redis_host/hosts). gitops는 이 값을 몰라야 정상이고(ConfigMap 경유 주입), 스모크 테스트가 DNS/TCP 도달성 확인에 쓴다.

### L96–103 · output "deployment_contract"

계약 전체를 output으로. description에 사용 명령(output -json → verify-contract.ps1)이 담겨 있다. 이 output이 곧 "terraform이 만들어주는 것 / gitops가 참조해야 하는 것"의 계약서 실체다.

---

## terraform/ci-sync.tf (185줄)

"재구축 후 사람이 손으로 메우던 간극을 apply 안으로 넣는" 파일(2026-08-06). 그날 재구축 직후 사이트가 503이었는데 원인이 terraform 바깥에 흩어져 있었다: (1) kubeconfig가 옛 클러스터를 가리킴 — 증상이 인증 실패가 아니라 DNS 실패(no such host)라 오해하기 쉽고 kubectl 진단 자체가 막힌다, (2) GitHub Actions 변수 IMAGE_SIGNING_KMS_KEY_ARN이 옛 KMS 키(PendingDeletion)를 가리킴 — 서명 잡 실패 → ECR에 이미지 없음 → 503, 원인이 3단계 떨어져 있어 추적이 길다, (3) ECR이 비어 있음 — force_delete가 destroy 때 이미지까지 지웠던 문제는 같은 날 `../persistent` 분리로 제거했지만, "이미지 없음" 상태는 다른 경로(수동 삭제, lifecycle 만료, 최초 구축)로도 생기므로 확인 단계는 유지. 설계 원칙(L23–27): 1)·2)는 멱등이라 자동으로 고치고, 3)은 자동 복구 불가(이미지를 만들 수 있는 건 CI뿐)라 진단만 한다. 어느 쪽도 apply를 실패시키지 않는다 — 재구축 도중에는 "아직 안 된 상태"가 정상이기 때문(smoke-test.tf의 경고 모드 원칙).

### L35–58 · resource "null_resource" "sync_kubeconfig"

trigger는 `module.eks.cluster_endpoint` — 클러스터가 새로 생기면 엔드포인트가 바뀌어 재구축마다 다시 돈다. 스크립트: (1) `Get-Command aws`로 CLI 존재 확인, 없으면 건너뜀(exit 0), (2) `aws eks update-kubeconfig --name <cluster> --region <r> --profile <p>` 실행 — 멱등이라 재구축이 아니어도 무해, (3) 실패 시에도 수동 명령을 출력하고 exit 0(apply를 막지 않음). 이후 단계(wait_for_app_ready, smoke test)가 전부 kubectl에 의존하므로 가장 먼저 돈다.

### L72–123 · resource "null_resource" "sync_github_ci_variables"

trigger는 4개 값(ECR URL, 빌드 역할 ARN, 서명 역할 ARN, 서명 키 ARN) — 하나라도 바뀌면(=재구축) 재동기화. **provider 대신 gh CLI를 쓰는 이유**(L63–67 주석)가 이 파일의 설계 핵심이다: integrations/github provider는 PAT를 terraform 변수로 받아야 하는데, 이 저장소는 이미 "terraform 변수에 토큰을 두지 않는" 방향(eso.tf)을 잡았고 두 번째 토큰 경로를 만들고 싶지 않다. gh CLI는 운영자가 이미 로그인해 둔 자격증명을 쓰므로 새 비밀이 늘지 않는다. 스크립트 흐름: (1) 대상 저장소(`<owner>/gochuchamchi-spring`)와 변수 4개를 ordered 해시테이블로 구성, (2) `Show-Manual` 함수 — 실패 시 `gh variable set ...` 4줄을 복사·실행 가능한 형태로 출력, (3) gh 존재 확인 → 없으면 수동 안내 후 exit 0, (4) `gh auth status`로 로그인 확인 → 안 돼 있으면 수동 안내 후 exit 0, (5) 4개 변수를 루프로 `gh variable set` — 개별 실패를 집계하고, (6) 하나라도 실패면 수동 안내, 전부 성공이면 완료 메시지. 어떤 경로든 exit 0 — CI 등 gh 없는 환경에서 apply가 막히지 않는다.

### L138–185 · resource "null_resource" "verify_ecr_has_image"

trigger `always_run = timestamp()` — apply마다 항상 실행(그래서 plan에 항상 replace로 뜬다). depends_on: ECR data source + 위 GitHub 변수 동기화(변수가 맞아야 "CI를 돌리세요" 안내가 유효하다). 스크립트: (1) aws CLI 확인, (2) `aws ecr list-images ... --query "imageIds[].imageTag" --output json`으로 태그 목록 조회, 실패 시 건너뜀, (3) `$_ -match '^signed-[0-9a-f]{40}$'`로 **signed- 태그만** 센다 — Image Updater가 감시하는 대상이 정확히 이 패턴이라 candidate만 있고 signed가 없으면 배포는 일어나지 않으므로, "배포 가능한 이미지 수"는 signed 기준으로 세야 의미가 있다(L133–136 주석), (4) 있으면 개수 출력 후 종료, (5) 없으면 배너 형태의 경고 — "이대로 두면 503", 원인 후보(최초 구축/수동 삭제/lifecycle 만료), 복구 명령(`gh workflow run 'Build and sign release image'` + `gh run watch`)까지 출력한다. 이 확인이 없으면 운영자는 ECR이 아니라 ArgoCD나 네트워크를 먼저 의심하게 되고, 실제로 2026-08-06에 그렇게 시간을 썼다.

---

## terraform/smoke-test.tf (215줄)

apply 후 검증 파이프라인(1/2 대기 + 2/2 검사). 이 프로젝트에서 반복된 실패 유형이 머리 주석(L7–15)에 나열돼 있다: 8/3 schema.sql 미실행(프로비저너가 Status를 안 봐서 apply는 성공, 회원가입 500), 8/3 ECR 비어 ImagePullBackOff 503, 8/4 PAT 미주입으로 앱 미배포, 8/4 NetworkPolicy DNS 결함으로 전체 500 — 공통점은 **"apply 성공"이 "서비스 정상"을 전혀 보장하지 않는다**는 것이고, 그 간극을 사람이 손으로 메우던 것을 apply 파이프라인 안으로 넣었다. 기본은 경고 모드다: 재구축 직후에는 PAT 주입 전이라 앱이 안 떠 있는 게 정상이므로 apply를 실패시키면 재구축 자체가 막힌다. 운영 중 변경에는 `TF_VAR_..._enforce=true`로 "서비스를 깨는 apply는 실패로 기록"되게 올리는 것이 목표 상태다.

이 파일의 null_resource 2개와 ci-sync.tf의 verify_ecr_has_image, 총 3개가 `always_run = timestamp()` 트리거라서 **plan마다 항상 3 add/3 destroy(교체)가 뜬다 — 정상이며, 이 루트에서 "No changes"는 구조적으로 불가능하다.** plan 결과를 읽을 때 이 3개는 소음으로 걸러야 한다. 스모크 테스트는 "코드가 바뀔 때"가 아니라 "인프라를 건드릴 때마다" 돌아야 의미가 있다는 의도적 트레이드오프다(L24–26 주석).

### L47–63 · variable wait_for_app_ready / _enforce / _timeout_seconds

대기 단계의 3변수: 대기 여부(기본 true), 시간 내 미기동 시 apply 실패 처리 여부(기본 false = 경고만), 제한 시간(기본 600초 — ArgoCD sync + 이미지 pull + Spring 기동 약 40초 + 노드 스케일업까지 감안한 값).

### L65–68 · locals app_ready_selector

계약의 pod_labels 맵을 `join`으로 kubectl `-l` 셀렉터 문자열(`app=gochuchamchi-web`)로 변환한다. 검증 기준이 contract.tf 한 곳에서 나오게 하는 배선.

### L70–151 · resource "null_resource" "wait_for_app_ready"

`always_run = timestamp()`로 apply마다 실행. depends_on이 사실상 "앱이 뜨기 위한 전제조건 목록"이다: EKS, Ingress, NetworkPolicy, `provision_app_db_iam_user`(앱이 IAM 토큰으로 붙을 DB 계정이 먼저 있어야 한다), PAT 주입 2종, `sync_kubeconfig`(아래 kubectl들이 새 클러스터를 보게), `verify_ecr_has_image`(이미지가 없으면 기다려도 안 뜬다 — 먼저 알린다), eso_config. 스크립트를 단계별로:

1. 보간으로 namespace/selector/timeout/enforce를 받고, `Stop-Wait` 함수를 정의 — enforce면 `Write-Error` + exit 1로 apply를 실패시키고, 아니면 경고 후 exit 0. 실패 처리의 단일 출구다.
2. kubectl 없으면 Stop-Wait.
3. `kubectl get namespace $ns`로 클러스터 접속 자체를 확인 — 실패 시 "kubeconfig가 옛 클러스터를 가리킬 수 있다"는 진단과 update-kubeconfig 명령을 안내한다(증상이 DNS 해석 실패라 원인을 오해하기 쉬운 그 문제).
4. 폴링 루프 1: deadline까지 15초 간격으로 `kubectl get deploy -n $ns -l $selector -o name` — ArgoCD가 Deployment를 만들 때까지 기다린다. Terraform은 이 Deployment를 만들지 않으므로 의존성 그래프로 표현할 수 없어 폴링이 유일한 방법이다(L37–39 주석).
5. 시간 내에 안 나타나면 **원인 확인 순서**까지 담은 메시지로 Stop-Wait: 1) ECR에 signed- 이미지 없음(이번 apply 로그의 ECR 확인 단계 참고), 2) ArgoCD가 저장소에 못 붙음(PAT 미주입 — `kubectl get externalsecret -n argocd`), 3) ArgoCD 자체가 죽음(리소스 부족 — `kubectl get pods -n argocd` / `kubectl top nodes`). 2026-08-06에 ECR 비움+ArgoCD 다운이 겹쳤는데 PAT만 의심하다 진단이 길어진 경험이 이 순서를 만들었다.
6. 폴링 루프 2: 남은 시간(최소 30초 보장)으로 `kubectl rollout status $deploy --timeout` — Deployment가 생긴 뒤 Ready까지. 실패 시 pod/events 확인 명령과 함께 Stop-Wait. 참고로 L140–141 주석은 PowerShell 함정을 기록한다 — `$remain초`처럼 한글이 변수명에 바로 붙으면 PowerShell이 "초"까지 변수명으로 먹어 빈 값이 된다(변수명에 유니코드 허용). `$($remain)초`로 끊어야 한다.

### L158–177 · variable smoke_test_after_apply / smoke_test_enforce / pod_identity_autofix

검사 단계의 3변수. autofix 기본이 true인 근거(L170–172 주석): Pod Identity 자격증명이 누락된 파드는 재시작 말고 고칠 방법이 없다(주입은 파드 생성 시 1회뿐) — 그대로 두면 그 파드의 AWS 호출은 영원히 실패하므로 검출과 복구를 분리할 실익이 없다.

### L179–215 · resource "null_resource" "post_apply_smoke_test"

`always_run` 트리거, depends_on은 검사 대상 전부 + `wait_for_app_ready`(앱이 뜬 뒤에 검사해야 결과가 의미 있다). provisioner의 세부가 전부 실전 흉터다:

- `interpreter`의 `-ExecutionPolicy Bypass`: 이 프로비저너는 인라인이 아니라 `.ps1` **파일**을 실행하는데, CurrentUser 정책이 RemoteSigned이고 git/다운로드로 받은 파일에는 Zone.Identifier(인터넷 출처 표시)가 붙어 서명 없는 스크립트가 "not digitally signed"로 차단됐다(2026-08-05 apply 실패). Unblock-File은 파일을 새로 받을 때마다 다시 해야 하므로 호출 쪽에서 프로세스 범위로 정책을 우회한다(시스템 정책은 안 바뀜).
- `command` 한 줄: `& '<module>/../scripts/smoke-test.ps1' -ContractJson '<jsonencode(계약)>' -Region ... -AwsProfile ... [-Enforce] [-FixPodIdentity]`. **계약을 인자로 넘기는 이유** — apply 도중에는 state가 확정 전이라 스크립트가 `terraform output`을 부르면 옛 값을 읽거나 실패한다. `replace(jsonencode(...), "'", "''")`는 PowerShell 작은따옴표 이스케이프의 방어적 처리이고, 여러 줄+백틱 연결 대신 한 줄을 유지하는 것도 `-Command` 전달 시 개행 처리로 깨질 수 있어서다. 플래그 2개는 위 변수들을 스위치 인자로 변환한다.

---

## terraform/migration-2026-08-07-removed.tf (493줄)

state 이관용 임시 파일이다. 계정 상시 보안 기반(Athena, AWS Config, CloudTrail, 비용 모니터링, Inspector/ECR 스캔, GuardDuty, IAM 보안, 로그 KMS/아카이브, Security Hub)을 `../account-baseline` 계층으로 옮기면서, **실물 AWS 리소스는 그대로 두고 이 state의 관리 대상에서만 빼는** `removed` 블록 55개를 담는다. 이 리소스들이 런타임 루트에 있으면 daily-down 때마다 계정 보안 기반이 같이 죽는다 — 이관이 daily-down(278 destroy) 체제를 가능하게 한 전제 작업이다.

머리 주석(L7–29)이 이 파일의 전부라 해도 좋다. **왜 `terraform state mv`가 아니라 removed 블록인가**: state mv는 S3 백엔드에서 state를 로컬로 뺐다가 다시 push해야 해서 3인 협업 환경에서 state가 갈라질 여지가 있다. removed 블록은 코드로 남고 plan에서 검토되며, `lifecycle { destroy = false }` 때문에 구조적으로 destroy가 불가능하다. 특히 중요한 대상 셋: `aws_inspector2_enabler`(destroy가 15분 타임아웃 후 tainted로 남음), `module.aws_config`(레코더 삭제/재생성이 구성 항목 수천 건을 다시 기록), `aws_s3_bucket.cloudwatch_log_archive`(Object Lock COMPLIANCE라 애초에 못 지움). 사용 순서도 못박혀 있다: (0) import ID 추출 스크립트를 **이 apply 전에**(apply 후엔 state에 리소스가 없어 ID를 못 뽑는다) → (1) baseline에서 plan으로 "N to import, create/destroy 0" 확인 → (2) 여기서 "N to forget, destroy 0" 확인 후 apply → (3) baseline apply → (4) 이 파일과 baseline의 imports.tf 삭제 후 커밋. (2)와 (3) 사이에는 리소스가 어느 state에도 없는 고아 상태지만, 메인 쪽 코드가 이미 지워져 있어 재생성을 시도하지 않으므로 다시 import하면 된다. 4)까지 끝나기 전에는 다른 apply 금지.

블록 형식은 55개가 전부 동일하다: `removed { from = <주소> lifecycle { destroy = false } }`. 원본 파일별 그룹으로:

### L34–128 · removed × 12 (athena.tf 출신)

`aws_s3_bucket.athena_results`와 부속 5개(ownership_controls/public_access_block/sse/lifecycle/policy), `aws_glue_catalog_database.security_logs`, `aws_glue_catalog_table.cloudtrail`, `aws_athena_workgroup.security_logs`, named query 3개(`recent_management_events`/`failed_api_calls`/`write_events`). 보안 로그 조회 기반은 로그가 상시인 이상 상시여야 한다.

### L132–178 · removed × 6 (aws-config.tf 출신)

Config 전달 버킷과 부속 4개, 그리고 `module.aws_config` — 모듈 전체를 removed 하나로 잊는다(모듈 주소도 from에 쓸 수 있다). 레코더 재생성 시 수천 건 재기록 문제의 그 대상이다.

### L182–188 · removed × 1 (cloudtrail.tf 출신)

`aws_cloudtrail.central`. 감사 추적이 일일 루트에 있으면 destroy 시간대의 API 기록이 끊긴다 — 이관의 대표적 명분.

### L192–214 · removed × 3 (cost-monitoring.tf 출신)

`aws_budgets_budget.monthly`, `aws_ce_anomaly_monitor.services`, `aws_ce_anomaly_subscription.email`. 비용 감시는 인프라가 내려가 있는 밤에도 살아 있어야 의미가 있다.

### L218–232 · removed × 2 (ecr-scanning.tf 출신)

`aws_inspector2_enabler.this`(destroy 15분 타임아웃+tainted 문제의 그 리소스), `aws_ecr_registry_scanning_configuration.this`.

### L236–250 · removed × 2 (flow-logs-analytics.tf 출신)

`aws_glue_catalog_table.vpc_flow_logs`, `aws_athena_named_query.flowlogs`.

### L254–292 · removed × 5 (guardduty.tf 출신)

`aws_guardduty_detector.this`와 feature 4개(eks_audit_logs/s3_data_events/ebs_malware/runtime_monitoring). 위협 탐지를 매일 껐다 켜면 탐지 공백과 베이스라인 재학습이 생긴다.

### L296–350 · removed × 7 (iam-security.tf 출신)

`aws_accessanalyzer_analyzer.account`, console_admins 그룹과 force_mfa 정책·정책 연결·멤버십, `aws_iam_policy.region_guard`와 그 연결. 계정 IAM 통제는 정의상 상시다.

### L354–368 · removed × 2 (kms-logs.tf 출신)

`aws_kms_key.logs`, `aws_kms_alias.logs`. 로그 암호화 키가 매일 죽으면 이전 로그 복호화가 위태로워진다.

### L372–482 · removed × 14 (log-archive.tf 출신)

`aws_s3_bucket.cloudwatch_log_archive`(Object Lock COMPLIANCE — 구조적으로 삭제 불가)와 부속 6개(ownership/pab/versioning/sse/lifecycle/policy), Firehose용 로그 그룹·스트림, Firehose IAM 역할·정책, `aws_kinesis_firehose_delivery_stream.cloudwatch_log_archive`, CloudWatch Logs→Firehose 구독용 IAM 역할·정책. 로그 아카이브 파이프라인 전체가 한 덩어리로 이관됐다.

### L486–492 · removed × 1 (security-hub.tf 출신)

`module.security_hub`. 모듈 통째 이관.

---

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| edge.tf | 511 | 17 (provider 1, locals 1, data 5, resource 8, output 2) | 전체 |
| edge-logs.tf | 296 | 21 (locals 1, data 4, resource 13, output 3) | 전체 |
| edge-logs-variables.tf | 39 | 3 (variable 3) | 전체 |
| dr.tf | 294 | 17 (provider 1, locals 1, resource 13, output 2) | 전체 |
| k8s-deploy.tf | 295 | 10 (data 1, resource 9) + 제거 기록 주석 | 전체 |
| argocd.tf | 192 | 6 (locals 1, helm_release 3, output 2) + 제거 기록 주석 | 전체 |
| eso.tf | 222 | 7 (null_resource 3, module 1, helm_release 2, output 1) | 전체 |
| kyverno.tf | 120 | 2 (helm_release 2) | 전체 |
| k8s-network-policies.tf | 132 | 2 (kubernetes_network_policy_v1 2) | 전체 |
| resource-limits.tf | 81 | 2 (limit_range 1, resource_quota 1) | 전체 |
| image-signing.tf | 134 | 9 (locals 1, data 1, resource 1, module 1, helm_release 1, output 4) | 전체 |
| image-signing-variables.tf | 21 | 2 (variable 2) | 전체 |
| contract.tf | 103 | 2 (locals 1, output 1) | 전체 |
| ci-sync.tf | 185 | 3 (null_resource 3) | 전체 |
| smoke-test.tf | 215 | 9 (variable 6, locals 1, null_resource 2) | 전체 |
| migration-2026-08-07-removed.tf | 493 | 55 (removed 55, 원본 파일별 11개 그룹으로 해설) | 전체 |


---

# terraform (3) — 런타임 루트: 관측·모니터링

이 섹션이 다루는 파일들은 terraform 런타임 루트(매일 daily-up으로 apply되고 daily-down으로 destroy되는 계층)의 "관측·모니터링" 축이다. 데이터 흐름을 한 줄로 그리면 이렇다: **EKS 위의 CloudWatch Observability Add-on(Container Insights 에이전트)이 메트릭과 Pod 로그를 CloudWatch로 밀어 넣고 → 로그에는 metric filter를 걸어 커스텀 메트릭을 뽑아내고 → 그 메트릭(그리고 ALB/RDS/Redis의 AWS 관리형 메트릭)에 CloudWatch Alarm을 걸고 → 알람 상태 변화 이벤트는 EventBridge가 잡아 SNS로 넘기고 → 같은 CloudWatch 데이터를 클러스터 안의 Grafana가 Pod Identity 자격증명으로 읽어 대시보드 3장으로 시각화한다.** 여기에 두 개의 곁가지가 붙는다. 하나는 CloudWatch Logs 구독필터로 로그 원본을 Log 계정의 크로스계정 목적지(Firehose→S3)로 흘려보내는 중앙 수집 배선(log-archive-subscriptions.tf)이고, 다른 하나는 CloudTrail 관리 이벤트를 EventBridge로 직접 잡는 IAM 활동 감시(iam-activity-monitoring.tf)다.

이 루트의 알람들을 보면 한 가지가 눈에 띈다 — **alarm_actions가 전부 비어 있다**. 이것은 실수가 아니라 설계다. 알림 발송은 상시 루트인 cloudwatch-notifications가 맡는다: 그쪽의 EventBridge 규칙이 "CloudWatch Alarm State Change" 이벤트를 **알람 이름 접두사 `gochuchamchi-`로 매칭**해서 SNS(→Discord·이메일)로 발행한다. us-east-1에서 발생하는 알람 이벤트도 relay 규칙으로 서울에 중계된다. 이 구조 덕에 매일 생멸하는 런타임 알람이 상시 알림 채널과 느슨하게 결합되지만, 뒤집어 말하면 **새 알람을 만들 때 이름이 `gochuchamchi-`로 시작하지 않으면 아무 에러 없이 조용히 통보 대상에서 빠진다**. 이 문서 전체에서 반복해서 짚는 진짜 함정이 이것이다.

프로젝트 전체 구조 안에서의 위치도 정리해 두자. management(조직·SSO), log-archive(로그 중앙 수집·SIEM·Athena), account-baseline(상시 보안), persistent(상시 자원), cloudwatch-notifications(알림 허브), discord-notifications가 상시 계층이고, 이 terraform 루트만 매일 생멸한다. 그래서 이 루트의 관측 코드는 "상시 계층이 먼저 준비돼 있어야 한다"는 순서 제약을 곳곳에 품고 있다 — 구독필터는 Log 계정의 Destination이 먼저 apply돼 있어야 생성되고, 알람 통보는 cloudwatch-notifications의 접두사 규칙이 이미 살아 있다는 전제 위에 서 있다.

## terraform/cloudwatch-observability.tf (110줄)

EKS에 Amazon CloudWatch Observability Add-on을 설치해 Container Insights 메트릭과 Pod 애플리케이션 로그 수집을 켜는 파일이다. 구성은 4단계다: (1) 에이전트가 CloudWatch에 쓸 수 있게 하는 Pod Identity IAM 역할, (2) 클러스터 Kubernetes 버전에 맞는 최신 애드온 버전 조회, (3) 애드온이 쓸 로그 그룹 2개를 Terraform이 선점 생성(보존 기간 통제 목적), (4) 애드온 본체 설치. 이 파일이 만들어 내는 `/aws/containerinsights/<cluster>/application` 로그 그룹과 ContainerInsights 메트릭 네임스페이스가 이후 application-security-monitoring.tf의 metric filter, log-archive-subscriptions.tf의 구독필터, Grafana 대시보드 전부의 데이터 원천이 된다.

### L5–21 · module "cloudwatch_observability_pod_identity"

커뮤니티 모듈 `terraform-aws-modules/eks-pod-identity/aws`(`version = "~> 2.0"`, 주석에 v8 시점 버전 핀이라고 명시)로 CloudWatch 에이전트용 Pod Identity 역할을 만든다. `name = "gochuchamchi-cloudwatch-observability"`은 IAM 역할 이름이 된다. 핵심 인자는 `attach_aws_cloudwatch_observability_policy = true` — 모듈이 AWS 관리형 정책 `CloudWatchAgentServerPolicy`를 붙여서 메트릭 PutMetricData·로그 PutLogEvents 권한을 부여한다. `associations` 블록은 이 역할을 어느 파드에 연결할지 정의한다: `cluster_name = module.eks.cluster_name`(루트의 EKS 모듈 출력 참조), namespace `amazon-cloudwatch`, service_account `cloudwatch-agent`. 이 namespace/SA 이름은 애드온이 설치하는 에이전트 데몬셋의 고정 이름이므로 임의로 바꾸면 자격증명 연결이 끊긴다. IRSA가 아니라 Pod Identity를 쓴 것은 OIDC 프로바이더·조건 키 없이 클러스터명+네임스페이스+SA 3튜플로 연결이 끝나는 신형 방식이기 때문이다.

### L28–32 · data "aws_eks_addon_version" "cloudwatch_observability"

`addon_name = "amazon-cloudwatch-observability"`, `kubernetes_version = module.eks.cluster_version`, `most_recent = true`로 "현재 클러스터 K8s 버전과 호환되는 가장 최신 애드온 버전"을 조회한다. 버전을 하드코딩하면 K8s 업그레이드 때마다 수동으로 따라가야 하고, 생략하면 default 버전(최신이 아닐 수 있음)이 잡히므로, 매일 새로 apply되는 이 루트의 특성상 조회식이 가장 관리 비용이 낮다. 단, `most_recent = true`는 애드온 신버전이 나오면 다음 daily-up 때 자동으로 버전이 올라간다는 뜻이기도 하다 — 재현성보다 최신성을 택한 트레이드오프다.

### L39–50 · resource "aws_cloudwatch_log_group" "container_insights_application"

`/aws/containerinsights/${module.eks.cluster_name}/application` 로그 그룹을 Terraform이 **애드온보다 먼저** 만든다. 애드온(Fluent Bit)이 이 이름의 로그 그룹을 자동 생성하게 놔두면 보존 기간이 "만료 없음"이 되고 Terraform 관리 밖이 된다. 선점 생성하면 `retention_in_days = var.container_insights_log_retention_days`로 보존 기간을 변수로 통제하고, daily-down 때 로그 그룹도 함께 정리된다. 태그의 `LogCategory = "application"`은 로그 분류용 메타데이터다. 이 로그 그룹 리소스는 이 문서의 다른 두 파일이 직접 참조한다 — application-security-monitoring.tf의 metric filter(`log_group_name`)와 log-archive-subscriptions.tf의 구독필터(`application` 키의 값).

### L56–67 · resource "aws_cloudwatch_log_group" "container_insights_performance"

같은 패턴으로 `/aws/containerinsights/<cluster>/performance` 로그 그룹을 선점 생성한다. 이곳에는 Container Insights가 메트릭의 원본이 되는 성능 로그(EMF 형식 performance log events)를 쓴다. ContainerInsights 네임스페이스의 메트릭은 사실 이 로그에서 추출되는 것이므로, 이 로그 그룹이 있어야 Grafana의 EKS Health 대시보드가 보는 메트릭이 만들어진다. `retention_in_days`는 application과 같은 변수를 공유한다 — 두 로그의 보존 정책을 따로 가져갈 이유가 없다는 판단이다.

### L73–110 · resource "aws_eks_addon" "cloudwatch_observability"

애드온 본체다. `cluster_name`·`addon_name`은 자명하고, `addon_version`은 위 data source의 조회 결과를 넣는다. 핵심은 `configuration_values`의 jsonencode 블록이다:

- `containerInsights.enabled = true` — 주석 그대로 "Grafana 대시보드가 사용하는 기존 ContainerInsights 메트릭 생성". Classic Container Insights 메트릭(`node_cpu_utilization`, `pod_status_pending` 등)을 켠다.
- `otelContainerInsights.enabled = false` — OpenTelemetry 형식으로 메트릭을 이중 발행하는 신기능을 끈다. 주석이 이유를 명시한다: 현재 Grafana 대시보드가 Classic 메트릭과 `kubernetes.*` 로그 필드(Fluent Bit이 붙이는 메타데이터, dashboard.tf의 `kubernetes.pod_name` 쿼리가 사용)를 전제로 만들어져 있어서, OTel을 켜면 메트릭 이름·로그 스키마가 달라져 대시보드가 깨진다. 비용(이중 발행) 관점에서도 끄는 것이 맞다.
- `containerLogs.enabled = true` — Pod stdout/stderr 수집을 켠다. `includeNamespaces = ["gochuchamchi"]`가 주석 처리되어 있는데, 원래 의도는 애플리케이션 네임스페이스만 수집해 비용을 줄이는 것이었으나 현재는 전체 네임스페이스를 수집한다. 켜는 순간 시스템 파드 로그가 사라져 디버깅 시야가 좁아지는 트레이드오프가 있어 보류된 상태다.

`resolve_conflicts_on_create/update = "OVERWRITE"`는 애드온이 관리하는 K8s 리소스가 이미 존재하거나 수동 변경됐을 때 애드온 설정으로 덮어쓰겠다는 뜻이다 — 매일 재생성되는 환경에서 충돌로 apply가 멈추는 것보다 덮어쓰는 것이 낫다. `depends_on` 4개는 각각 의미가 있다: Pod Identity 모듈(에이전트가 뜨자마자 자격증명이 있어야 함), 로그 그룹 2개(애드온이 자동 생성해 버리기 전에 Terraform 소유로 선점), 그리고 `aws_route.private_subnet` — 프라이빗 서브넷 라우팅이 완성되기 전에 에이전트가 뜨면 CloudWatch 엔드포인트에 못 나가 CrashLoop에 빠지므로 네트워크 경로를 선행 조건으로 못박은 것이다.

## terraform/cloudwatch-managed-metrics.tf (143줄)

AWS 관리형 메트릭(ALB·RDS·ElastiCache)에 CloudWatch Alarm을 거는 모듈(`module/cloudwatch-managed-metrics`)의 호출부다. 이 파일의 대부분은 알람 자체가 아니라 **"Kubernetes Ingress가 비동기로 만든 ALB를 Terraform이 어떻게 찾아내는가"**라는 문제를 푸는 데 쓰인다. ALB는 aws-load-balancer-controller가 Ingress를 보고 나중에 만들기 때문에 Terraform 그래프에 리소스로 존재하지 않는다. 그래서 태그 API로 조회해 디멘션 값을 역산하는, 이 프로젝트에서 손꼽히게 영리한 배선이 들어 있다.

### L7–9 · locals { gochuchamchi_ingress_stack }

`gochuchamchi_ingress_stack = "gochuchamchi-web"`. Web과 Grafana Ingress가 명시적 IngressGroup(`alb.ingress.kubernetes.io/group.name = gochuchamchi-web`)을 쓰기 때문에, 컨트롤러가 ALB에 붙이는 `ingress.k8s.aws/stack` 태그 값이 group.name과 동일하다는 사실(주석에 명시)을 이용해 조회 키로 삼는다. IngressGroup 없이 단일 Ingress였다면 stack 태그가 `<namespace>/<ingress-name>` 형식이 되어 이 값도 달라졌을 것이다.

### L20–34 · data "aws_resourcegroupstaggingapi_resources" "gochuchamchi_alb"

ALB 조회의 핵심 트릭이다. 주석이 설계 이유를 정확히 설명한다: `data "aws_lb"`는 결과가 0개면 **에러**를 내므로, ALB가 아직 없는 최초 apply의 plan 단계에서 전체 apply가 죽는다. 반면 Resource Groups Tagging API는 결과가 없으면 **빈 리스트**를 돌려준다. 그래서 태그 API로 조회한다 — ALB가 없는 첫 apply에서는 ALB 알람만 조용히 건너뛰고, ALB가 생긴 다음 apply에서 자동으로 알람이 붙는 "자기 치유" 구조가 된다. `resource_type_filters = ["elasticloadbalancing:loadbalancer"]`로 로드밸런서만, `tag_filter` 2개로 (1) `elbv2.k8s.aws/cluster` = 우리 클러스터가 만든 것, (2) `ingress.k8s.aws/stack` = gochuchamchi-web 그룹의 것으로 좁힌다.

### L36–53 · locals { gochuchamchi_alb_arns, gochuchamchi_alb_arn, gochuchamchi_alb_arn_suffix }

태그 API 결과를 CloudWatch 디멘션 값으로 가공한다. (1) `gochuchamchi_alb_arns` — 태그 API의 `loadbalancer` 타입 필터는 NLB/GWLB도 포함하므로, ARN에 `loadbalancer/app/`이 들어간 것(ALB)만 `regexall`로 걸러낸다. (2) `gochuchamchi_alb_arn = try(local.gochuchamchi_alb_arns[0], null)` — 첫 번째 것을 취하되, 빈 리스트면 인덱스 에러 대신 `try`로 null을 얻는다. 이 null이 이후 모든 조건 분기의 스위치다. (3) `gochuchamchi_alb_arn_suffix` — CloudWatch의 `LoadBalancer` 디멘션은 전체 ARN이 아니라 `app/<name>/<id>` 형태의 suffix를 요구하므로, `regex("loadbalancer/(app/.+)$", ...)`의 캡처 그룹으로 잘라낸다. ALB가 없으면 null을 그대로 전파한다.

### L60–75 · data "aws_resourcegroupstaggingapi_resources" "gochuchamchi_target_groups"

같은 두 태그 필터로 이번에는 `elasticloadbalancing:targetgroup` 타입을 조회한다. 같은 IngressGroup이 만든 Target Group **후보** 목록이다. "후보"인 이유는 태그만으로는 현재 ALB에 실제 연결된 TG인지(과거 것의 잔재인지) 알 수 없기 때문이며, 그 검증은 아래 L96–110에서 한다.

### L82–89 · data "aws_lb_target_group" "gochuchamchi_candidates"

후보 ARN 각각을 `for_each = toset([...])`로 순회하며 TG 상세를 조회한다. 상세 조회가 필요한 이유는 단 하나 — data source가 돌려주는 `load_balancer_arns` 속성으로 "이 TG가 어느 ALB에 붙어 있는가"를 확인하기 위해서다. 태그 API의 목록만으로는 이 정보가 없다.

### L96–110 · locals { gochuchamchi_target_group_arn_suffixes }

ALB가 없으면(`gochuchamchi_alb_arn == null`) 빈 set, 있으면 후보 TG 중 `contains(target_group.load_balancer_arns, local.gochuchamchi_alb_arn)`으로 **현재 ALB에 실제 연결된 TG만** 남기고, `regex("targetgroup/.+$", ...)`로 CloudWatch `TargetGroup` 디멘션 형식(`targetgroup/<name>/<id>`)으로 잘라 set으로 만든다. 이렇게 하면 Ingress를 지웠다 다시 만들며 남은 고아 TG에 알람이 붙는 일을 막는다.

### L116–143 · module "cloudwatch_managed_metrics"

위에서 준비한 값들을 `./module/cloudwatch-managed-metrics`에 주입한다. 인자별로: `name_prefix = "gochuchamchi"` — **모든 알람 이름이 이 접두사로 시작하게 만드는, 알림 파이프라인 전체에서 가장 중요한 한 줄이다.** cloudwatch-notifications의 EventBridge 규칙이 이 접두사로 알람 이벤트를 매칭하기 때문이다. `rds_identifier = module.rds.db_instance_identifier` — RDS 모듈 출력을 그대로 연결. `redis_cluster_id = "${aws_elasticache_replication_group.this.id}-001"` — 2026-08-04에 단일 cache cluster에서 replication group으로 전환(redis.tf)하면서 바뀐 부분으로, CloudWatch의 `CacheClusterId` 디멘션은 RG ID가 아니라 멤버 캐시 클러스터 ID를 요구하는데 RG의 첫 멤버는 `<rg-id>-001` 규칙으로 명명되므로 문자열 조립으로 맞춘 것이다(주석에 날짜와 함께 기록). `redis_cache_node_id = "0001"`은 단일 노드의 고정 노드 ID다. `alb_arn_suffix`와 `alb_target_group_arn_suffixes`는 위 locals를 전달 — ALB가 없으면 null/빈 set이 넘어가 모듈이 ALB 알람 생성을 건너뛴다. `alarm_actions = []`는 주석("아직 SNS/Discord 통지 연결 안 함")만 보면 미완처럼 읽히지만, 실제로는 앞서 설명한 EventBridge 접두사 매칭 구조가 통보를 대신하므로 비워두는 것이 맞다 — 여기에 SNS ARN을 넣으면 오히려 이중 통보가 된다.

## terraform/grafana.tf (61줄)

Grafana 모듈 호출부와 루트 출력이다. 모듈에 "무엇을, 어디에, 어떤 도메인으로" 설치할지만 넘기고 실제 설치 로직은 전부 `module/grafana`에 있다.

### L5–40 · module "grafana"

인자별로 본다. `cluster_name = module.eks.cluster_name`·`region = var.region` — Pod Identity 연결과 CloudWatch 데이터소스 리전 설정에 쓰인다. `namespace = "monitoring"`·`service_account_name = "grafana"` — 모듈이 만들 K8s 네임스페이스·SA 이름. `grafana_hostname = "grafana.${var.domain_name}"` — external-dns가 등록할 접속 도메인. `storage_class_name = "ebs-sc"`·`storage_size = "5Gi"` — PVC 설정값인데, 모듈 쪽에서 persistence가 현재 꺼져 있어(후술) 지금은 휴면 인자다. `rds_identifier = module.rds.db_instance_identifier` — AWS Errors 대시보드가 RDS error 로그 그룹 이름을 조립하는 데 쓴다. `alb_group_name = "gochuchamchi-web"` — 주석 그대로 "기존 웹 Ingress와 같은 ALB 사용": 별도 ALB를 만들지 않고 IngressGroup 병합으로 비용을 아낀다(이 값이 cloudwatch-managed-metrics.tf의 stack 태그 조회와 같은 그룹명이라는 점이 두 파일을 잇는 고리다). `certificate_arn = aws_acm_certificate_validation.this.certificate_arn` — 인증서 리소스가 아니라 **validation 리소스**의 출력을 넘겨서 "DNS 검증까지 완료된" 인증서만 ALB 리스너에 붙게 한다(검증 전 인증서를 붙이면 리스너 생성 실패). `tags`는 공통 태그. `depends_on` 5개는 Grafana가 뜨기 위한 실질 전제들이다: EKS 클러스터, CloudWatch 애드온(대시보드가 볼 메트릭·로그의 생산자), 인증서 검증 완료, aws-load-balancer-controller(Ingress→ALB 실체화 주체), external-dns(도메인 등록 주체).

### L47–50 · output "grafana_url"

모듈의 `url` 출력(`https://grafana.<domain>`)을 루트로 재노출한다. description에 "계정: admin"을 적어 접속 계정 정보를 함께 전달한다.

### L52–56 · (주석) grafana_admin_password output 제거 이력

코드가 아니라 주석이지만 보안상 중요한 기록이다. 2026-08-04 보안 리뷰 §3-② 조치로 admin 비밀번호 output을 제거했다 — data source → output 경유로 비밀번호가 **tfstate에 평문 저장**되던 문제 때문이다. `sensitive = true`는 CLI 출력만 가릴 뿐 state 파일에는 평문으로 남는다는 것이 핵심 교훈이다. 대신 필요할 때 클러스터에서 직접 조회하는 PowerShell 명령을 주석에 남겼다(`base64` 명령이 없는 PowerShell 5.1 환경이라 `[System.Convert]::FromBase64String` 방식 — bash식 `| base64 -d`는 실패한다는 환경 특이사항까지 기록).

### L58–61 · output "grafana_iam_role_arn"

모듈의 `iam_role_arn`(CloudWatch 조회용 Pod Identity 역할 ARN)을 재노출한다. 권한 검증·디버깅 시 역할을 바로 찾기 위한 편의 출력이다.

## terraform/application-security-monitoring.tf (175줄)

애플리케이션 계층 보안 탐지다. Spring 애플리케이션이 한 줄 JSON으로 보안/접근 이벤트를 남기면, Container Insights 애플리케이션 로그 그룹에 metric filter를 걸어 커스텀 메트릭으로 바꾸고, 그 메트릭에 알람을 건다. 파일 상단 영문 주석이 두 가지 설계 결정을 못박는다: (1) 애드온의 기본 파서는 JSON을 `log_processed` 아래에 중첩시키고, 커스텀 수집기는 루트에 그대로 둘 수 있으므로 **두 형태 모두에 필터를 하나씩 유지**한다 — 애드온 설정이 바뀌어도 탐지가 조용히 죽지 않게. (2) 알람 상태 변화는 cloudwatch-notifications의 `gochuchamchi-` 접두사 EventBridge 규칙이 잡으므로 alarm_actions를 여기서 중복 지정하지 않는다.

### L15–88 · locals { application_security_metric_namespace, application_security_metric_filters, application_security_alarms }

세 덩어리다. **`application_security_metric_namespace = "Gochuchamchi/ApplicationSecurity"`** — 커스텀 메트릭 네임스페이스. AWS 예약 접두사(`AWS/`)와 충돌하지 않는 프로젝트 네임스페이스다.

**`application_security_metric_filters`** — 필터 10개(5종 × merged/root 2형태). 각 항목은 CloudWatch Logs filter pattern 문법의 JSON 필드 매칭이다:
- `http-4xx-merged`/`http-4xx-root`: `eventCategory = "HTTP_ACCESS"`이고 `statusCode`가 400 이상 500 미만 → `Http4xxCount`. merged형은 모든 필드 앞에 `$.log_processed.`가 붙고 root형은 `$.` 바로 아래를 본다는 것만 다르다.
- `http-5xx-merged`/`root`: statusCode 500–599 → `Http5xxCount`.
- `login-failure-merged`/`root`: `eventCategory = "SECURITY_EVENT" && eventType = "LOGIN" && outcome = "FAILURE"` → `LoginFailureCount`. 로그인 성공은 세지 않는다 — 실패만이 신호다.
- `access-denied-merged`/`root`: `SECURITY_EVENT`이고 `eventType`이 `ACCESS_DENIED` 또는 `ACCESS_BLOCKED`(괄호 OR) → `AccessDeniedCount`.
- `high-security-event-merged`/`root`: `SECURITY_EVENT`이고 `severity`가 `HIGH` 또는 `CRITICAL` → `HighSecurityEventCount`.

같은 `metric_name`을 merged/root 두 필터가 공유하므로, 로그가 어느 형태로 들어오든 **같은 메트릭이 증가**한다. 알람은 메트릭만 보면 되니 필터 형태 변화에 면역이 된다 — 이 파일의 가장 좋은 설계 포인트다.

**`application_security_alarms`** — 알람 5개 정의. 4xx/5xx/login-failure/access-denied는 임계값을 변수로 빼고, high-security-event만 `threshold = 1` 하드코딩이다 — HIGH/CRITICAL 이벤트는 단 1건도 즉시 알아야 한다는 의도로, 조정 가능한 값이 아니라 원칙이기 때문에 변수화하지 않았다. description들은 알람 수신자가 바로 취할 행동(확인할 로그·필드)을 한국어로 안내한다 — Discord로 전달됐을 때 그 자체가 초동 대응 runbook이 되도록.

### L90–103 · resource "aws_cloudwatch_log_metric_filter" "application_security"

`for_each`로 필터 10개를 생성한다. `name = "gochuchamchi-app-${each.key}"`, `log_group_name`은 cloudwatch-observability.tf의 application 로그 그룹 리소스를 직접 참조한다(문자열이 아닌 리소스 참조라 로그 그룹 생성이 자동으로 선행된다). `metric_transformation`은 매칭 1건당 `value = "1"`을 해당 메트릭에 더한다(`unit = "Count"`). 즉 "필터에 걸린 로그 줄 수 = 메트릭 값"이라는 가장 단순한 변환이다.

### L105–131 · resource "aws_cloudwatch_metric_alarm" "application_security"

`for_each`로 알람 5개를 생성한다. `alarm_name = "gochuchamchi-app-${each.key}"` — 접두사 `gochuchamchi-`를 지키므로 EventBridge 매칭에 걸린다. 메트릭 설정: `namespace`는 위 커스텀 네임스페이스, `statistic = "Sum"`(기간 내 발생 건수 합), `period = 300`(5분 창), `evaluation_periods = 1`·`datapoints_to_alarm = 1`(5분 창 하나만 초과해도 즉시 ALARM — 보안 이벤트는 지속성 확인보다 신속성이 우선), `comparison_operator = "GreaterThanOrEqualToThreshold"`(임계값 "이상"), `treat_missing_data = "notBreaching"` — **커스텀 메트릭은 필터에 걸리는 로그가 없으면 데이터포인트 자체가 안 생기므로**, missing을 정상(OK)으로 취급해야 조용한 시간대에 INSUFFICIENT_DATA로 알람이 오염되지 않는다. alarm_actions는 의도적으로 없다(파일 상단 주석). `depends_on`으로 필터 생성을 명시적으로 선행시킨다 — 알람이 참조하는 것은 메트릭 "이름"뿐이라 Terraform이 의존을 추론하지 못하기 때문이다.

### L133–142 · variable "application_http_4xx_alarm_threshold"

기본값 20(5분당 4xx 20건). 4xx는 정상 트래픽에도 섞이므로(404, 잘못된 요청 등) 가장 높은 임계값을 준다. `validation`으로 1 이상을 강제 — 0이면 `GreaterThanOrEqualToThreshold` 조건상 항상 ALARM이 되는 실수를 입력 단계에서 차단한다.

### L144–153 · variable "application_http_5xx_alarm_threshold"

기본값 5. 5xx는 서버 결함이므로 4xx보다 훨씬 민감하게 잡는다. 같은 validation.

### L155–164 · variable "application_login_failure_alarm_threshold"

기본값 5(5분당 로그인 실패 5회). 정상 사용자의 오타 몇 번은 통과시키고 무차별 대입 시도는 걸리는 수준의 절충값이다. 같은 validation.

### L166–175 · variable "application_access_denied_alarm_threshold"

기본값 5. 권한 거부 반복 — 정상 사용자 오동작인지 권한 우회 시도인지 확인이 필요한 수준. 같은 validation. high-security-event의 임계값만 변수가 없다는 비대칭이 의도임을 다시 짚어 둔다.

## terraform/iam-activity-monitoring.tf (111줄)

루트 계정 사용·IAM 변경 API·콘솔 로그인 실패를 탐지하는 파일이다(2026-08-12 추가). 파일 상단의 긴 한국어 주석이 설계 결정 네 가지를 조목조목 기록하고 있고, 이는 발표·면접에서 그대로 쓸 수 있는 논리다.

**왜 metric filter가 아니라 EventBridge인가** — 교과서 방식은 CloudTrail → CloudWatch Logs → metric filter → alarm(CIS 벤치마크 방식)이다. 하지만 이 계정의 CloudTrail(gochuchamchi-org-trail)은 Management 계정 소유의 org trail이고 S3로만 가며 CloudWatch Logs로는 보내지 않는다(`CloudWatchLogsLogGroupArn=None`). 그 경로를 켜려면 Workload 계정이 아닌 Management의 trail을 건드려야 한다. 반면 EventBridge는 **트레일 설정과 무관하게** CloudTrail 관리 이벤트를 자동 수신한다. 로그 그룹도 filter도 필요 없고 비용도 사실상 0이다.

**왜 us-east-1인가** — IAM과 콘솔 로그인은 "글로벌 서비스" 이벤트라 CloudTrail이 us-east-1에만 기록한다. 따라서 EventBridge 규칙도 us-east-1에 있어야 한다. 서울에 두면 문법상 완벽해도 IAM 이벤트가 영원히 안 들어온다 — 주석이 "대표적 함정, CIS 벤치마크 알람이 전부 us-east-1인 이유"라고 명시한 부분이다.

**서울로 어떻게 보내나** — edge-logs.tf의 WAF 알람 포워더와 같은 패턴으로, us-east-1 규칙이 잡은 이벤트를 서울 default 이벤트 버스로 relay하면 cloudwatch-notifications 루트의 서울 규칙이 받아 SNS(gochuchamchi-alerts)로 발행한다. relay 시 source/detail-type/detail이 보존되므로 서울 쪽 매칭 패턴을 그대로 쓸 수 있다.

**무엇을 잡나** — 멘토가 지적했던 GuardDuty 오탐 문제를 의식해 노이즈를 최소화했다: 조회(Get/List/Describe)와 성공 로그인은 아예 매칭하지 않는다.

### L31–40 · data "aws_iam_policy_document" "iam_activity_forwarder_assume"

EventBridge 서비스(`events.amazonaws.com`)가 맡을 수 있는 신뢰 정책이다. EventBridge 타깃이 "다른 이벤트 버스"일 때는 규칙이 IAM 역할을 맡아 대상 버스에 PutEvents 해야 하므로 이 역할이 필요하다.

### L42–46 · resource "aws_iam_role" "iam_activity_forwarder"

이름 `gochuchamchi-iam-activity-forwarder`로 위 신뢰 정책을 가진 역할을 만든다. IAM은 글로벌이므로 이 역할 자체는 리전 무관하게 us-east-1 규칙에서 쓸 수 있다.

### L48–54 · data "aws_iam_policy_document" "iam_activity_forwarder"

권한 정책: `events:PutEvents`를 **서울 리전 default 버스 하나로만** 허용한다. resource ARN을 `arn:aws:events:${var.region}:${data.aws_caller_identity.edge_current.account_id}:event-bus/default`로 조립 — `edge_current`는 us-east-1 프로바이더 쪽 caller identity data source(edge-logs.tf 계열에서 정의)로, 같은 계정이지만 프로바이더 별칭 체계를 따라 참조한 것이다. 최소 권한: 이 역할로는 다른 버스에 아무것도 못 보낸다.

### L56–60 · resource "aws_iam_role_policy" "iam_activity_forwarder"

위 정책 문서를 역할에 inline policy로 부착한다. 이 용도로만 쓰는 1:1 정책이라 관리형 정책으로 분리할 이유가 없다.

### L63–95 · resource "aws_cloudwatch_event_rule" "iam_activity"

`provider = aws.us_east_1` — 이 파일의 존재 이유가 이 한 줄에 있다(글로벌 서비스 이벤트는 us-east-1에만 온다). `event_pattern`은 `detail-type`이 "AWS API Call via CloudTrail" 또는 "AWS Console Sign In via CloudTrail"인 이벤트 중, detail에서 `$or`로 묶은 세 조건 중 하나라도 참이면 매칭한다(주석: EventBridge는 배열 요소 간에는 OR이지만, 서로 다른 필드 조합의 OR은 `$or` 연산자가 필요):

- **(a) `userIdentity.type = ["Root"]`** — 루트 계정의 **모든** 행위. 정상 운영에서 루트는 안 쓰므로 쓰였다는 사실 자체가 이상 신호다.
- **(b) `eventSource = ["iam.amazonaws.com"]` + `eventName` prefix 10종** — `Create/Delete/Update/Put/Attach/Detach/Add/Remove/Tag/Untag`로 시작하는 IAM API. 사용자·역할·정책·액세스키의 생성/삭제/수정/연결/해제를 전부 덮으면서 Get/List/Describe 조회는 접두사에 안 걸려 자연히 제외된다 — 이벤트명 열거 대신 prefix 매칭으로 미래의 신규 API까지 커버하는 방식이다.
- **(c) `signin.amazonaws.com`의 `ConsoleLogin` 중 `responseElements.ConsoleLogin = ["Failure"]`** — 콘솔 로그인 실패만(무차별 대입 정찰 신호). 성공 로그인은 매칭하지 않는다.

### L97–104 · resource "aws_cloudwatch_event_target" "iam_activity_to_seoul"

us-east-1 규칙의 타깃으로 서울 default 이벤트 버스 ARN을 지정하고, `role_arn`으로 위 forwarder 역할을 붙인다. `target_id = "ForwardIamActivityToSeoul"`은 규칙 내 타깃 식별자다. 이후의 배선(서울 버스 → SNS)은 cloudwatch-notifications 루트의 몫이므로 여기서 끝난다 — 루트 간 결합을 이벤트 버스라는 경계면으로 끊은 구조다.

### L106–111 · output "iam_activity_rule_arn"

us-east-1 규칙의 ARN을 출력한다. 주석 그대로 "서울 수신 규칙과 무관하게, us-east-1 규칙이 실제로 생성됐는지 확인용" — 리전을 넘나드는 배선은 눈으로 검증하기 어려우므로 검증 스크립트·수동 확인의 앵커를 남긴 것이다.

## terraform/log-archive-subscriptions.tf (73줄)

CloudWatch Logs 구독필터로 Workload 계정의 로그를 Log 계정의 크로스계정 Destination(그 뒤는 Firehose→S3)으로 실시간 전송하는 배선이다. 파일 주석이 이력을 압축한다: 8/7에 Firehose 수신부를 account-baseline으로 뺐고, 8/10에 그 수신부 전체가 별도 Log 계정(../log-archive)으로 갔다. 이 파일에 남은 것은 "EKS 쪽 로그 그룹을 수신부에 붙이는 배선"뿐이며, 이는 클러스터와 생명주기가 같으므로 런타임 루트에 있는 것이 맞다. 크로스계정이라 두 가지가 달라졌다: (1) Firehose ARN이 아니라 **Log Destination ARN**을 가리킨다 — 구독필터는 타 계정 Firehose를 직접 지정할 수 없다. (2) `role_arn`이 없다 — 인가는 수신측 destination policy가, Firehose 투입 권한은 수신측 destination의 role이 갖는다. 또 참조는 data source가 아니라 **ARN 문자열 조립**이다 — 크로스계정 data source는 Log 계정 자격증명이 필요해서 kim/moon의 DenySensitiveServices 권한 경계에 걸리기 때문이다. 대신 destination 이름 규칙이 ../log-archive/log-archive.tf와 반드시 일치해야 한다는 암묵 계약이 생긴다.

### L19–35 · locals { cloudwatch_log_archive_sources }

전송할 로그 그룹의 맵이다. **키는 ../log-archive/log-archive.tf의 `cloudwatch_log_archive_sources`와 반드시 일치해야 한다**(주석 명시) — 키가 destination 이름(`gochuchamchi-<key>-log-archive`)의 일부가 되기 때문이다. 세 항목:
- `application` — cloudwatch-observability.tf의 application 로그 그룹(리소스 참조).
- `control-plane` — EKS 모듈이 만든 컨트롤플레인 로그 그룹(모듈 출력 참조).
- `rds-audit` — 2026-08-12 추가. 주석이 목적을 명확히 한다: rds.tf에서 MariaDB audit plugin을 `QUERY_DML_NO_SELECT`까지 켠 뒤, "누가 들어와 무엇을 실행했나"의 증적을 workload 계정에만 두지 않고 **다른 계정이 변조·삭제할 수 없는 불변 중앙 버킷(Log 계정)으로** 보낸다 — 침해된 계정이 자기 흔적을 못 지우게 하는 제로트러스트 감사의 핵심. 이 로그 그룹(`/aws/rds/instance/<id>/audit`)은 AWS(RDS)가 만드는 것이라 Terraform 리소스 참조가 불가능해 `data.aws_db_instance.this`(루트의 다른 파일에 정의)의 식별자로 이름을 조립한다. 그리고 순서 제약: 수신 Destination(`gochuchamchi-rds-audit-log-archive`)이 Log 계정에서 **먼저 apply**돼 있어야 한다 — ../log-archive에 "rds-audit" 키를 추가하는 짝 커밋이 선행돼야 여기 구독필터 생성이 성공한다.

### L37–53 · resource "aws_cloudwatch_log_subscription_filter" "cloudwatch_log_archive"

`for_each`로 위 맵의 구독필터 3개를 만든다. `name = "gochuchamchi-${each.key}-s3-archive"`, `filter_pattern = ""`(빈 패턴 = 전체 로그 무필터 전송 — 아카이브 목적이므로 선별하지 않는다), `destination_arn`은 `arn:aws:logs:<region>:<log_archive_account_id>:destination:gochuchamchi-<key>-log-archive`로 조립한다. `depends_on = [aws_eks_addon.cloudwatch_observability]` — application 로그 그룹은 리소스 참조로 자동 순서가 잡히지만, 애드온이 실제 로그를 흘리기 시작하는 시점까지 포괄하려는 보수적 의존이다. `lifecycle.precondition`은 `var.log_archive_account_id != ""`를 검사해, Log 계정이 아직 없거나 변수 미설정 상태로 apply하면 조립된 ARN이 엉뚱해지기 전에 **plan 단계에서** 한국어 에러 메시지("../log-archive 먼저 apply")로 실패시킨다 — 순서 제약을 문서가 아니라 코드로 강제한 좋은 예다.

### L57–73 · resource "aws_cloudwatch_log_subscription_filter" "waf_log_archive"

CloudFront 범위 WAF 로그 그룹(`aws_cloudwatch_log_group.waf`, edge-logs.tf에 정의)은 us-east-1에 있으므로 `provider = aws.us_east_1`로 분리된 별도 리소스가 필요하다(구독필터는 로그 그룹과 같은 리전이어야 한다). destination ARN도 `arn:aws:logs:us-east-1:...`로 리전만 다르고 구조는 같다 — 즉 Log 계정 쪽에도 us-east-1 destination이 따로 apply돼 있어야 한다. `depends_on = [aws_wafv2_web_acl_logging_configuration.edge]` — WAF 로깅 설정이 로그 그룹에 실제 스트림을 만들기 시작한 뒤에 구독을 붙인다. 같은 precondition으로 계정 ID 미설정을 차단한다.

## terraform/module/cloudwatch-managed-metrics/main.tf (221줄)

AWS 관리형 메트릭 알람 7종(ALB 3, RDS 2, Redis 2)을 만드는 모듈 본체다. 공통 골격: 모든 알람 이름은 `${var.name_prefix}-...`로 시작하고(루트가 "gochuchamchi"를 넣으므로 EventBridge 접두사 매칭 충족), `alarm_actions`/`ok_actions`에는 `var.alarm_actions`(현재 빈 리스트)를 넣는다. ALB 알람은 `for_each = local.alb_target_groups`(TG별 생성), RDS/Redis 알람은 `count = local.enable_* ? 1 : 0`(입력이 null이면 생성 생략) 패턴으로 조건부 생성을 구현한다.

### L1–11 · locals { alb_target_groups, enable_rds, enable_redis }

`alb_target_groups`는 `var.alb_arn_suffix == null`이면 빈 맵(→ ALB 알람 for_each가 0개), 아니면 TG ARN suffix(`targetgroup/<name>/<id>`)를 키로, `split("/", suffix)[1]`로 뽑은 **TG 이름**을 값으로 하는 맵이다 — 키는 CloudWatch 디멘션에, 값은 사람이 읽는 알람 이름에 쓰인다. `enable_rds = var.rds_identifier != null`, `enable_redis = var.redis_cluster_id != null` — "입력을 안 주면 그 알람군은 안 만든다"는 모듈의 선택적 활성화 스위치다.

### L17–44 · resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_host"

TG별 비정상 Target 감시. `alarm_name = "<prefix>-alb-<tg이름>-unhealthy-host"`. 메트릭은 `AWS/ApplicationELB`의 `UnHealthyHostCount`, 디멘션은 `LoadBalancer = var.alb_arn_suffix` + `TargetGroup = each.key`(이 메트릭은 두 디멘션 조합이 필수다). `statistic = "Maximum"` — 기간 내 순간이라도 비정상이 있었는지를 본다(Average는 짧은 장애를 희석한다). `period = 60`·`evaluation_periods = 2`·`datapoints_to_alarm = 2` — 1분 창 2번 연속 위반이어야 ALARM: 롤링 재시작 중 헬스체크가 잠깐 빠지는 1분짜리 순간 노이즈는 거르고 2분 이상 지속되는 실제 장애만 잡는다. `comparison_operator = "GreaterThanOrEqualToThreshold"` + `threshold = 1` — 비정상 1대부터 즉시 이상. `treat_missing_data = "notBreaching"` — 주석 그대로 "메트릭이 없을 때는 장애로 판단하지 않음": daily-down 이후나 ALB 생성 직전의 데이터 공백을 OK로 취급한다.

### L47–72 · resource "aws_cloudwatch_metric_alarm" "alb_target_5xx"

Spring Target이 반환한 5xx 감시. 메트릭 `HTTPCode_Target_5XX_Count`(ALB 자체가 아니라 **백엔드가 돌려준** 5xx — ALB 자체 5xx는 `HTTPCode_ELB_5XX_Count`로 별개이며 대시보드에서 구분해 본다). `statistic = "Sum"`·`period = 300`·`evaluation_periods = 1`·`datapoints_to_alarm = 1` — 5분간 합계가 한 번이라도 임계에 닿으면 즉시 ALARM. `threshold = 5`(하드코딩) — 5분에 5xx 5건이면 산발적 오류를 넘어선 수준이라는 판단. `treat_missing_data = "notBreaching"` — 5xx가 하나도 없으면 이 메트릭은 데이터포인트 자체가 없으므로 missing=정상이 필수다.

### L79–104 · resource "aws_cloudwatch_metric_alarm" "rds_cpu_high"

`count = local.enable_rds ? 1 : 0`. 메트릭 `AWS/RDS`의 `CPUUtilization`, 디멘션 `DBInstanceIdentifier = var.rds_identifier`. `statistic = "Average"`·`period = 300`·`evaluation_periods = 3`·`datapoints_to_alarm = 3` — 5분 평균이 3회 연속(15분) 임계 이상이어야 ALARM: CPU는 스파이크가 정상이므로 "지속되는 고부하"만 잡는다. `threshold = var.rds_cpu_threshold`(기본 80%). `treat_missing_data = "missing"` — 인프라 상시 메트릭인 CPU가 안 들어온다는 것 자체가 이상 신호일 수 있으므로 notBreaching으로 뭉개지 않고 INSUFFICIENT_DATA로 드러나게 둔다. 앞의 이벤트성 메트릭(5xx 등)과 결정이 다른 이유가 면접 포인트다: **항상 존재해야 하는 메트릭은 missing, 이벤트가 있을 때만 생기는 메트릭은 notBreaching.**

### L107–132 · resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low"

메트릭 `FreeStorageSpace`. `statistic = "Minimum"` — 기간 내 최저 여유 공간 기준(가장 보수적). `period = 300`·`evaluation_periods = 2`·`datapoints_to_alarm = 2`(10분 지속 확인). `comparison_operator = "LessThanOrEqualToThreshold"` — 이 모듈에서 유일한 "이하" 방향 알람이다. `threshold = var.rds_free_storage_threshold_bytes`(기본 5 GiB). 디스크 고갈은 RDS가 스토리지 풀 상태로 멈추는 최악의 장애라 미리 여유를 두고 잡는다. `treat_missing_data = "missing"` — CPU와 같은 논리.

### L139–165 · resource "aws_cloudwatch_metric_alarm" "redis_memory_high"

`count = local.enable_redis ? 1 : 0`. 메트릭 `AWS/ElastiCache`의 `DatabaseMemoryUsagePercentage`, 디멘션 `CacheClusterId = var.redis_cluster_id`(루트가 `<rg-id>-001`을 넣는 이유는 루트 해설 참조) + `CacheNodeId = var.redis_cache_node_id`. `statistic = "Average"`·`period = 300`·평가 3/3(15분 지속)·`threshold = var.redis_memory_threshold`(기본 80%)·`treat_missing_data = "missing"`. RDS CPU 알람과 완전히 같은 프로파일 — "지속형 자원 포화" 계열로 일관되게 설계했다.

### L168–194 · resource "aws_cloudwatch_metric_alarm" "redis_evictions"

메트릭 `Evictions`(메모리 부족으로 키가 제거된 횟수). `statistic = "Sum"`·`period = 300`·평가 1/1. `comparison_operator = "GreaterThanThreshold"` + `threshold = 0` — 이 모듈에서 유일한 "초과" 연산자로, "eviction은 0이 정상, 1건이라도 있으면 이상"을 표현한다(≥1과 수학적으로 같지만 "0이어야 한다"는 의도가 더 직접 드러난다). `treat_missing_data = "notBreaching"` — eviction이 없으면 0이 아니라 데이터 없음일 수 있어서다. maxmemory-policy에 따라 메모리 80% 도달 전에 eviction이 시작될 수 있으므로 memory_high보다 먼저 울릴 수 있는 실질적 조기 경보다.

### L197–221 · resource "aws_cloudwatch_metric_alarm" "alb_target_4xx"

파일 말미에 나중에 추가된 알람(주석: 인증 실패·권한 거부·스캐닝 증가를 포함한 Target 4xx 급증 확인). 메트릭 `HTTPCode_Target_4XX_Count`, TG별 for_each, `statistic = "Sum"`·`period = 300`·평가 1/1·`threshold = var.alb_target_4xx_threshold`(기본 20)·`treat_missing_data = "notBreaching"`. description이 초동 대응 안내(상태 코드·IP·URI 확인)를 담는다. application-security-monitoring.tf의 Http4xxCount 알람과 겹쳐 보이지만 관측 지점이 다르다: 이쪽은 **ALB가 본** 4xx(앱 로그가 안 남는 요청 포함), 저쪽은 **앱이 기록한** 4xx다. 두 층이 어긋나면(예: ALB만 4xx 급증) 앱 도달 전 구간의 문제라는 진단 정보가 된다.

## terraform/module/cloudwatch-managed-metrics/variables.tf (88줄)

모듈 입력 11개. 자원 식별자들은 default가 null이라 루트가 필요한 축만 활성화할 수 있는 구조다.

### L1–5 · variable "name_prefix"

알람 이름 접두사. `default = "gochuchamchi"`. 기본값이 있어도 루트가 명시적으로 넣고 있다 — 이 값이 알림 파이프라인의 매칭 키이므로 암묵 기본값에 기대지 않는 것이 옳다.

### L11–15 · variable "alb_arn_suffix"

`type = string`, `default = null`. null이면 locals에서 alb_target_groups가 빈 맵이 되어 ALB 알람 전체가 생략된다. description에 값 형식 예시(`app/web-alb/1234567890abcdef`)를 남겨 디멘션 형식 실수를 예방한다.

### L17–21 · variable "alb_target_group_arn_suffixes"

`type = set(string)`, `default = []`. set인 이유: for_each에 바로 쓰이고, 순서가 무의미하며 중복이 없어야 하기 때문이다. 루트에서 toset으로 만든 값이 그대로 들어온다.

### L27–31 · variable "rds_identifier"

`default = null` — null이면 RDS 알람 2종 생략. 루트는 `module.rds.db_instance_identifier`를 넣는다.

### L37–41 · variable "redis_cluster_id"

`default = null` — null이면 Redis 알람 2종 생략. 루트는 RG 멤버 클러스터 ID(`<rg-id>-001`)를 넣는다.

### L43–47 · variable "redis_cache_node_id"

`default = "0001"`. 단일 노드 캐시 클러스터의 노드 ID는 항상 "0001"이므로 기본값으로 충분하지만 루트는 명시적으로도 넣고 있다.

### L54–58 · variable "alarm_actions"

`type = list(string)`, `default = []`. 주석("나중에 SNS Topic ARN을 넣을 수 있습니다")은 모듈의 확장 여지를 남긴 것이고, 실제 아키텍처에서는 EventBridge 접두사 매칭이 통보를 담당하므로 빈 리스트가 최종 상태다.

### L64–68 · variable "rds_cpu_threshold"

`default = 80`(%). RDS CPU 지속 80%는 스케일업 검토 신호라는 일반적 기준값.

### L70–76 · variable "rds_free_storage_threshold_bytes"

`default = 5368709120`(주석: 5 GiB). 바이트 단위인 이유는 FreeStorageSpace 메트릭의 단위가 Bytes이기 때문 — %가 아니어서 인스턴스 스토리지 크기가 바뀌면 실질 의미가 달라진다는 점은 알아둘 만하다.

### L78–82 · variable "redis_memory_threshold"

`default = 80`(%). DatabaseMemoryUsagePercentage 기준.

### L84–88 · variable "alb_target_4xx_threshold"

`default = 20`(5분당). 애플리케이션 계층 4xx 임계값(application-security-monitoring.tf의 4xx 기본값)과 같은 20으로 맞춰 두 층의 감도를 일치시켰다.

## terraform/module/cloudwatch-managed-metrics/outputs.tf (37줄)

생성된 알람 이름 목록을 자원군별로 노출한다. 조건부 생성(for_each/count)이라 "실제로 뭐가 만들어졌는지"가 apply 전에는 불확실하므로, 검증 스크립트나 운영자가 결과를 확인하는 통로다.

### L1–21 · output "alb_alarm_names"

for_each 리소스 3종(alb_unhealthy_host, alb_target_5xx, alb_target_4xx)의 인스턴스들을 `values(...)`로 꺼내 alarm_name을 뽑고 concat으로 합친다. ALB가 없던 apply에서는 빈 리스트가 된다.

### L23–29 · output "rds_alarm_names"

count 리소스라 splat(`[*]`)으로 alarm_name을 뽑아 concat한다. enable_rds가 false면 빈 리스트. for_each는 values(), count는 [*] — 두 문법 차이가 outputs 파일 안에 나란히 있어 좋은 학습 예시다.

### L31–37 · output "redis_alarm_names"

rds와 같은 패턴으로 redis_memory_high, redis_evictions의 이름을 합친다.

## terraform/module/grafana/main.tf (475줄)

Grafana를 EKS에 설치하는 모듈의 본체다. 구성 요소: monitoring 네임스페이스 → ServiceAccount → Pod Identity용 IAM 역할·정책 → SA-역할 연결(association) → 전파 대기(time_sleep) → Helm 설치 → ALB Ingress. 이 파일의 백미는 time_sleep 앞의 긴 주석 — 2026-08-06 실제 장애의 부검 기록이다.

### L5–60 · locals { grafana_https_enabled, grafana_root_url, grafana_tags, grafana_ingress_annotations }

**`grafana_https_enabled`** — `try(trimspace(var.certificate_arn), "") != ""`: 인증서 ARN이 null이거나 공백이면 false. `try`는 null에 trimspace를 적용할 때의 에러를 흡수한다. 이 하나의 불리언이 root_url 스킴, Ingress 리스너 구성, 쿠키 보안 설정 세 곳을 일관되게 지배한다. **`grafana_root_url`** — https/http 스킴을 붙인 접속 URL. Grafana가 리다이렉트·링크 생성에 쓰는 canonical URL이며 모듈 출력 `url`로도 나간다. **`grafana_tags`** — 모듈 기본 태그(Project/ManagedBy/Component)에 `var.tags`를 merge. merge는 뒤가 이기므로 루트가 기본값을 덮어쓸 수 있다. **`grafana_ingress_annotations`** — ALB Ingress 어노테이션을 공통부+조건부로 merge한다. 공통부: `alb.ingress.kubernetes.io/group.name = var.alb_group_name`(웹과 ALB 공유), `group.order = "30"`(그룹 내 규칙 평가 순번 — 웹 Ingress 뒤 순번을 줘서 규칙 우선순위를 웹에 양보), `scheme = "internet-facing"`, `target-type = "ip"`(파드 IP 직결 — NodePort 홉 없이 라우팅), `backend-protocol = "HTTP"`(ALB→파드 구간은 평문, TLS는 ALB 종단), 헬스체크 3종(`healthcheck-path = /api/health`, HTTP, success-codes 200 — Grafana의 무인증 헬스 엔드포인트로, 기본 `/`를 쓰면 로그인 리다이렉트 302 때문에 헬스체크가 실패한다), `external-dns.alpha.kubernetes.io/hostname`(external-dns가 이 값으로 Route53 레코드 생성). 조건부: HTTPS면 `listen-ports`에 80+443, `certificate-arn`, `ssl-redirect = "443"`(80 진입을 443으로 리다이렉트)을 추가하고, 아니면 80만 연다. listen-ports 값을 `jsonencode`로 만드는 것은 이 어노테이션의 값 형식이 JSON 문자열이기 때문이다.

### L67–76 · resource "kubernetes_namespace_v1" "monitoring"

`var.namespace`(기본 monitoring) 네임스페이스를 만든다. 라벨 `monitoring = "enabled"`은 네트워크 폴리시나 셀렉터가 참조할 수 있는 표식이다. 이후 모든 K8s 리소스가 `metadata[0].name`을 참조해 네임스페이스 생성이 그래프상 선행된다.

### L83–94 · resource "kubernetes_service_account_v1" "grafana"

Grafana 파드가 쓸 SA. Helm 차트에게 만들게 하지 않고(차트 values에서 `serviceAccount.create = false`) Terraform이 직접 만드는 이유는 **Pod Identity association이 SA 이름을 참조해야 하고, 그 association이 Helm 설치보다 먼저 완료돼야 하기 때문**이다(아래 장애 기록 참조). 차트가 SA를 만들면 이 순서를 Terraform이 통제할 수 없다. `automount_service_account_token = true`는 K8s API 토큰 자동 마운트다.

### L101–119 · data "aws_iam_policy_document" "grafana_pod_identity_assume_role"

Pod Identity 신뢰 정책: principal `pods.eks.amazonaws.com`(Pod Identity 전용 서비스 프린시펄), actions `sts:AssumeRole` + `sts:TagSession`. TagSession이 IRSA와 다른 Pod Identity의 필수 요소다 — EKS가 세션에 클러스터/네임스페이스/SA 태그를 붙여 넘기므로 이것이 빠지면 assume 자체가 실패한다.

### L126–148 · resource "aws_iam_role" "grafana"

이름 `${var.cluster_name}-grafana-cloudwatch`. description 위 주석이 실전에서 얻은 지식이다: **IAM description은 ASCII+Latin-1( -~, ¡-ÿ)만 허용해서 한글을 넣으면 CreateRole이 ValidationError로 실패한다**(다른 리소스의 description/태그는 유니코드가 되지만 IAM만 예외) — 그래서 이 역할의 description만 영문이다. assume_role_policy는 위 신뢰 정책 문서, tags는 grafana_tags에 Name을 merge.

### L155–213 · data "aws_iam_policy_document" "grafana_cloudwatch"

Grafana CloudWatch 데이터소스가 요구하는 읽기 전용 권한 4개 statement다. (1) `ReadCloudWatchMetrics` — cloudwatch:DescribeAlarmsForMetric·DescribeAlarmHistory·DescribeAlarms(알람 상태·이력 표시), ListMetrics(메트릭 탐색 UI), GetMetricData(실제 시계열 조회 — 대시보드의 모든 Metrics 패널이 이걸 쓴다), GetInsightRuleReport(Contributor Insights). (2) `ReadCloudWatchLogs` — logs:DescribeLogGroups·GetLogGroupFields(로그 그룹 탐색), StartQuery/StopQuery/GetQueryResults(**Logs Insights 쿼리의 3단계 API** — 대시보드의 CWLI 패널 전부가 이 조합으로 동작한다), GetLogEvents(원시 로그 조회). (3) `ReadAwsResourceInformation` — ec2:DescribeRegions·DescribeInstances·DescribeTags·DescribeVolumes + tag:GetResources: 데이터소스가 리전 목록·리소스 정보를 채울 때 쓰는 보조 권한. (4) `ReadRdsPerformanceInsights` — `pi:GetResourceMetrics`(RDS Performance Insights 조회). 전부 `resources = ["*"]`인데, 이들 조회 API 대부분이 리소스 수준 제한을 지원하지 않아 실질적 선택지가 없다 — 읽기 전용이라는 것으로 위험을 한정한다.

### L215–220 · resource "aws_iam_role_policy" "grafana_cloudwatch"

위 정책 문서를 `${var.cluster_name}-grafana-cloudwatch-read`라는 inline policy로 역할에 부착한다.

### L227–236 · resource "aws_eks_pod_identity_association" "grafana"

클러스터+네임스페이스+SA 3튜플을 IAM 역할에 매핑하는 Pod Identity의 핵심 리소스다. 이 연결이 있으면 해당 SA로 뜨는 파드에 EKS가 자격증명 공급 환경변수(`AWS_CONTAINER_CREDENTIALS_FULL_URI`)와 토큰 볼륨(eks-pod-identity-token)을 주입한다.

### L250–253 · resource "time_sleep" "grafana_pod_identity_propagation"

`create_duration = "30s"`의 대기 리소스. 그 앞 L239–249 주석이 이 프로젝트에서 가장 값진 장애 기록이다. 요지: Pod Identity 자격증명 주입은 **파드가 생성되는 순간 EKS admission이 단 한 번** 수행한다. 그런데 association은 API가 200을 돌려준 뒤에도 admission 쪽에 반영되기까지 시간이 걸린다. `depends_on`은 "Terraform이 association 생성을 끝냈다"까지만 보장하므로, 바로 다음 스텝인 helm_release가 그 전파 갭 안에서 파드를 띄우면 주입이 통째로 누락된다. 주입 기회는 파드 생성 시 1회뿐이라 이후 association이 전파돼도 **그 파드는 끝까지 자격증명이 없다**. 결과: AWS SDK가 자격증명 체인 끝의 IMDS로 폴백 → "no EC2 IMDS role found" → CloudWatch 데이터소스 GetMetricData 실패 → 대시보드 전 패널 No data. 2026-08-06 실제 장애였고, depends_on이 이미 걸려 있었는데도 발생했다(RS가 1개뿐인 최초 배포 파드에 env·볼륨이 둘 다 없었음). 주석은 이를 s3.tf의 wait_for_public_access_block과 같은 뿌리로 일반화한다: **"그래프상 순서 != 실제 전파 완료"** — Terraform 의존 그래프는 API 호출 순서만 보장할 뿐, 분산 시스템의 최종 일관성 지연은 모른다. time_sleep 30초는 그 간극을 메우는 실용적 처방이다.

### L260–431 · resource "helm_release" "grafana"

Helm 설치 본체. 릴리스 설정: `repository = "https://grafana-community.github.io/helm-charts"`, `chart = "grafana"`, `version = "12.8.0"`(차트 버전 핀 — most_recent인 EKS 애드온과 달리 Helm은 고정해 재현성을 확보), namespace는 위 네임스페이스 참조, `create_namespace = false`(Terraform이 이미 만듦), `atomic = true`+`cleanup_on_fail = true`(실패 시 자동 롤백·잔재 정리 — daily-up 자동화에서 반쯤 설치된 릴리스가 다음 apply를 막는 것을 방지), `wait = true`+`timeout = 600`(파드 Ready까지 최대 10분 대기).

values의 yamlencode 블록을 키별로 본다:

- `fullnameOverride = "grafana"` — 리소스 이름을 `grafana`로 고정. 아래 Ingress backend가 service 이름 "grafana"를 문자열로 참조하므로 이 고정이 있어야 배선이 안 끊긴다.
- `replicas = 1` — 단일 레플리카. persistence 없이 다중 레플리카를 두면 UI에서 만진 상태가 파드마다 갈라지므로 1이 맞다.
- `rbac.create = false` / `serviceAccount = { create = false, name = <Terraform SA> }` — SA는 Terraform 소유(Pod Identity 순서 통제 때문), Grafana는 K8s API를 쓸 일이 없어 RBAC도 불필요.
- `automountServiceAccountToken = true` — 차트 레벨에서도 토큰 마운트 허용.
- `testFramework.enabled = false` — helm test용 파드 비활성(불필요한 리소스 제거).
- `service` — type ClusterIP, port 80 → targetPort 3000(Grafana 기본 포트). 외부 노출은 Ingress가 담당하므로 ClusterIP로 충분.
- `ingress.enabled = false` — 차트 내장 Ingress 대신 아래 kubernetes_ingress_v1 리소스로 별도 생성(주석 명시). 어노테이션 조건부 merge 같은 로직을 Terraform 쪽에서 다루기 위함이다.
- `persistence.enabled = false` — PVC 비활성. type/storageClassName/accessModes/size 설정이 통째로 주석 처리되어 있다. 매일 destroy되는 환경에서 대시보드는 어차피 코드(프로비저닝)로 주입되므로 상태 보존이 무의미하고, EBS PVC는 destroy 순서 문제까지 만든다. 루트에서 넘어오는 storage_class_name/storage_size 변수가 휴면 상태인 이유다.
- `resources` — requests cpu 250m/memory 512Mi, limits cpu 1/memory 1Gi. 소규모 클러스터에서 Grafana가 노드 자원을 독식하지 않게 하는 상한.
- `env` — `AWS_REGION`·`AWS_DEFAULT_REGION`에 var.region. SDK가 리전을 추측하지 않도록 명시한다.
- `datasources` — sidecar 없이 프로비저닝 파일(`datasources.yaml`)로 CloudWatch 데이터소스를 시작 시 자동 등록. `uid = "cloudwatch"`를 고정하는 것이 중요하다 — **대시보드 JSON 전부가 이 uid를 하드코딩으로 참조**하므로 uid가 자동 생성되면 전 패널이 데이터소스를 못 찾는다. `access = "proxy"`(브라우저가 아니라 Grafana 서버가 AWS API 호출 — Pod Identity 자격증명을 쓰려면 필수), `isDefault = true`, `editable = false`(UI에서 수정 금지 — 코드가 진실의 원천). jsonData: `authType = "default"`(SDK 기본 자격증명 체인 → Pod Identity), `defaultRegion = var.region`, `customMetricsNamespaces = "ContainerInsights"`(커스텀 네임스페이스를 메트릭 탐색에 노출).
- `dashboardProviders` — 파일 프로바이더 "gochuchamchi"를 등록: `orgId = 1`, `folder = "Gochuchamchi"`(UI 폴더명), `type = "file"`, `path = /var/lib/grafana/dashboards/gochuchamchi`, `disableDeletion = false`·`editable = true`(UI에서 만져볼 수는 있게 — 어차피 파드 재생성 시 코드 상태로 복원된다).
- `dashboards.gochuchamchi` — 대시보드 3장을 JSON 문자열로 주입: `eks-logs-overview`(local.eks_logs_dashboard — dashboard.tf), `eks-health-overview`(local.eks_health_dashboard — metrics_dashboard.tf), `aws-errors-overview`(local.aws_errors_dashboard — aws_errors_dashboard.tf). 차트가 이들을 ConfigMap으로 만들어 프로바이더 경로에 마운트한다. **대시보드 .tf 파일들이 helm_release와 연결되는 지점이 정확히 여기다.**
- `grafana.ini` — Grafana 본체 설정: `server.domain`/`root_url`(위 locals — 리다이렉트·쿠키 도메인의 기준), `serve_from_sub_path = false`(루트 경로 서빙), `security.cookie_secure = local.grafana_https_enabled`(HTTPS일 때만 Secure 쿠키 — HTTP 상태에서 Secure를 켜면 로그인이 안 된다), `users.allow_sign_up = false`(자가 가입 차단), `auth_anonymous.enabled = false`(익명 접근 차단 — 인터넷 노출 대시보드의 최소 방어), `aws.allowed_auth_providers = "default"`(자격증명 체인만 허용, 액세스키 직접 입력 방식 차단)·`assume_role_enabled = true`.

`depends_on = [time_sleep.grafana_pod_identity_propagation, aws_iam_role_policy.grafana_cloudwatch]` — 주석 그대로 "association 직후가 아니라 전파 대기를 거친 뒤에 파드를 띄운다". 역할 정책 부착도 선행시켜 파드의 첫 API 호출이 권한 없음으로 실패하지 않게 한다.

### L438–476 · resource "kubernetes_ingress_v1" "grafana"

Grafana용 ALB Ingress. `annotations = local.grafana_ingress_annotations`(위 locals의 조건부 merge 결과), `ingress_class_name = "alb"`(aws-load-balancer-controller 담당 표시), rule은 `host = var.grafana_hostname`으로 host 기반 라우팅 — 같은 ALB를 웹과 공유하므로 host 헤더로만 Grafana 트래픽을 구분한다. backend는 service "grafana"(fullnameOverride로 고정한 이름)의 port 80. `wait_for_load_balancer = true` — 컨트롤러가 ALB를 실제 프로비저닝해 status에 주소가 잡힐 때까지 apply를 대기시킨다: 이 대기가 있어야 daily-up 종료 시점에 접속 가능한 상태가 보장된다. `depends_on = [helm_release.grafana]` — 백엔드 서비스가 생긴 뒤 Ingress를 만든다.

## terraform/module/grafana/variables.tf (60줄)

모듈 입력 11개.

### L1–4 · variable "cluster_name"

필수(기본값 없음). IAM 역할 이름 접두사, Pod Identity association, 대시보드의 ClusterName 디멘션·로그 그룹 이름 조립에 쓰인다.

### L6–9 · variable "region"

필수. CloudWatch 데이터소스 defaultRegion, 파드 env, 대시보드 모든 타깃의 region 필드, 로그 그룹 ARN 조립에 쓰인다.

### L11–15 · variable "namespace"

기본 "monitoring". 네임스페이스 리소스와 association에 쓰인다.

### L17–21 · variable "service_account_name"

기본 "grafana". SA 리소스 이름.

### L23–26 · variable "grafana_hostname"

필수. Ingress host 규칙, external-dns 어노테이션, grafana.ini의 domain/root_url — 접속 도메인의 단일 진실 공급원.

### L28–32 · variable "storage_class_name" / L34–38 · variable "storage_size"

기본 "ebs-sc"/"5Gi". persistence가 꺼져 있어 현재는 휴면 인자다(main.tf 해설 참조). 인터페이스만 남겨 나중에 PVC를 켤 때 루트 수정 없이 모듈만 바꾸면 되게 한 형태다.

### L40–44 · variable "alb_group_name"

기본 "gochuchamchi-web". IngressGroup 병합용 — 웹 ALB 공유의 스위치.

### L46–51 · variable "certificate_arn"

`default = null`, `nullable = true` — 명시적으로 "없을 수 있음"을 선언한 유일한 변수다. null/공백이면 모듈이 HTTP 전용으로 동작하는 분기(locals의 grafana_https_enabled)와 짝을 이룬다.

### L53–57 · variable "tags"

기본 {}. grafana_tags에 merge된다.

### L58–61 · variable "rds_identifier"

필수. aws_errors_dashboard.tf가 RDS error 로그 그룹 이름(`/aws/rds/instance/<id>/error`)을 조립하는 데만 쓰인다 — 모듈이 RDS 자원을 만들지는 않는다.

## terraform/module/grafana/outputs.tf (28줄)

### L1–4 · output "namespace" / L6–9 · output "service_account_name"

생성된 네임스페이스·SA 이름. 다른 코드나 검증 스크립트가 kubectl 대상 지정에 쓸 수 있는 값이다.

### L11–14 · output "iam_role_arn"

CloudWatch 조회용 역할 ARN. 루트 grafana.tf가 `grafana_iam_role_arn`으로 재노출한다.

### L16–19 · output "hostname" / L21–24 · output "url"

접속 도메인과 스킴 포함 URL(locals.grafana_root_url). url은 루트에서 `grafana_url`로 재노출된다.

### L26–28 · output "helm_release_name"

Helm 릴리스 이름("grafana"). helm 명령으로 릴리스를 다룰 때의 앵커다.

## terraform/module/grafana/dashboard.tf (749줄)

첫 번째 대시보드 "Gochuchamchi EKS Logs"(uid `gochuchamchi-eks-logs`)의 JSON 정의다. 파일 전체가 data source 하나와 locals 하나로 이루어져 있고, `jsonencode`로 만든 JSON 문자열이 main.tf의 `dashboards.gochuchamchi["eks-logs-overview"]`에 주입된다. Terraform 맵으로 대시보드를 쓰면 JSON 원문 대비 주석을 달 수 있고 `var.region` 같은 변수 보간이 되는 것이 장점이다. 이 대시보드의 패널 9개는 전부 CloudWatch **Logs Insights**(queryMode "Logs", queryLanguage "CWLI") 쿼리로, application 로그 그룹 하나만 바라본다. 공통 프레임: `schemaVersion = 41`(Grafana 11.x대 스키마), `refresh = "30s"`(자동 새로고침), `time = now-1h ~ now`(기본 조회 창 — "최근 1시간"이라는 패널 제목들은 이 기본값 전제이며, 사용자가 시간 범위를 바꾸면 제목과 실제 값의 의미가 어긋난다는 점이 소소한 함정이다), `editable = true`, `timezone = "browser"`. 모든 타깃은 `datasource = { type = "cloudwatch", uid = "cloudwatch" }`로 main.tf가 고정한 데이터소스 uid를 참조하고, `logGroups`에 이름+ARN 쌍을 명시한다(신형 Grafana CloudWatch 플러그인은 로그 그룹을 ARN으로 식별한다). `logGroupNames = []`·`matchExact = true`·`metricQueryType = 0`·`statsGroups = []`는 플러그인 스키마가 요구하는 상용구다.

### L1 · data "aws_caller_identity" "current"

현재 계정 ID 조회. 로그 그룹 ARN 조립에 쓰인다. 이 data source는 이 파일에 있지만 aws_errors_dashboard.tf의 ARN 조립도 같이 쓴다(모듈 내 공유).

### L3–14 · locals { application_log_group_name, application_log_group_arn }

`application_log_group_name = "/aws/containerinsights/${var.cluster_name}/application"` — 루트 cloudwatch-observability.tf가 만드는 로그 그룹과 같은 이름을 **모듈 안에서 다시 조립**한다(모듈 경계를 넘는 리소스 참조 대신 명명 규약에 의존 — 루트 쪽 이름이 바뀌면 여기도 같이 바꿔야 하는 암묵 계약이다). ARN은 `arn:aws:logs:<region>:<account>:log-group:<name>:*` 형식으로 join 조립하며, 끝의 `:*`는 로그 스트림 전체를 뜻하는 CloudWatch Logs ARN 관례다.

### L16–749 · locals { eks_logs_dashboard } — 패널 9개

#### 패널 id 1 · "최근 1시간 ERROR" (stat, L51–135)

- 데이터소스: CloudWatch Logs Insights(application 로그 그룹). 쿼리: `filter @message like /(?i)(error|exception|failed)/ | stats count(*) as error_count` — 대소문자 무시 정규식으로 error/exception/failed 중 하나라도 포함한 로그 줄 수를 센다. JSON 파싱에 기대지 않는 러프한 매칭이라 로그 형식이 바뀌어도 동작하지만, "Error handling done" 같은 무해한 문장도 세는 과탐 여지는 있다.
- 시각화: stat, `gridPos w=8,h=4,(0,0)` — 최상단 좌측. `colorMode = "background"`(배경 전체 착색), `graphMode = "none"`, `reduceOptions.calcs = ["lastNotNull"]`(쿼리 결과가 단일 행이므로 그 값 표시).
- 임계값: absolute, base green → **1부터 red**. "ERROR 0건 = 초록"이라는 신호등 — 대시보드를 연 순간 색만 보고 상태를 읽게 하는 설계다.
- 보는 이유: 지난 1시간 애플리케이션 오류의 총량을 한 눈에. 알람(5분 창)보다 긴 시야의 보조 지표다.

#### 패널 id 2 · "최근 1시간 WARN" (stat, L139–224)

- 쿼리: `filter @message like /(?i)warn/ | stats count(*) as warn_count`. ERROR 패널과 같은 구조로 warn만 센다.
- 시각화: stat, `w=8,h=4,(8,0)` — 상단 중앙. 같은 background/lastNotNull 구성.
- 임계값: green → **1부터 yellow**(red가 아님) — WARN은 조사 대상이지 장애가 아니라는 위계 구분이 색으로 표현되어 있다.
- 보는 이유: ERROR로 번지기 전의 전조(재시도, 커넥션 풀 고갈 임박 등) 총량 확인.

#### 패널 id 6 · "ERROR 로그 발생 추이" (timeseries, L228–310)

- 쿼리: 같은 ERROR 필터에 `| stats count(*) as error_count by bin(5m)` — 5분 버킷 시계열로 집계.
- 시각화: timeseries, `w=12,h=8,(0,4)`. custom: `drawStyle = "line"`, `lineInterpolation = "smooth"`, `lineWidth = 2`, `fillOpacity = 15`(면 옅게 채움), `showPoints = "never"`, stacking 없음. legend는 하단 list, tooltip single.
- 임계값: 없음(추이 관찰용).
- 보는 이유: stat이 "얼마나"라면 이 패널은 "언제" — 오류가 특정 시각에 몰렸는지(배포·외부 이벤트 상관) 폭발적인지 지속적인지를 판별한다. 알람 수신 후 원인 시각을 좁히는 첫 화면이다.

#### 패널 id 4 · "최근 1시간 전체 로그" (stat, L314–383)

- 쿼리: `stats count(*) as total_log_count` — 필터 없이 전체 로그 줄 수.
- 시각화: stat, `w=8,h=4,(16,0)` — 상단 우측. `colorMode = "value"`(숫자만 착색), `graphMode = "area"`(배경 스파크라인), 임계값 없음 — 절대량에 좋고 나쁨이 없기 때문이다.
- 보는 이유: 로그 파이프라인 건강 지표. 이 값이 0이면 "오류가 없다"가 아니라 **수집이 죽었다**는 뜻이다 — ERROR 0/WARN 0이 초록으로 보여도 전체 로그가 0이면 착시라는 것을 잡아주는, 관측 시스템 자체를 관측하는 패널이다.

#### 패널 id 5 · "WARN 로그 발생 추이" (timeseries, L388–470)

- 쿼리: warn 필터 + `by bin(5m)`. ERROR 추이 패널과 동일한 시각화 옵션(smooth line, fillOpacity 15, legend bottom).
- 배치: `w=12,h=8,(12,4)` — ERROR 추이의 우측 짝. 두 추이를 나란히 두어 "WARN 급증 → ERROR 급증"의 시차 패턴을 눈으로 좇게 했다.

#### 패널 id 3 · "최근 ERROR / Exception 로그" (logs, L474–535)

- 쿼리: `fields @timestamp, @message, @logStream | filter @message like /(?i)(error|exception|failed)/ | sort @timestamp desc | limit 100` — 오류 로그 원문 최신 100건. `@logStream`을 포함해 어느 파드 스트림에서 나왔는지 추적 가능하게 했다.
- 시각화: logs 패널, `w=24,h=12,(0,12)` — 전폭. options: `showTime = true`, `wrapLogMessage = true`(긴 스택트레이스 줄바꿈), `enableLogDetails = true`(행 클릭 시 필드 전개), `sortOrder = "Descending"`(최신 우선), dedup 없음.
- 보는 이유: 위 stat/추이가 "오류가 있다"까지 알려주면, 여기서 스택트레이스 원문으로 바로 내려간다 — CloudWatch 콘솔로 이동할 필요 없이 대시보드 안에서 triage가 끝나게 하는 배치다.

#### 패널 id 7 · "최근 애플리케이션 로그" (logs, L539–599)

- 쿼리: 필터 없이 `fields @timestamp, @message, @logStream | sort @timestamp desc | limit 200` — 전체 로그 최신 200건.
- 시각화: logs, `w=24,h=16,(0,24)` — 전폭, 더 큰 높이. 옵션은 id 3과 동일.
- 보는 이유: 오류 필터에 안 걸리는 문맥(오류 직전의 정상 로그, INFO 흐름)을 보는 창이다. 오류 로그만 보면 인과가 안 보일 때 앞뒤 문맥을 확인한다.

#### 패널 id 8 · "Pod별 로그 발생량 Top 10" (table, L603–672)

- 쿼리: `fields kubernetes.pod_name | filter ispresent(kubernetes.pod_name) | stats count(*) as log_count by kubernetes.pod_name | sort log_count desc | limit 10`. `kubernetes.pod_name`은 Fluent Bit(Classic Container Insights 경로)이 로그에 붙이는 메타데이터 필드다 — cloudwatch-observability.tf에서 otelContainerInsights를 끈 이유가 바로 이 필드 스키마를 지키기 위해서였다. `ispresent` 필터로 메타데이터 없는 줄을 제외한다.
- 시각화: table, `w=24,h=10,(0,40)`. `showHeader = true`, `cellHeight = "sm"`, align auto.
- 보는 이유: 로그 폭주(비용·노이즈)의 주범 파드 식별. 로그 요금은 수집량 과금이므로 비용 관리 화면이기도 하다.

#### 패널 id 9 · "Pod별 ERROR 발생량 Top 10" (table, L676–747)

- 쿼리: id 8과 같은 골격에 `| filter @message like /(?i)(error|exception|failed)/`를 추가해 파드별 오류 수 Top 10을 집계.
- 시각화: table, `w=24,h=10,(0,50)` — id 8 바로 아래.
- 보는 이유: "오류가 나는데 **어느 파드인가**"에 대한 즉답. 특정 파드 편중이면 해당 파드/노드 문제, 전 파드 고른 분포면 공통 의존성(DB·Redis) 문제라는 1차 분기를 이 표 하나로 한다.

## terraform/module/grafana/metrics_dashboard.tf (1015줄)

두 번째 대시보드 "Gochuchamchi EKS Health"(uid `gochuchamchi-eks-health`)다. 로그 대시보드와 달리 패널 9개 전부가 CloudWatch **Metrics** 쿼리(queryMode "Metrics")이고, 데이터 원천은 애드온이 만드는 `ContainerInsights` 네임스페이스다. 상단 stat 4개(클러스터 개요) → 중단 timeseries 2개(노드 자원) → 하단 timeseries 3개(파드 수준)로 "클러스터 → 노드 → 파드"의 드릴다운 동선이 배치에 새겨져 있다. 프레임은 로그 대시보드와 거의 같고 `graphTooltip = 1`(모든 그래프에 십자선 공유 — 패널 간 같은 시각 비교)이 추가됐다. 일반 메트릭 타깃의 공통 상용구: `metricQueryType = 0`(builder), `metricEditorMode = 0`, `matchExact = true`(디멘션 완전 일치 매칭), `period = "60"`(1분 해상도).

### L1–1016 · locals { eks_health_dashboard } — 패널 9개

#### 패널 id 1 · "실행 중인 Pod" (stat, L32–122)

- 쿼리: ContainerInsights `namespace_number_of_running_pods`, `statistic = "Average"`, period 60, 디멘션 `ClusterName = var.cluster_name`, label "Running Pods".
- 시각화: stat, `w=6,h=4,(0,0)`. colorMode background, lastNotNull.
- 임계값: **base red → 1부터 green** — 다른 패널과 방향이 반대다. "실행 중인 파드 0 = 빨강"으로, 값이 있어야 정상인 지표의 신호등이다.
- 보는 이유: daily-up 직후 "클러스터에 뭔가 떠 있긴 한가"를 1초 만에 확인하는 생존 신호.

#### 패널 id 2 · "비정상 Node" (stat, L126–216)

- 쿼리: `cluster_failed_node_count`, `statistic = "Maximum"`(기간 내 한 번이라도 실패 노드가 있었으면 잡히게), ClusterName 디멘션, label "Failed Nodes".
- 시각화: stat, `w=6,h=4,(6,0)`. 임계값 green → 1부터 red.
- 보는 이유: NotReady 노드 존재 여부. 노드 1대 구성에 가까운 소규모 클러스터에서는 노드 실패가 곧 전체 장애다.

#### 패널 id 3 · "전체 Worker Node" (stat, L220–310)

- 쿼리: `cluster_node_count`, Maximum, ClusterName, label "Worker Nodes".
- 시각화: stat, `w=6,h=4,(12,0)`. 임계값 **red → 1부터 green**(id 1과 같은 역방향 — 0대면 빨강).
- 보는 이유: 기대 노드 수와의 대조. 오토스케일링·스팟 회수로 수가 변했는지 즉시 확인.

#### 패널 id 4 · "Pending Pod" (stat, L314–404)

- 쿼리: `pod_status_pending`, Maximum, ClusterName, label "Pending Pods".
- 시각화: stat, `w=6,h=4,(18,0)`. 임계값 green → 1부터 red.
- 보는 이유: Pending은 "자원이 모자라거나 스케줄 제약에 걸렸다"는 뜻 — 노드 용량 부족의 가장 이른 사용자 관점 증상이다. 상단 4칸이 합쳐져 "파드 돌고 있나 / 노드 죽었나 / 노드 몇 대인가 / 스케줄 밀리나"라는 클러스터 4문진을 이룬다.

#### 패널 id 5 · "Node CPU 사용률" (timeseries, L408–525)

- 쿼리: `node_cpu_utilization`, Average, period 60, ClusterName 디멘션, label "Node CPU".
- 시각화: timeseries, `w=12,h=8,(0,4)`. unit "percent", min 0/max 100(축 고정 — 스케일 착시 방지), palette-classic, line/linear/width 2/fillOpacity 10/showPoints never. legend에 `calcs = ["mean", "max"]`로 평균·최대 요약을 함께 표기. thresholds green→70 yellow→90 red를 정의하되 `thresholdsStyle.mode = "off"` — 색 기준은 갖고 있지만 그래프에 임계선을 그리지는 않는 상태다.
- 보는 이유: 노드 수준 CPU 포화 추적. RDS CPU 알람처럼 EKS 노드에는 알람이 없으므로 이 패널이 노드 자원의 주 감시 창이다.

#### 패널 id 6 · "Node 메모리 사용률" (timeseries, L529–646)

- 쿼리: `node_memory_utilization`, Average. 나머지는 id 5와 완전히 동일한 시각화·임계값 구성으로 `(12,4)`에 배치 — CPU/메모리를 좌우 쌍으로 본다.
- 보는 이유: 메모리는 CPU와 달리 포화 시 OOMKill로 즉사하므로, 70/90 경고 색 기준의 실질 의미가 더 무겁다.

#### 패널 id 7 · "Pod 컨테이너 재시작 누적 횟수" (timeseries, L650–765)

- 쿼리: `pod_number_of_container_restarts`, `statistic = "Maximum"`, 디멘션 `ClusterName = var.cluster_name, Namespace = "*", PodName = "*"` — 와일드카드 디멘션으로 전 네임스페이스·전 파드의 시계열을 각각 가져오고, `label = "{{Namespace}} / {{PodName}}"` 템플릿으로 범례에 파드 식별자를 찍는다.
- 시각화: timeseries, `w=24,h=8,(0,12)` — 전폭. `showPoints = "auto"`, legend는 **table** 모드로 `calcs = ["lastNotNull", "max"]` — 파드별 현재 누적치·최대치를 표로 정렬해 보게 했다. tooltip은 multi/desc(십자선 위치의 전 시리즈 값을 내림차순 표시). 임계값 green → 1부터 red(재시작 1회부터 비정상 취급).
- 보는 이유: CrashLoopBackOff의 대시보드적 표현이다. 이 메트릭은 **누적 카운터**라 계단형으로 올라가는데, 계단이 반복적으로 생기면 크래시 루프, 한 번 오르고 평평하면 일회성 재시작으로 구분해 읽는다.

#### 패널 id 8 · "Pod CPU 사용률 Top 10" (timeseries, L769–889)

- 쿼리: 이 대시보드에서 유일하게 다른 쿼리 방식 — `metricQueryType = 1`·`metricEditorMode = 1`, 즉 **CloudWatch Metrics Insights SQL**(코드 편집기 모드)이다: `SELECT AVG(pod_cpu_utilization) FROM SCHEMA("ContainerInsights", ClusterName, Namespace, PodName) WHERE ClusterName = '${var.cluster_name}' GROUP BY Namespace, PodName ORDER BY AVG() DESC LIMIT 10`. builder 방식(디멘션 나열)으로는 "상위 10개만"을 표현할 수 없어서 SQL이 필요하다 — `SCHEMA(네임스페이스, 디멘션들)`은 해당 디멘션 조합을 가진 메트릭만 대상으로 삼는 Metrics Insights 특유의 문법이고, `ORDER BY AVG() DESC LIMIT 10`이 서버 측에서 Top 10을 잘라 온다. Terraform 보간(`${var.cluster_name}`)이 SQL 안에 직접 들어가는 점도 눈여겨볼 부분이다.
- 시각화: timeseries, `w=12,h=8,(0,20)`. percent, min 0/max 100, legend table(mean/max), tooltip multi/desc, 임계값 70/90(표시 off).
- 보는 이유: 노드 CPU가 높을 때 "누가 먹는가"로 내려가는 드릴다운. limit/request 튜닝의 근거 화면이다.

#### 패널 id 9 · "Pod 메모리 사용률 Top 10" (timeseries, L893–1013)

- 쿼리: id 8과 같은 Metrics Insights SQL로 대상만 `pod_memory_utilization`. `id = "podmemory"`.
- 시각화: `(12,20)`에 id 8과 좌우 쌍, 동일 구성.
- 보는 이유: 메모리 leak 파드 식별 — 우상향 곡선을 그리는 파드가 leak 후보이고, OOMKill(id 7 재시작 패널)과 교차 대조하면 확진에 가까워진다.

## terraform/module/grafana/aws_errors_dashboard.tf (1348줄)

세 번째 대시보드 "Gochuchamchi AWS Errors"(uid `gochuchamchi-aws-errors`)다. EKS 바깥의 관리형 자원 — ALB, RDS, ElastiCache Redis — 의 오류만 모은 화면으로, cloudwatch-managed-metrics 모듈의 알람들과 정확히 같은 메트릭 축을 시각화 쪽에서 커버한다(알람이 "울리는" 축이라면 이 대시보드는 "보는" 축). 패널 13개: stat 8 + logs 1 + timeseries 4. 특징 두 가지: (1) ALB/Redis 메트릭 타깃이 전부 `LoadBalancer = "*"`, `CacheClusterId = "*"` 같은 **와일드카드 디멘션**을 쓴다 — ALB는 컨트롤러가 만들어 이름을 미리 알 수 없으므로, 알람 모듈처럼 태그 API로 ARN을 역산하는 대신 대시보드는 와일드카드로 "있는 것 전부"를 그린다(대시보드 JSON은 빌드 시점 고정이라 이 방식이 더 강건하다). (2) stat 패널들에 `noValue = "0"`이 있다 — 오류 메트릭은 오류가 없으면 데이터포인트 자체가 없어 "No data"로 표시되는데, 이를 "0"으로 바꿔 "오류 없음"으로 읽히게 한 세심함이다(알람의 treat_missing_data = notBreaching과 같은 문제의식의 시각화 버전).

### L1–12 · locals { rds_error_log_group_name, rds_error_log_group_arn }

`/aws/rds/instance/${var.rds_identifier}/error` — RDS가 자동 생성하는 MariaDB error 로그 그룹 이름을 조립한다(루트 grafana.tf가 넘긴 rds_identifier의 유일한 사용처). ARN 조립은 dashboard.tf와 같은 join 패턴이고 data.aws_caller_identity.current(dashboard.tf에 정의)를 공유한다.

### L13–1349 · locals { aws_errors_dashboard } — 패널 13개

#### 패널 id 1 · "ALB 자체 5XX 오류" (stat, L43–134)

- 쿼리: `AWS/ApplicationELB`의 `HTTPCode_ELB_5XX_Count`, Sum, period 60, 디멘션 `LoadBalancer = "*"`, label "{{LoadBalancer}}".
- 시각화: stat, `w=6,h=5,(0,0)`. `reduceOptions.calcs = ["sum"]` — 1분 단위 시계열을 다시 합산해 조회 창 전체의 총 건수를 표시(다른 대시보드 stat의 lastNotNull과 다른 선택 — 카운트 메트릭이기 때문). graphMode "area"로 배경 스파크라인. noValue "0". 임계값 green → 1부터 red.
- 보는 이유: **ELB_5XX와 Target_5XX의 구분**이 이 대시보드 상단 설계의 핵심이다. ELB_5XX는 ALB 자체가 만든 오류(백엔드 연결 불가로 인한 502/503/504 등)로, 앱 로그에는 아무 흔적이 없다. 이 값이 높은데 앱 로그가 조용하면 문제는 앱이 아니라 그 앞 구간이다.

#### 패널 id 2 · "Target 애플리케이션 5XX 오류" (stat, L138–229)

- 쿼리: `HTTPCode_Target_5XX_Count`, Sum, `LoadBalancer = "*"`. 나머지는 id 1과 동일 구성, `(6,0)` 배치.
- 보는 이유: Spring이 실제로 돌려준 5xx. 알람 모듈의 alb_target_5xx(임계 5)와 같은 메트릭이라, 알람 수신 → 이 패널에서 규모 확인 → EKS Logs 대시보드로 이동하는 동선의 중간 다리다.

#### 패널 id 3 · "ALB Target 연결 실패" (stat, L233–324)

- 쿼리: `TargetConnectionErrorCount`, Sum, `LoadBalancer = "*"`. 같은 stat 구성, `(12,0)`.
- 보는 이유: ALB가 Target에 TCP 연결조차 못 한 횟수 — 보안그룹 오설정, 파드 다운, target-type ip 환경에서 파드 IP 갱신 지연 등의 신호다. 5xx보다 낮은 계층의 실패를 분리해 보여준다.

#### 패널 id 4 · "최근 1시간 비정상 Target 최대 수" (stat, L328–420)

- 쿼리: `UnHealthyHostCount`, `statistic = "Maximum"`, 디멘션 `LoadBalancer = "*", TargetGroup = "*"`, label "{{LoadBalancer}} / {{TargetGroup}}".
- 시각화: stat, `(18,0)`. `reduceOptions.calcs = ["max"]` — 시계열의 최대값(합산이 아니라, "순간 최대 몇 대까지 빠졌었나"). 임계값 green → 1 red.
- 보는 이유: 알람 alb_unhealthy_host와 같은 메트릭의 시각화판. 조회 창 내 최악의 순간을 보존해 보여주므로, 이미 복구됐어도 "1시간 안에 헬스체크 이탈이 있었다"는 사실이 남는다.

#### 패널 id 5 · "최근 1시간 RDS ERROR" (stat, L424–519)

- 쿼리: 이 대시보드에서 Logs Insights를 쓰는 첫 패널. RDS error 로그 그룹에 `filter @message like /(?i)(\[error\]|fatal|crash|failed|abort)/ | stats count(*) as rds_error_count`. 패턴이 `\[error\]`(대괄호 포함)인 것에 주목 — MariaDB error 로그의 `[ERROR]` 태그 형식을 정확히 노리면서, 본문에 흔한 단어 "error"의 과탐을 줄인 것이다.
- 시각화: stat, `w=6,h=5,(0,5)`. lastNotNull(단일 행 쿼리), noValue "0", green → 1 red.
- 보는 이유: DB 엔진 수준의 오류(연결 거부, 복구, aborted connection) 존재 여부. 앱 5xx의 근본 원인이 DB일 때 이 칸이 먼저 붉어진다.

#### 패널 id 6 · "최근 RDS ERROR 로그" (logs, L523–584)

- 쿼리: 같은 로그 그룹에 `fields @timestamp, @message, @logStream | filter @message like /(?i)(error|fatal|crash|failed|abort)/ | sort @timestamp desc | limit 100`. **stat(id 5)보다 넓은 패턴**이다(`error` — 대괄호 없음): 카운트는 보수적으로, 원문 열람은 폭넓게 잡는 의도적 비대칭으로 읽힌다.
- 시각화: logs, `w=24,h=12,(0,10)` — 전폭. wrapLogMessage·enableLogDetails 등 로그 패널 표준 옵션.
- 보는 이유: id 5에서 오류 존재를 확인하면 원문으로 즉시 하강. RDS 콘솔에 들어가지 않고 대시보드에서 DB 오류 문면까지 본다.

#### 패널 id 7 · "최근 1시간 Redis 인증 실패" (stat, L588–678)

- 쿼리: `AWS/ElastiCache`의 `AuthenticationFailures`, Sum, period 60, 디멘션 `CacheClusterId = "*", CacheNodeId = "*"`, label "{{CacheClusterId}} / {{CacheNodeId}}". (이 타깃만 `matchExact`/`id` 상용구가 빠져 있는데 동작에는 무해한 비일관성이다.)
- 시각화: stat, `w=8,h=5,(0,22)`. calcs sum, noValue "0", green → 1 red.
- 보는 이유: AUTH 실패는 잘못 배포된 자격증명(앱 설정 오류) 아니면 **비인가 접근 시도**다. transit encryption + AUTH를 쓰는 이 프로젝트 구성에서 보안 신호로서의 의미가 크다.

#### 패널 id 8 · "최근 1시간 Redis 연결 거부" (stat, L682–774)

- 쿼리: `RejectedConnections`, Sum, 같은 와일드카드 디멘션. `(8,22)` 배치, 동일 stat 구성.
- 보는 이유: maxclients 도달로 연결이 거부된 횟수 — 커넥션 풀 누수나 급격한 스케일아웃의 신호. 인증 실패(보안)와 연결 거부(용량)를 나란히 두어 원인 계열을 즉시 가른다.

#### 패널 id 9 · "최근 1시간 Redis 명령 실행 실패" (stat, L778–870)

- 쿼리: `ErrorCount`, Sum, 같은 디멘션. `(16,22)` 배치, 동일 구성.
- 보는 이유: 명령 수준 오류(잘못된 명령, OOM 계열 실패 등) 총량. 상단 두 칸이 "들어오는 단계"의 실패라면 이 칸은 "들어와서 실행하다" 실패한 건수다.

#### 패널 id 10 · "Redis 오류 추이" (timeseries, L874–1010)

- 쿼리: 타깃 3개(refId A/B/C)로 `AuthenticationFailures`·`RejectedConnections`·`ErrorCount`를 한 그래프에 겹친다. 전부 Sum/period 60/와일드카드 디멘션, label에 "인증 실패 - …", "연결 거부 - …", "명령 실패 - …" 접두어를 붙여 범례에서 계열을 구분한다.
- 시각화: timeseries, `w=24,h=9,(0,27)`. line/linear/width 2/fillOpacity 10/showPoints auto/pointSize 5, legend list bottom, tooltip multi/desc.
- 보는 이유: stat 3개(id 7–9)의 시간축 버전. 세 오류의 동시 발생 여부(예: 인증 실패와 연결 거부가 같이 튀면 무차별 접속 시도)를 한 화면에서 상관 분석한다.

#### 패널 id 11 · "RDS 오류 발생 추이" (timeseries, L1014–1100)

- 쿼리: RDS error 로그 그룹 Logs Insights — `filter @message like /(?i)(error|fatal|crash|failed|abort)/ | stats count(*) as rds_error_count by bin(5m)`. 넓은 패턴(id 6과 동일)의 5분 버킷 시계열.
- 시각화: timeseries, `w=24,h=9,(0,36)`. fillOpacity 15, 나머지는 id 10과 유사.
- 보는 이유: DB 오류의 "언제" — 백업 창·페일오버·배포 시각과의 상관을 본다. Logs Insights 결과를 timeseries로 그리는 패턴(bin 집계)의 RDS판이다.

#### 패널 id 12 · "ALB 오류 발생 추이" (timeseries, L1104–1238)

- 쿼리: 타깃 3개로 `HTTPCode_ELB_5XX_Count`(label "ALB 자체 5XX - …")·`HTTPCode_Target_5XX_Count`("애플리케이션 5XX - …")·`TargetConnectionErrorCount`("Target 연결 오류 - …")를 겹친다. 전부 Sum/60/`LoadBalancer = "*"`.
- 시각화: timeseries, `w=24,h=9,(0,45)`. id 10과 같은 계열 구성.
- 보는 이유: 상단 stat 3개(id 1–3)의 시간축 버전이자 이 대시보드의 진단 핵심 — 세 선의 상대 모양이 곧 진단이다. Target 5XX만 오르면 앱 문제, ELB 5XX+연결 오류가 같이 오르면 인프라(파드 다운·보안그룹) 문제.

#### 패널 id 13 · "비정상 Target 수 추이" (timeseries, L1242–1346)

- 쿼리: `UnHealthyHostCount`, Maximum, `LoadBalancer = "*", TargetGroup = "*"`, label "{{TargetGroup}}"(TG별 계열).
- 시각화: timeseries, `w=24,h=9,(0,54)` — 최하단. `lineInterpolation = "stepAfter"` — 이 대시보드에서 유일한 계단형 보간으로, "비정상 대수"라는 정수 상태값을 부드러운 곡선으로 왜곡하지 않고 상태 변화 그대로 그린다. min 0, legend **table**(lastNotNull/max), tooltip multi/desc, 임계값 green → 1 red.
- 보는 이유: 헬스체크 이탈의 시간 폭을 본다 — 알람(2분 연속 기준)이 놓친 1분짜리 순간 이탈도 여기엔 남으므로, 알람과 대시보드가 서로의 사각을 메우는 관계가 완성된다.

## 다룬 파일 체크리스트

| 파일 | 줄 수 | 블록 수 | 커버리지 |
|---|---|---|---|
| terraform/cloudwatch-observability.tf | 110 | 5 (module 1, data 1, resource 3) | 전체 블록 해설 완료 |
| terraform/cloudwatch-managed-metrics.tf | 143 | 7 (locals 3, data 3, module 1) | 전체 블록 해설 완료 |
| terraform/grafana.tf | 61 | 3 (module 1, output 2) + 주석 이력 1 | 전체 블록 해설 완료 |
| terraform/application-security-monitoring.tf | 175 | 7 (locals 1, resource 2, variable 4) | 전체 블록·필터 10종·알람 5종 해설 완료 |
| terraform/iam-activity-monitoring.tf | 111 | 7 (data 2, resource 4, output 1) | 전체 블록 해설 완료 |
| terraform/log-archive-subscriptions.tf | 73 | 3 (locals 1, resource 2) | 전체 블록 해설 완료 |
| terraform/module/cloudwatch-managed-metrics/main.tf | 221 | 8 (locals 1, resource 7) | 알람 7종 메트릭·통계·기간·임계값·treat_missing_data 포함 완료 |
| terraform/module/cloudwatch-managed-metrics/variables.tf | 88 | 11 (variable 11) | 전체 변수 해설 완료 |
| terraform/module/cloudwatch-managed-metrics/outputs.tf | 37 | 3 (output 3) | 전체 출력 해설 완료 |
| terraform/module/grafana/main.tf | 475 | 11 (locals 1, data 2, resource 8) | helm_release values 키별 해설 포함 완료 |
| terraform/module/grafana/variables.tf | 60 | 11 (variable 11) | 전체 변수 해설 완료 |
| terraform/module/grafana/outputs.tf | 28 | 6 (output 6) | 전체 출력 해설 완료 |
| terraform/module/grafana/dashboard.tf | 749 | 2 (data 1, locals 2개 묶음) | 패널 9/9 — 제목·쿼리·시각화·임계값·이유 해설 완료 |
| terraform/module/grafana/metrics_dashboard.tf | 1015 | 1 (locals 1) | 패널 9/9 — Metrics Insights SQL 포함 해설 완료 |
| terraform/module/grafana/aws_errors_dashboard.tf | 1348 | 1 (locals 1) | 패널 13/13 해설 완료 |


---

