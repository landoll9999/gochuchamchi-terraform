# account-baseline 계층 분리 — 실행 절차 (2026-08-07)

## 왜

`terraform destroy`가 "지워도 돈이 안 아끼는데 지우면 apply가 실패하는 것"까지 매번
건드리고 있었다. 8/4 실패 9건 중 6건이 이 그룹에서 났다.

시간당 과금 리소스는 6종뿐이고(엔드포인트·노드그룹·NAT·RDS·ALB·Redis), 나머지는
사용량 과금이라 클러스터가 꺼져 있으면 청구도 0이다. 그래서 후자를 destroy 경로에서
빼낸다.

| state | 내용 | 일일 destroy |
|---|---|---|
| `persistent/` | ECR · 서명 KMS · OIDC · 시크릿 | 안 함 |
| `account-baseline/` | **신설.** 계정 싱글턴 · 로그 아카이브 · Budgets | 안 함 |
| `terraform/` | VPC · EKS · RDS · Redis · 엔드포인트 · k8s/helm | 대상 |

참조 방향은 항상 `terraform/` → `account-baseline/` 한 방향이다. 반대 방향을 만들면
일일 운영이 다시 이 계층을 건드리게 되고 분리한 의미가 없어진다.

## 옮긴 것

**통째로** — `guardduty.tf` `security-hub.tf` `aws-config.tf` `cloudtrail.tf`
`athena.tf` `cost-monitoring.tf` `iam-security.tf`, `module/aws-config`,
`module/security-hub`

**발췌** — `ecr.tf`에서 `aws_inspector2_enabler` + `aws_ecr_registry_scanning_configuration`

**분할한 3개**

| 원본 | baseline | main에 남긴 것 |
|---|---|---|
| `cloudwatch-log-archive.tf` (628줄) | `log-archive.tf` (605줄) | `log-archive-subscriptions.tf` (46줄) — EKS 로그 그룹 배선만 |
| `flow-logs.tf` (220줄) | `flow-logs-analytics.tf` (187줄) — Glue/Athena | `flow-logs.tf` (56줄) — `aws_flow_log`만 |
| `kms.tf` (177줄) | `kms-logs.tf` — `logs` 키 | `kms.tf` — `data` 키 (RDS/EFS용) |

`log-archive`의 `cloudwatch_log_archive_sources`가 map이었는데 `each.value`를 쓰는
곳이 구독 필터 하나뿐이었다. baseline에서는 `toset(["application","control-plane"])`로
키만 남기고, 값 연결은 main이 맡는다. 이걸로 EKS 참조가 끊겼다.

main은 baseline을 **이름 고정 data source**로 참조한다 (`persistent-data.tf`와 같은
방식). `terraform_remote_state`를 쓰지 않는 이유는 state 파일을 S3에서 직접 읽어야
하는데, kim/moon 계정의 `DenySensitiveServices`가 S3를 막고 있어서다.

## 실행 절차

전 과정에서 프로파일을 먼저 고정한다. PowerShell은 호출 간 상태가 유지되지 않는다.

```powershell
$env:AWS_PROFILE = "admin"
```

### 0. import ID 추출 — **removed apply 전에**

```powershell
cd C:\terraform\go\scripts
.\generate-baseline-imports.ps1
```

`..\account-baseline\imports.tf`가 생긴다. 못 찾은 대상이 노란색으로 뜨면 거기서
멈추고 확인한다.

### 1. baseline 검증 — 여기서 틀려도 아직 피해가 없다

```powershell
cd ..\account-baseline
terraform init
terraform plan
```

**`N to import`만 있고 create/destroy가 0건**이어야 한다.
`create`가 잡히면 import ID가 틀린 것이니 2단계로 넘어가지 말 것.

### 2. main에서 관리 해제

```powershell
cd ..\terraform
terraform plan
```

**`N resources to forget`, destroy 0건** 확인 후:

```powershell
terraform apply
```

