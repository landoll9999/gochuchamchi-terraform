# 2026-08-04 복구 후 재점검 — 하드코딩 인벤토리 + 보안 리뷰

> 장애 5건의 전말·복구 과정은 `2026-08-04.md` **§4**에 기록돼 있다. 이 문서는
> 복구 확인 후 별도 세션에서 수행한 **저장소 전체 하드코딩/보안 재점검** 결과다.

## 0. 장애 원인 한 줄 요약 + 복구 확인

`2026-08-04.md` §4가 개별 원인 5건을 다루지만, 근본 원인은 하나로 요약된다:
**terraform apply와 gitops 수정이 한 세트인 작업(제로트러스트 전환)에서 gitops
쪽이 누락된 채 apply만 실행됨** — 기존 파드는 평문 접속이 거부되고(500), 새 파드는
삭제된 Secret을 참조해 못 뜨는(CreateContainerConfigError) 이중 잠김 상태였다.

**교훈**: "apply 전 체크리스트"가 문서에 있어도 강제 장치가 없으면 누락된다.
terraform 변경과 gitops 변경이 결합된 작업은 한 PR/한 사람이 원자적으로 처리할 것.

복구 확인 (별도 세션에서 외부 검증):

- `/api/health` 500 → **302**(로그인 리다이렉트, 정상), 메인 200
- terraform 저장소 로컬 클론 == origin/main (작업 컴퓨터 간 드리프트 없음)

---

## 1. 하드코딩 인벤토리 (전체 .tf 스캔)

### 🔴 실질 리스크 — 개선 후보

| 항목 | 위치 | 리스크 | 대안 |
|------|------|--------|------|
| AMI ID `ami-0f93dc65265863858` | `variables.tf` (bastion_ami/nat_ami) | 서울 리전 전용 + AL2023 이미지는 주기적 deprecated → **수개월 뒤 재구축 시 "AMI not found"** | `data "aws_ssm_parameter"` `/aws/service/ami-amazon-linux-latest/al2023-...` 조회. 단 latest 추적 시 AMI 갱신마다 인스턴스 재생성 발생 — 특정 버전 파라미터로 핀 고정이 절충안 |
| tfstate 버킷+프로파일 | `backend.tf` ×3 스택 (`gochuchamchi-tfstate-<계정ID>`, `profile="admin"`) | 계정 ID 종속 — 타 계정 재구축 시 3개 파일 수동 수정 | backend 블록은 변수 불가(TF 제약). `terraform init -backend-config=<env>.hcl` 주입 방식으로 전환 가능. 계정 이전 계획 없으면 유지 |
| Secret 이름 문자열 계약 | `gochuchamchi/discord/cloudwatch-webhook` 등 3개 — 여러 스택에 문자열로 산재 | 한쪽에서 이름 변경 시 다른 스택이 조용히 깨짐 | 현 규모에선 관리 가능. 이름 변경 시 전체 grep 필수라는 점만 인지 |

### 🟡 의도적 하드코딩 (문서화됨 — 유지하되 관리 필요)

- **접속 허용 IP `/32` 목록** (`endpoint_public_access_cidrs`) — 보안 절충으로 선택.
  유동 IP는 재할당되므로 **안 쓰는 항목 즉시 삭제** 원칙 준수 (variables.tf 주석).
- **버전 핀** — EKS 1.35, MariaDB 10.11, Redis 7.1, Grafana chart 12.8.0,
  python3.12. 하드코딩이 아니라 올바른 버전 고정 관행 → 유지.

### 🟢 하드코딩이 정답인 것

- VPC CIDR/서브넷(`172.30.0.0/16` 등) — 네트워크 설계 상수
- `169.254.170.23/32` — EKS Pod Identity Agent link-local, **AWS 고정값** (변수화 금지)
- NetworkPolicy/SG의 `0.0.0.0/0` egress — 의미 있는 설계값
- 도메인·GitHub owner — 이미 변수 default로 분리 완료
- S3 버킷명 — `account_id` 동적 참조로 모범 처리 (`s3.tf`)

