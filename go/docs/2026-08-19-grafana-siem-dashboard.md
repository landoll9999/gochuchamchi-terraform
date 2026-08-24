# Grafana SIEM 대시보드 — Athena 통합 검색 + 실시간 사용자 활동

**작성일** 2026-08-19 · **대상 스택** `go/log-archive`(Log 계정) + `go/terraform`(Workload 계정)
**상태** 코드 작성 완료, 정적 검사 10회 통과, **apply 전**

---

## 1. 무엇이 없어서 만들었나

탐지는 이미 있었다(2026-08-12). 없던 것은 **그것을 보는 자리**다.

| 층 | 이전 | 지금 |
|---|---|---|
| 수집 | ✅ 7개 소스 → 중앙 S3 | 그대로 |
| 정규화 | ✅ `security_events` 8필드 공통 스키마 | 그대로 |
| 탐지 | ✅ 상관 룰 4종 + Groq 판정 | 그대로 |
| 알림 | ✅ SNS → Discord + 이메일 | 그대로 |
| **조사 화면** | ❌ Athena 콘솔에서 저장 쿼리 수동 실행 | ✅ Grafana 통합 검색 |
| **관제 화면** | ❌ CloudWatch 대시보드만 | ✅ 웹/DB/Redis 3계층 실시간 |
| **Redis 로그** | ❌ 아예 없었음 | ✅ slow-log·engine-log + 인증 실패 알람 |

현업이 "SIEM이 없다"고 한 것의 실체가 이것이다 — 기능이 아니라 화면이 없었다.
`module/grafana/main.tf`의 데이터소스에 CloudWatch만 등록되어 있어, Log 계정의
통합 뷰가 Grafana에서 보이지 않는 상태였다.

---

## 2. 배선

```
[Workload 828885965304]                    [Log 564186750363]

 Grafana (EKS/monitoring)
   │
   ├─ CloudWatch 데이터소스 ──── 초 단위 ──→ 앱/RDS/Redis 로그 그룹
   │                                          (같은 계정)
   │
   └─ Athena 데이터소스
        │ sts:AssumeRole
        ▼
      gochuchamchi-grafana-athena-reader ──→ Athena 워크그룹
                                              gochuchamchi-security-logs
                                                  │
                                                  ▼
                                              security_events (7소스 정규화 뷰)
```

**화면을 둘로 나눈 것이 이 설계의 전부다.** 지연이 다르기 때문이다.

- `04` 조사 — S3 적재분(5~15분 지연). 소스 간 상관을 볼 수 있다
- `05` 관제 — CloudWatch(초 단위). 상관은 못 보지만 "지금"에 답한다

한 화면에 섞으면 "왜 여기엔 있고 저기엔 없지"로 혼란에 빠진다.

---

## 3. 추가/변경된 것

| 파일 | 내용 |
|---|---|
| `log-archive/grafana-athena-access.tf` | **신규** — Grafana 조회 전용 cross-account 역할 |
| `terraform/redis.tf` | **변경** — slow-log/engine-log 전달 + 인증 실패·연결 급증 알람 |
| `terraform/redis-variables.tf` | **신규** — 보존 기간, 연결 수 임계값 |
| `terraform/module/grafana/siem_dashboards.tf` | **신규** — 04 통합 검색(Athena) |
| `terraform/module/grafana/siem_realtime_dashboard.tf` | **신규** — 05 실시간 사용자 활동 |
| `terraform/module/grafana/main.tf` | **변경** — AssumeRole 권한, 플러그인, 데이터소스, 대시보드 등록 |
| `terraform/module/grafana/variables.tf` | **변경** — `athena_reader_role_arn` 추가 |
| `terraform/grafana.tf` · `terraform/variables.tf` | **변경** — 역할 ARN 전달 |

### 3-1. 왜 조회 전용 역할을 따로 파나

`log-archive/providers.tf`가 *"Workload나 Management에서 이 계정의 관리자 역할을
AssumeRole하는 신뢰 경로를 만들지 않는다"*고 못박고 있다. 그 원칙을 지키면서
조회만 열려면 관리자와 무관한 별도 역할이 필요하다.

신뢰 대상을 **계정 루트가 아니라 역할 ARN 하나**로 한정한 이유: 워크로드 계정
전체를 신뢰하면 침해 가정 하에서 앱 파드 역할도 중앙 로그를 읽을 수 있게 된다.

### 3-2. 역할 이름 제약