### 3. baseline이 흡수

```powershell
cd ..\account-baseline
terraform apply
```

### 4. 확인 후 정리

```powershell
terraform plan          # No changes
cd ..\terraform
terraform plan          # No changes
```

양쪽 다 깨끗하면 임시 파일 둘을 지우고 커밋한다.

```powershell
Remove-Item ..\account-baseline\imports.tf
Remove-Item .\migration-2026-08-07-removed.tf
```

## 주의점

**2와 3 사이에는 리소스가 어느 state에도 없다.** 다만 main 쪽 코드가 이미 지워져
있으므로 재생성을 시도하지 않는다. 고아로 남을 뿐이고 다시 import하면 된다.
8/4에 났던 "이미 존재하는데 또 만들려다 실패" 유형과는 다르다.

**전 과정이 끝나기 전에 다른 apply를 돌리지 말 것.** CI apply도 마찬가지라, 작업
중에는 main 브랜치 머지를 멈추는 게 안전하다.

**`state mv`를 쓰지 않는 이유.** S3 백엔드에서 state를 로컬로 뺐다가 다시 push해야
해서 3인 협업 중에 갈라질 여지가 있다. `removed` 블록은 `lifecycle { destroy = false }`
때문에 구조적으로 destroy가 불가능하고, plan에서 검토되며 git에 남는다.

특히 이 셋이 destroy되면 곤란하다:

- `aws_inspector2_enabler` — destroy가 15분 타임아웃 후 tainted로 남는다 (8/4 §5.2)
- `module.aws_config` — 레코더 재생성이 구성 항목 수천 건을 다시 기록한다 ($0.003/건)
- `aws_s3_bucket.cloudwatch_log_archive` — Object Lock COMPLIANCE라 애초에 못 지운다 (8/4 §5.5)

## CI — 이 계층은 plan까지만 (2026-08-07 확정)

`.github/workflows/terraform-account-baseline.yml`에 **apply job을 두지 않는다.**

| job | 트리거 | AWS 자격증명 | 상태 |
|---|---|---|---|
| `static-check` (fmt · `init -backend=false` · validate) | PR | 불필요 | 즉시 동작 |
| `plan` + destroy 가드 + PR 코멘트 | PR | plan 전용 롤 | `vars.AWS_TF_PLAN_ROLE_ARN` 등록 전까지 자동 skip |
| `apply` | — | — | **없음. 로컬 admin 전용** |

**왜:**

- `cloudwatch_log_archive_admin_arns`를 비워두면 apply 실행 주체 ARN이 불변성
  Deny의 예외로 들어간다. 로컬 admin과 CI 롤이 번갈아 apply하면 버킷 정책이
  매번 뒤집힌다(perpetual diff). apply 주체를 로컬 admin 하나로 고정하면
  구조적으로 사라진다.
- 이 계층은 CloudTrail/GuardDuty/Config/Object Lock 버킷 등 계정 싱글턴이라
  영향 범위가 계정 전체다. MFA 걸린 admin이 plan을 읽고 apply하는 것 자체를
  통제 수단으로 삼고, CI에는 plan 가시성만 준다.
- plan 롤(`gochuchamchi-terraform-plan`)은 아직 없다. 2차 작업에서 `persistent/`에
  만들고 레포 variable만 등록하면 코드 수정 없이 plan job이 살아난다.

## 이 다음

이번 범위에 넣지 않은 것들이 남아 있다.

- `dr.tf` (백업 볼트 서울/도쿄 + DR 버킷) — 보고서상 "상시 유지"인데 백업 플랜이
  `module.rds`와 `aws_efs_file_system.this`의 ARN을 대상으로 잡고 있어 배선 설계가 필요하다
- `efs.tf` + `aws_kms_key.data` — 재생성 시 데이터 소실. 지금은 main에 있다
- `s3.tf` images 버킷 — 앱 데이터라 성격이 다르다