---

## 2. 보안 재점검 결과

### 🔴 신규 발견 — 조치 권장

**① `.gitignore` 부분 보강 (조치 완료 — 초기 판정 정정 포함)**

> **정정**: 최초 리뷰에서 루트 `.gitignore`(`.claude/` 한 줄)만 보고 "사실상 비어
> 있음"으로 판정했으나, **`go/.gitignore`에 tfstate/.terraform/pem/plan 규칙이
> 이미 잘 갖춰져 있었음**을 후속 작업 중 확인. tfstate 유출 위험은 당초 보고보다
> 낮았다. 다만 실제 갭 2건은 유효했고 조치함:

- **`*.tfvars` 규칙 부재** (go/.gitignore에도 없었음) — 주입 변수 파일에 이메일 등
  개인정보가 들어갈 수 있음 → 루트 `.gitignore`에 추가 (완료)
- **Lambda zip이 git 추적 중** (`cloudwatch-discord.zip`) — 시크릿은 아니나
  apply마다 재생성되는 빌드 산출물 → `*.zip` 규칙 추가 (완료),
  기존 추적분은 `git rm --cached go/cloudwatch-notifications/cloudwatch-discord.zip` 필요
- 루트에도 tfstate/.terraform 규칙을 이중 방어로 추가 + 깨진 인코딩(CP949) UTF-8 재저장 (완료)

**② Grafana admin 비밀번호가 tfstate에 평문 (2순위, apply 필요)**

`module/grafana/admin-password.tf`의 `data "kubernetes_secret_v1"` +
`output "admin_password"` 조합. `sensitive=true`는 **CLI 출력만 가릴 뿐 state에는
평문 저장** — 감사 #1이 정의한 ESO 트리거에 해당하는 값이 잔존.
→ data source·output 제거, 필요 시 runbook 방식(`kubectl -n monitoring get secret grafana ...`)으로 조회.

### 🟡 알고 있는 잔존 리스크 (문서화된 절충 — 현상 유지)

- Redis `auth_token`이 state에 있음 — 리소스 인자라 구조적 불가피 (redis.tf 주석)
- S3 이미지 버킷 퍼블릭 읽기 — 감사 #4 의도적 유지. 운영 전환 시 CloudFront+OAC
- EKS 퍼블릭 엔드포인트 + /32 제한 — 감사 #3 절충. IP 목록 주기 점검

### 🟢 점검 결과 문제없음 (확인 완료)

- **IAM `Resource="*"` 전수 확인** — 모두 정당: `ecr:GetAuthorizationToken`(리소스
  지정 불가), `eks:DescribeCluster`, Grafana CloudWatch 읽기(리소스 레벨 미지원).
  `Principal="*"`는 전부 **Deny**문(DenyInsecureTransport) — 보안 강화 패턴
- **SG 설계** — 전부 SG 참조 기반, 배스천 인바운드 0(SSM 전용), DB/캐시 egress 제거.
  NAT만 VPC CIDR 인그레스(기능상 필수)
- **배스천 권한** — EKS는 `gochuchamchi` 네임스페이스 Edit로, Secrets Manager는
  시크릿 2개 ARN 단위로 축소돼 있음
- **시크릿 전달 규칙** — MYSQL_PWD/env/600 파일 원칙 일관 적용 (argv·SSM 로그 노출 차단)

---

## 3. 알림 자동화 — SNS 허브 도입 (`cloudwatch-notifications/`)

기존 `EventBridge → Lambda → Discord` 직결 구조를 `EventBridge → SNS 허브 →
(Lambda→Discord | 이메일)` 팬아웃 구조로 개편:

- `sns.tf`(신규): 토픽 `gochuchamchi-alerts` + EventBridge 전용 최소권한 토픽 정책
  + Lambda 구독(**SQS DLQ** 연결, 14일 보존) + 이메일 구독(`var.alert_emails`,
  형식 검증) + **DLQ 감시 알람**(`gochuchamchi-` prefix라 기존 룰에 자동 포착 —
  Discord가 죽어도 이메일로 "파이프라인 고장"이 통보되는 자기 감시 루프)