이름이 반드시 `gochuchamchi-` 로 시작해야 한다. `kms-logs.tf`의
`AllowProjectRoles`가 `aws:PrincipalArn StringLike role/gochuchamchi-*` 조건을
걸고 있어서, 이름을 바꾸면 IAM에 `kms:Decrypt`가 있어도 **키 정책에서 막힌다.**
`siem-detector.tf`가 같은 이유로 같은 제약을 진다.

### 3-3. Redis — 없는 로그를 만드는 것이 아니라 우회하는 것

ElastiCache Redis는 **접속·명령 감사 로그를 제공하지 않는다.** 상용 SIEM을
붙여도 없는 로그는 못 본다. 그래서 관측 가능한 세 축을 켰다.

1. `engine-log` — 페일오버·재시작·설정 변경
2. `slow-log` — 임계 초과 명령. `KEYS *` 같은 대량 스캔의 흔적이 여기 남는다.
   감사 로그가 없는 환경에서 이상 사용을 잡는 사실상 유일한 로그 축이다
3. `AuthenticationFailures` 지표 — SG가 EKS 노드만 허용하므로, 값이 오르면
   **이미 노드 안에 있는 무언가가 잘못된 토큰으로 붙으려 한 것**이다.
   `auth_token`을 건 시나리오(측면이동)의 직접 증거이고, 그래서 임계값이 1이다

최종 사용자 단위 추적은 이 로그가 아니라 앱의 세션 이벤트를 봐야 한다.

### 3-4. 04는 자동 새로고침을 켜지 않는다

워크그룹에 쿼리당 1 GiB 스캔 상한이 걸려 있다(`athena.tf`). refresh를 켜면
**대시보드를 열어둔 것만으로 스캔이 반복된다.** 대신 Athena result reuse(5분)를
켜서 같은 쿼리 재실행은 과금 없이 캐시에서 온다. 05는 CloudWatch라 무관하다.

---
## 4. apply 순서 — 반드시 Log 계정 먼저

역할이 먼저 있어야 워크로드 쪽에서 그 ARN을 참조할 수 있습니다.

### 2-1. Log 계정

```powershell
cd C:\terraform\go\log-archive
terraform plan
terraform apply

# 워크로드 쪽에 넣을 값
terraform output grafana_reader_role_arn
terraform output grafana_athena_datasource_settings
```

### 2-2. 워크로드 계정

`terraform.tfvars`에 앞 단계 output을 넣습니다.

```hcl
grafana_athena_reader_role_arn = "arn:aws:iam::564186750363:role/gochuchamchi-grafana-athena-reader"
```

```powershell
cd C:\terraform\go\terraform
terraform plan
terraform apply
```

> **Redis 변경 주의** — `log_delivery_configuration` 추가는 클러스터 수정 작업입니다.
> `apply_immediately = true`라 즉시 반영되고, 그 사이 **세션이 초기화되어 사용자가
> 재로그인해야 할 수 있습니다.** 시연 직전에는 돌리지 마세요.

---

## 5. 검증

### 3-1. 역할 전환이 되는가 (가장 흔한 실패 지점)

```powershell
# 워크로드 계정 자격증명으로
aws sts assume-role `
  --role-arn arn:aws:iam::564186750363:role/gochuchamchi-grafana-athena-reader `
  --role-session-name test --profile workload-admin
```

`AccessDenied`가 나면 양쪽 중 하나가 빠진 것입니다.

- Log 계정 신뢰 정책에 워크로드 역할 ARN이 맞게 들어갔는가 (`grafana_workload_role_name` 기본값 `gochuchamchi-eks-grafana-cloudwatch`)
- 워크로드 역할에 `sts:AssumeRole` 스테이트먼트가 붙었는가 (PATCH ②)

### 3-2. Grafana 파드

```powershell
kubectl -n monitoring get pods
kubectl -n monitoring logs deploy/grafana | Select-String -Pattern "athena|plugin|error"
```

플러그인 다운로드 실패가 보이면 노드 아웃바운드를 확인하세요.

### 3-3. 데이터소스

Grafana > Connections > Data sources > **Athena (Security Logs)** > Save & test.

실패 시 대표 원인:

| 증상 | 원인 |
|---|---|
| `AccessDenied` on `athena:StartQueryExecution` | 3-1 실패. 역할 전환 문제 |
| `Table not found: security_events` | 뷰 미생성. 저장 쿼리 `00-create-security-events-view` 실행 또는 siem-detector Lambda 1회 수동 실행 |
| `bytes scanned limit exceeded` | 조회 기간을 줄일 것. 워크그룹 상한 1 GiB |

### 3-4. 대시보드

- **04 SIEM 통합 검색** — 기간 24시간, 소스 전체로 두고 결과가 나오는지
- **05 실시간 사용자 활동** — 웹에 한 번 접속한 뒤 "현재 활동 중인 사용자"에 뜨는지

Redis slow-log 패널은 느린 명령이 없으면 **정상적으로 비어 있습니다.**
확인하려면 임시로 임계값을 낮추거나 무거운 명령을 한 번 날려 보세요.

---

## 6. 남은 한계 (보고서에 적을 것)

이 작업으로 채워지는 것과 아닌 것을 구분해 두는 편이 발표에서 유리합니다.

| 항목 | 상태 |
|---|---|
| 7개 소스 통합 검색 | ✅ 이번 작업 |
| 실시간 사용자 활동 (웹서버) | ✅ 최종 사용자까지 식별 |
| 실시간 DB 접속 | ⚠️ 커넥션 풀 계정 단위. 최종 사용자 불가 |
| 실시간 Redis 접속 | ⚠️ ElastiCache가 접속 감사 로그를 제공하지 않음. 지표·slow-log로 대체 |
| 증적 CSV 내보내기 | ✅ 패널 Inspect > Data > Download CSV |
| 소스 간 상관 탐지 | ✅ 기존 SIEM 파이프라인 (1시간 주기) |
| 룰 간 상관 / 리스크 스코어 | ❌ 미구현 |
| 케이스 관리 | ❌ 미구현 |

> **DB·Redis의 ⚠️는 도구의 한계가 아니라 로그 소스의 한계입니다.** 상용 SIEM을
> 도입해도 동일합니다 — 없는 로그는 어떤 제품도 못 봅니다. 이 문장을 보고서에
> 그대로 넣어 두면 "왜 완전하지 않냐"는 질문이 설계 이해도를 보여주는 답으로 바뀝니다.

---

## 7. 롤백

```hcl
# log-archive/terraform.tfvars
grafana_reader_enabled = false     # 조회 역할 제거 (Grafana의 Athena 패널만 죽음)
```

```hcl
# terraform/terraform.tfvars
grafana_athena_reader_role_arn = ""   # 데이터소스 미등록. CloudWatch 화면은 그대로 동작
```

Redis 로그를 되돌리려면 `redis.tf`의 `log_delivery_configuration` 두 블록을 제거하고
apply합니다. 로그 그룹은 남으므로 필요하면 따로 삭제하세요.

---

## 8. 부록. 오류 검사 기록 (10회, 2026-08-19)

| 회차 | 관점 | 결과 |
|---|---|---|
| 1 | HCL 파싱 | 통과 (5/5) |
| 2 | variable 중복 선언 | 통과 — 기존 스택과 충돌 없음 |
| 3 | locals / resource / output 이름 충돌 | 통과 |
| 4 | 참조 해결 (var·local·resource·module) | 통과 (오탐 3건 확인) |
| 5 | 대시보드 패널 구조 (id·gridPos·uid) | 통과 (13패널) |
| 6 | Glue 테이블 ↔ IAM 버킷 커버리지 | **결함 1 발견 → 수정** |
| 7 | KMS 키 정책 조건 | 조건부 통과 → 제약 명시 |
| 8 | Grafana 변수 → SQL 렌더링 | **결함 2 발견 → 수정** |
| 9 | CloudWatch Logs Insights 구문 | 통과 (개선 2건 반영) |
| 10 | AWS 프로바이더 인자 유효성 | 통과 |

### 결함 1 — ALB 액세스 로그 버킷 권한 누락 (6회차)

`security_events` 뷰의 7개 소스 중 **`alb` 분기만 다른 버킷**을 본다.

```
cloudtrail / vpc_flow / waf / application / rds / eks → aws_s3_bucket.cloudwatch_log_archive
alb                                                   → aws_s3_bucket.alb_access_logs
```

초기 IAM 정책이 중앙 아카이브 버킷만 허용해 `alb` 행에서 AccessDenied가 나고,
뷰가 `UNION ALL`이라 **쿼리 전체가 실패**한다. 두 버킷 모두 허용하도록 수정했다.