- `lambda_function.py`: SNS 봉투 해제(`unwrap_events`) — 직접 호출 테스트도 지원
- apply 시: `$env:TF_VAR_alert_emails = '["<주소>"]'` 주입, apply 후 확인 메일의
  Confirm 클릭 필요 (3일 내 미클릭 시 만료)

---

## 4. full-HA 라인(8/3, fin) 복원 + 현재 코드와 병합

### 배경

CloudFront/WAF 부재를 확인하는 과정에서, 8/3 "full HA security upgrade" 라인의
**13개 파일이 저장소 재생성(8/4 first commit) 때 통째로 누락**된 것을 발견.
`Desktop\3pro\fin` 사본에서 복원해 8/4 제로트러스트 작업과 3-way 병합함.
`terraform validate` 통과 확인.

### 복원된 파일 (11개 신규)

| 파일 | 내용 | 비고 |
|---|---|---|
| `edge.tf` | CloudFront + WAFv2(관리형 룰 3종 + rate limit) + us-east-1 ACM + Route53 전환 + ALB SG 잠금 | **2단계 apply**: 1차 기본 → 2차 `-var enable_edge=true` |
| `iam-security.tf` | Access Analyzer + MFA 강제 그룹 + Region Guard | ⚠️ Terraform 실행 계정을 그룹에 넣지 말 것 (07/29 사고 유형) |
| `kms.tf` | 로그/데이터 CMK 2개 + 키 정책 | RDS/EFS wiring은 파괴적이라 보류 (아래) |
| `nacl.tf` | database 서브넷 커스텀 NACL | |
| `vpc-endpoints.tf` | 인터페이스 엔드포인트 7종 (ECR/SSM/Secrets/Logs) | 비용 주의 — 파일 주석 참고 |
| `flow-logs.tf` | VPC Flow Logs → 중앙 S3 + Athena 테이블/조사 쿼리 3종 | |
| `cost-monitoring.tf` | Budgets(월 $350, 80%/예측100%) + Cost Anomaly Detection | 이메일 default 하드코딩 잔존(fin 그대로) |
| `kyverno.tf` | Kyverno + restricted Audit 정책 | |
| `resource-limits.tf` | LimitRange + ResourceQuota | |
| `dr.tf` | AWS Backup(도쿄 크로스리전) + S3 CRR | `enable_dr=true` 기본 |
| `aws-config.tf` (교체) | Config 전용 버킷 분리(불변성 통제와의 충돌 해소 — fin의 8/3 실장애 교훈) + module에 KMS 지원 | |

**복원 안 한 것 (사유)**: `network-policies.tf`(→ 8/4 `k8s-network-policies.tf`가 대체),
`sns-alerts.tf`(→ §3 SNS 허브가 상위 호환), `github-oidc.tf`(repo `ecr.tf`의 OIDC와
**중복 — fin 자체 버그**로 판단, 같은 URL의 provider는 계정당 1개만 가능)

### 공통 파일에 이식된 변경

- `main.tf`: **NAT AZ별 2대** (count + `moved` 블록으로 기존 1대 무중단 인수 + auto_recovery)
- `k8s-deploy.tf`: **PSA 라벨**(enforce=baseline, warn/audit=restricted) +
  `APP_SUPERADMIN_USERNAME` + enable_edge 시 ingress 어노테이션(ExternalDNS
  annotation-only + CloudFront 전용 SG)
- `s3.tf`: 이미지 버킷 versioning + 라이프사이클(CRR 전제)
- `ecr.tf`: **Inspector ENHANCED 스캔** (OS+언어 패키지, 15일 무료 후 과금)
- `guardduty.tf`: 기능 확장 병합 — EKS 감사/S3 이벤트/EBS 말웨어 + 15분 주기 +
  런타임 모니터링(옵트인 변수)
- `cloudwatch-log-archive.tf`: SSE를 **로그 CMK**로 전환(in-place) + Flow Logs
  전달 정책 + **DenyObjectDeletion/DenyPolicyTampering**(로그 불변성)
- `variables.tf`: 복원 변수 9개 (enable_edge, waf_rate_limit, console_admin_users,
  allowed_regions, enable_dr, dr_retention, guardduty_runtime, superadmin, pss_enforce)
- `grafana.tf` + `module/grafana`: **admin 비밀번호 state 평문 제거** (§2-② 조치 —
  fin 모듈엔 data source가 애초에 없었음, 그 버전으로 복원)
- 각종 outputs 복원 (cloudtrail/athena/security-hub/dns/s3)

### 의도적으로 보류한 것 (다음 전체 재구축 사이클에)

| 항목 | 이유 |
|---|---|
| RDS/EFS `kms_key_id` (CMK 전환) | **인스턴스/파일시스템 교체 유발 → 데이터 소실** (fin 자체 경고). efs.tf에 주석으로 표시 |
| 중앙 로그 버킷 Object Lock | 생성 시점에만 활성화 가능 → 기존 버킷 교체 유발 |
| fin의 구식 부분 전체 | key_name(B2로 제거됨), argocd_git_pat(B3 ESO), 배스천 ClusterAdmin(제로트러스트로 축소됨), DB 마스터 접속(제로트러스트), 구 elasticache_cluster 등 — **8/4 코드가 우선** |

### ⚠️ apply 시 주의 (옆컴퓨터)

1. `terraform init` 필요 (모듈/프로바이더 추가)
2. plan에서 **다수의 신규 리소스**(edge WAF/ACM, KMS 2개, NACL, VPCE 7종, Flow Logs,
   Backup 볼트/도쿄 리소스, Inspector, Kyverno 등) + NAT `nat-0` 생성 확인.
   **RDS/EFS/로그 버킷에 replace가 뜨면 중단하고 원인 확인** (보류 항목이 새면 안 됨)
3. `DenyPolicyTampering` 적용 후에는 **이 버킷 정책을 Terraform으로도 수정 불가** —
   루트 사용자의 DeleteBucketPolicy → 재apply가 유일한 변경 경로
4. CloudFront는 2차 apply(`-var enable_edge=true`)에서 활성화. 전환 후
   `curl -sI https://gochuchamchi.shop | grep -i via` 로 CloudFront 경유 확인
5. `aws iam list-open-id-connect-providers`로 기존 OIDC provider 충돌 여부 사전 확인

---

## 5. 남은 작업

- [x] **`.gitignore` 보강** (§2-①) — `*.tfvars`/`*.zip` 추가 + 루트 이중 방어 (같은 날 완료)
- [x] Grafana admin 비밀번호 state 제거 (§2-②) — **코드 완료** (§4), apply 대기
- [x] SNS 알림 허브 (§3) — **코드 완료**, apply 대기
- [x] full-HA 13파일 복원·병합 (§4) — **코드 완료**, apply 대기 (2단계 apply)
- [ ] `git rm --cached go/cloudwatch-notifications/cloudwatch-discord.zip` — 추적 중인 빌드 산출물 해제
- [ ] AMI ID → SSM 파라미터 조회 전환 검토 (§1)
- [ ] MTU 1492 (8/3 잔여 — 다음 apply 전 미적용 시 `Error locating chart` 재발 가능)
- [ ] (재구축 사이클) RDS/EFS CMK 전환 + 로그 버킷 Object Lock (§4 보류 항목)
- [ ] (백로그) 이미지 태그 자동화 — plain YAML gitops에선 Image Updater git write-back이
      반영 안 됨(Kustomize/Helm 소스만 지원). 대안: gitops에 `kustomization.yaml` 추가
      또는 CI(gochuchamchi-spring Actions)가 직접 gitops 태그 커밋. 후자는 클러스터의
      write PAT를 read-only로 강등할 수 있어 보안상 우위 (감사 "최고가치 시크릿" 축소)
- [ ] (백로그) `cost-monitoring.tf` 이메일 default 하드코딩 → 변수 주입 방식 정리