> **같은 결함이 기존 `siem-detector.tf`에도 있습니다.** 그 Lambda의 `ReadCentralLogs`
> 스테이트먼트 역시 `cloudwatch_log_archive`만 허용하는데, 탐지용 뷰
> `security_events_recent`의 소스에 `alb`가 포함되어 있습니다.
> 즉 **탐지 룰 4종이 전부 실패하고 있을 가능성**이 있습니다.
> `CloudWatch > Metrics > Gochuchamchi/SIEM > RuleQueryFailures`가 0이 아닌지
> 확인하세요. 0이 아니면 `siem-detector.tf`의 해당 스테이트먼트에
> `aws_s3_bucket.alb_access_logs` 두 ARN을 추가해야 합니다.

### 결함 2 — SQL 문자열 이스케이프 (8회차)

검색 키워드 변수를 `'$${q}'` 형태로 직접 감싸고 있었다. 검색어에 아포스트로피가
하나만 들어가도(`O'Brien`, `can't`) 쿼리가 깨진다.

Grafana 포맷 지정자를 `:sqlstring`으로 교체했다. `:singlequote`는 `\'`로
이스케이프하는데 **Trino(Athena)는 `''`를 쓰기 때문에** 이쪽이 정답이다.

```sql
-- before:  AND ('${q}' = '' OR ... LIKE lower('%${q}%'))
-- after:   AND (${q:sqlstring} = '' OR ... LIKE lower(concat('%', ${q:sqlstring}, '%')))
```

### 그 외 반영

- **IAM 역할 이름 제약 명시** — `kms-logs.tf`의 `AllowProjectRoles`가
  `role/gochuchamchi-*`를 조건으로 걸고 있어, 역할 이름을 바꾸면 IAM에
  `kms:Decrypt`가 있어도 키 정책에서 막힌다. 주석으로 못박았다.
- **버킷 레벨 액션 ARN 정정** — `s3:GetBucketLocation`·`s3:ListBucket`이
  객체 ARN(`.../results/*`)에 걸려 있어 인가되지 않았다. 버킷 ARN을 함께 부여.
- **CWLI 별칭 `user` → `actor_name`** — 예약어 충돌 회피.
- **집계 타임스탬프 표시** — `max(@timestamp)`는 숫자(epoch ms)로 반환되므로
  필드 오버라이드로 시간 형식을 지정.

### 검사로 확인되지 않는 것

정적 검사의 한계이며, 실제 환경에서만 드러납니다.

- `terraform plan`의 provider 스키마 검증 (자격증명 필요)
- Grafana가 대시보드 JSON을 실제로 렌더링하는지
- Athena 플러그인의 `assumeRoleArn` 동작 (Pod Identity 자격증명 체인)
- CWLI 쿼리가 실제 로그 형태와 맞는지 (특히 `log_processed` 래핑 여부)

---

## 9. `module/grafana/main.tf` 수정 4곳

새 파일 2개(`siem_dashboards.tf`, `siem_realtime_dashboard.tf`)를 같은 모듈 폴더에 넣은 뒤,
기존 `main.tf`에 아래 네 곳을 반영합니다. 순서대로 하면 됩니다.

---

## ① `variables.tf`에 변수 추가

```hcl
variable "athena_reader_role_arn" {
  description = <<-EOT
    Log 계정의 Grafana 조회 전용 역할 ARN.
    log-archive 스택의 output `grafana_reader_role_arn` 값을 넣는다.
    비워 두면 Athena 데이터소스가 등록되지 않고 CloudWatch만 동작한다 —
    log-archive apply 전에도 이 모듈이 깨지지 않게 하기 위한 기본값이다.
  EOT
  type        = string
  default     = ""
}
```

---

## ② IAM 정책에 `sts:AssumeRole` 추가

`data "aws_iam_policy_document" "grafana_cloudwatch"` 블록 **안**, 마지막 statement 뒤에
아래를 추가합니다.

```hcl
  # ---------------------------------------------------------------------------
  # (2026-08-19) Log 계정 조회 역할 전환
  #
  # Grafana 파드는 워크로드 계정에 있고 통합 로그 뷰(security_events)는 Log 계정에
  # 있다. 파드가 그 뷰를 보려면 Log 계정 역할로 전환해야 한다.
  #
  # 대상을 특정 ARN 하나로 못박는다. Resource = "*"로 두면 이 파드가 신뢰 관계만
  # 맞으면 어떤 역할로도 전환할 수 있게 되는데, 그건 대시보드 도구에 줄 권한이 아니다.
  # ---------------------------------------------------------------------------
  dynamic "statement" {
    for_each = trimspace(var.athena_reader_role_arn) != "" ? [1] : []

    content {
      sid    = "AssumeLogAccountReaderRole"
      effect = "Allow"

      actions = ["sts:AssumeRole"]

      resources = [var.athena_reader_role_arn]
    }
  }
```

---

## ③ Helm values — 플러그인 설치 + Athena 데이터소스

`helm_release.grafana`의 `values`에서 두 곳을 고칩니다.

**(a) `env` 블록 바로 위에 플러그인 설치 지시 추가**

```hcl
      # Athena 데이터소스는 기본 번들에 없으므로 시작 시 설치한다.
      # 서명된 공식 플러그인이라 allow_loading_unsigned_plugins 설정은 필요 없다.
      plugins = [
        "grafana-athena-datasource"
      ]
```

> ⚠️ 파드가 뜰 때 grafana.com에서 플러그인을 내려받습니다. 노드에 아웃바운드가
> 막혀 있으면 `atomic = true` 때문에 helm_release 전체가 롤백됩니다.
> 그런 환경이면 `GF_INSTALL_PLUGINS` 대신 initContainer로 미리 넣어야 합니다.

**(b) `datasources` 블록의 `datasources` 리스트를 아래로 교체**

```hcl
      datasources = {
        "datasources.yaml" = {
          apiVersion = 1

          datasources = concat(
            [
              {
                name      = "CloudWatch"
                uid       = "cloudwatch"
                type      = "cloudwatch"
                access    = "proxy"
                isDefault = true
                editable  = false

                jsonData = {
                  authType                = "default"
                  defaultRegion           = var.region
                  customMetricsNamespaces = "ContainerInsights"
                }
              }
            ],

            # Log 계정 역할 ARN이 주어졌을 때만 Athena를 등록한다.
            # 값이 없는데 등록하면 파드는 뜨지만 모든 패널이 인증 오류를 뱉어서
            # "대시보드가 깨졌다"로 보인다 — 아예 없는 편이 진단하기 쉽다.
            trimspace(var.athena_reader_role_arn) != "" ? [
              {
                name      = "Athena (Security Logs)"
                uid       = "athena"
                type      = "grafana-athena-datasource"
                access    = "proxy"
                isDefault = false
                editable  = false

                jsonData = {
                  authType      = "default"
                  defaultRegion = var.region

                  # 파드 자격증명 -> Log 계정 조회 역할로 전환
                  assumeRoleArn = var.athena_reader_role_arn

                  catalog   = var.athena_catalog
                  database  = var.athena_database
                  workgroup = "gochuchamchi-security-logs"

                  # 워크그룹에 enforce_workgroup_configuration = true가 걸려 있어
                  # 실제 출력 위치는 워크그룹 설정이 이긴다. 여기 값은 UI 표시용.
                  outputLocation = ""
                }
              }
            ] : []
          )
        }
      }
```

---

## ④ 대시보드 등록

`dashboards` 블록에 두 줄을 추가합니다.

```hcl
      dashboards = {
        gochuchamchi = {
          "01-service-dependencies" = {
            json = local.aws_errors_dashboard
          }

          "02-platform-health" = {
            json = local.eks_health_dashboard
          }

          "03-application-logs" = {
            json = local.eks_logs_dashboard
          }

          # (2026-08-19) SIEM 화면 — siem_dashboards.tf / siem_realtime_dashboard.tf
          "04-siem-search" = {
            json = local.siem_search_dashboard
          }

          "05-siem-realtime" = {
            json = local.siem_realtime_dashboard
          }
        }
      }
```

> `04`는 Athena 데이터소스가 없으면 패널이 비어 보입니다. 등록 자체는 무해하므로
> 조건 분기는 두지 않았습니다 — log-archive apply 후 자동으로 채워집니다.

---

## ⑤ 루트 `grafana.tf`에서 값 전달

```hcl
module "grafana" {
  source = "./module/grafana"

  # ... 기존 인자 유지 ...

  # (2026-08-19) Log 계정 조회 역할.
  # log-archive 스택의 output grafana_reader_role_arn 값을 넣는다.
  # 계정이 분리되어 있고 한 방향 참조 원칙(terraform/ -> 상시 계층)을 지켜야 하므로
  # remote state 참조가 아니라 변수로 넘긴다.
  athena_reader_role_arn = var.grafana_athena_reader_role_arn
}
```

루트 `variables.tf`에:

```hcl
variable "grafana_athena_reader_role_arn" {
  description = "Log 계정 Grafana 조회 역할 ARN (log-archive output). 비우면 Athena 데이터소스 미등록"
  type        = string
  default     = ""
}
```
