# gochuchamchi EKS 보안 점검 보고서

> **점검일**: 2026-07-29
> **조치일**: 2026-07-29 (동일자 — 전 항목 조치 후 라이브 환경에서 검증 완료)
> **대상**: gochuchamchi-eks (ap-northeast-2) — Terraform 기반 EKS 인프라 전체
> **점검 범위**: Terraform 코드 전체(main/securitygroups/iamRole/eks-pod-identity/rds/redis/s3/dns/argocd/k8s-deploy/notifications/rds-schema-init), userdata 템플릿, tfstate, 운영 문서
> **환경 스펙**: EKS 1.35 (커뮤니티 모듈, Pod Identity), t3.small×2 (min2/max4), NAT instance t3.micro, VPC Endpoint 없음, ArgoCD + Image Updater, 도메인 gochuchamchi.shop

---

## 0. 요약 (Executive Summary)

| # | 심각도 | 항목 | 상태 |
|---|--------|------|------|
| 1 | 🚨 긴급 | tfstate 내 GitHub PAT / RDS 비밀번호 평문 저장 | ✅ 조치완료 |
| 2 | 🔴 높음 | Bastion SSH 22번 0.0.0.0/0 개방 | ✅ 조치완료 |
| 3 | 🔴 높음 | EKS API 엔드포인트 퍼블릭 무제한 노출 | ✅ 조치완료 |
| 4 | 🔴 높음 | S3 이미지 버킷 퍼블릭 액세스 차단 전체 해제 | ➖ 의도적 유지 (사유 문서화) |
| 5 | 🟠 중간 | SG 전반이 VPC CIDR 전체 허용 (SG 참조 미사용) | ✅ 조치완료 (EFS 포함) |
| 6 | 🟠 중간 | ExternalDNS가 계정 내 전체 호스팅존 수정 가능 | ✅ 조치완료 |
| 7 | 🟠 중간 | ArgoCD internet-facing 노출 | ✅ 조치완료 |
| 8 | 🟠 중간 | GitHub Actions OIDC — sub 조건 필수 (구축 예정 시) | ✅ 이미 구현돼 있었음 |
| 9 | ⚡ 트러블 | t3.small max-pods=11 → 파드 Pending 임박 | ✅ 조치완료 |
| 10 | ⚡ 트러블 | EKS 인증 토큰 15분 만료 → 긴 apply 시 Unauthorized | ✅ 조치완료 |
| 11 | ⚡ 트러블 | ACM 검증 완료 전 ALB 인증서 참조 가능 | ✅ 조치완료 |
| 12 | ⚡ 트러블 | NAT 인스턴스 SPOF + S3 Gateway Endpoint 부재 | ✅ 조치완료 |
| 13 | 🟡 개선 | schema init 시 DB 비밀번호 로그 노출 | ✅ 조치완료 |
| 14 | 🟡 개선 | Redis 전송 암호화/AUTH 미적용 | ✅ 조치완료 (2026-08-04 replication_group + TLS + AUTH — docs/2026-08-04.md) |
| **15** | 🚨 긴급 | **discord-notifications state에 Discord 웹훅 URL 평문 저장** (2차 점검 신규) | ✅ 조치완료 |
| **16** | ⚡ 트러블 | **metrics-server 미설치 → HPA가 CPU를 못 읽어 오토스케일링 미동작** (조치 중 발견) | ✅ 조치완료 |
| **17** | ⚡ 트러블 | **EFS StorageClass가 access entry 전파 전에 생성 시도 → 403** (apply 중 발견) | ✅ 조치완료 |
| **18** | ⚡ 트러블 | **destroy 시 SG "규칙"이 먼저 삭제돼 ALB 정리 교착 (3차 재발)** (destroy 중 발견) | ✅ 조치완료 |

**긍정 평가 항목** (현행 유지):
- ✅ aws-auth ConfigMap 대신 **access entry** 방식 사용
- ✅ 컴포넌트별 **Pod Identity 역할 분리** + 최소권한 정책 (S3/Secrets 스코프 지정)
- ✅ `manage_master_user_password` — RDS 비밀번호를 코드에 넣지 않음
- ✅ ExternalDNS `policy: upsert-only` — 레코드 삭제 방어
- ✅ destroy 순서 `depends_on` 고정 (NAT/webhook 데드락 방지) — 트러블슈팅 이력 반영됨
- ✅ database subnet 라우팅 테이블 분리 (NAT 라우트 없는 isolated subnet)

---

## 0.1 조치 결과 및 검증 증거 (2026-07-29)

전 항목 조치 후 **라이브 환경에서 실제로 검증**한 결과. "코드를 고쳤다"가 아니라 "고친 결과가 클러스터에 반영됐다"까지 확인함.

| # | 코드 변경 | 라이브 검증 결과 |
|---|-----------|------------------|
| 1 | `backend.tf` 신규 (메인/discord 양쪽) | `terraform state pull` 성공, 로컬 tfstate 4개 삭제, 잔존 시크릿 grep 0건 |
| 1 | PAT 로테이션 | Secret `resourceVersion 2390 → 33417`, hard refresh 후 `Synced/Healthy`, conditions `[]` |
| 2 | `securitygroups.tf` — `ingress_rules = {}` | SG 설명 `"SSM only, no inbound"`, SSM 접속 정상 (`PingStatus: Online`) |
| 3 | `endpoint_public_access_cidrs` | `describe-cluster` → `116.122.154.177/32` |
| 5 | rds/redis/efs SG를 `referenced_security_group_id`로 | plan에 `mariadb_from_nodes`/`redis_from_nodes`/`nfs_from_nodes` 생성 확인 |
| 6 | `external_dns_hosted_zone_arns`에 zone_id 주입 | 존 1개로 축소 |
| 7 | `scheme = "internal"` | `describe-load-balancers` → ArgoCD ALB만 `internal`, 앱 ALB는 `internet-facing` 유지 |
| 9 | vpc-cni `ENABLE_PREFIX_DELEGATION` | `describe-addon` → `{"env":{"ENABLE_PREFIX_DELEGATION":"true"}}` |
| 10 | provider를 `exec` 플러그인으로 | 174개 리소스 apply를 토큰 만료 없이 완주 |
| 11 | `aws_acm_certificate_validation.this.certificate_arn` | ALB 인증서 정상 부착, 사이트 HTTPS 200 |
| 12 | `aws_vpc_endpoint.s3` | `describe-vpc-endpoints` → `com.amazonaws.ap-northeast-2.s3` |
| 13 | `defaults-extra-file` 방식 | schema init 정상 완료 (`ps` 노출 제거) |
| 15 | discord state S3 이전 | 평문 웹훅 담긴 로컬 `.backup` 삭제, 재검색 0건 |
| 16 | addon `metrics-server = {}` | HPA `cpu: <unknown>/70%` → **`cpu: 1%/70%`**, `kubectl top` 동작 |
| 17 | `depends_on`에 `module.eks` 추가 | 재apply 시 403 재발 없음 |

**최종 서비스 상태**: `https://gochuchamchi.shop` 200 OK (0.27s) / `www` 200 / HTTP→HTTPS 301 / 파드 2/2 Running / ArgoCD `Synced` + `Healthy`

### 2차 점검에서 정정된 사항

초기 보고서 작성 이후 실제 파일을 재확인하는 과정에서 아래를 정정함:

1. **항목 1의 "tfstate에 PAT/RDS 비밀번호 평문 존재"는 재확인 시점에는 해당 없음** — 점검 이후 destroy를 수행해 `terraform.tfstate`가 `"resources": []` 상태였고, 백업 3개에도 `github_pat_` / `secret_string` 문자열이 없었음. 다만 **로컬 백엔드 + state 평문 저장이라는 구조적 위험은 그대로**여서 S3 백엔드 이전은 예정대로 진행함.
2. **진짜 활성 유출은 `discord-notifications/terraform.tfstate.backup`이었음** (항목 15로 신규 등록) — Discord 웹훅 URL이 토큰째 평문 저장돼 있었고, 이건 초기 보고서 점검 범위에 "notifications"가 포함돼 있었음에도 누락된 항목이었음.
3. **항목 8(OIDC sub 조건)은 "구축 예정"이 아니라 이미 `ecr.tf`에 구현돼 있었음** — `aud` + `sub`(`repo:<owner>/gochuchamchi-spring:ref:refs/heads/main`) 양쪽 검증 확인.
4. **항목 5의 대상에 EFS SG(2049)가 빠져 있었음** — rds/redis와 동일한 VPC CIDR 전체 허용 패턴이라 같이 조치함.

### 운영 중 유의사항 (조치의 부작용)

- **#3 IP 제한**: 집 외 네트워크(카페 등)에서는 로컬 `kubectl`/`terraform`이 EKS API에 닿지 않음. IP 변경 시 `curl checkip.amazonaws.com` 후 `endpoint_public_access_cidrs` 갱신 필요. 이동이 잦다면 배스천 경유(SSM)로 우회.
- **#7 ArgoCD internal**: UI 접근에 SSM 포트포워딩 필요. hosts에 `127.0.0.1 argocd.gochuchamchi.shop` 등록 후 `https://argocd.gochuchamchi.shop:8443` 접속 (ALB가 호스트 기반 라우팅이라 `localhost:8443`으로는 404).
- **#2 SSH 제거**: 배스천은 SSM 전용. `scp` 대신 S3 경유 파일 전달(`k8s_manifests` 버킷 패턴 그대로).
- **#9 prefix delegation**: 기존 노드에는 소급 적용 안 됨. 이번엔 클린 재구축이라 무관했으나, 운영 중 적용 시 노드그룹 롤링 필요.
- **Image Updater write-back**: 새 PAT의 **Contents: Read and write** 권한은 실제 이미지 갱신이 발생해야 실증됨. 다음 CI 실행 시 image-updater 로그의 `errors=0` 유지 여부 확인 권장.

---

## 1. 🚨 [긴급] tfstate 내 크리덴셜 평문 저장 — ✅ 조치완료

> **2차 점검 정정**: 아래 "현상"은 최초 점검 시점 기준. 재확인 시점에는 destroy 후여서
> `terraform.tfstate`가 `"resources": []`였고 백업 3개에도 해당 문자열이 없었음.
> 단, **로컬 백엔드 + state 평문 저장이라는 구조적 위험은 동일**하므로 S3 이전은 예정대로 수행.
> 한편 **실제 활성 유출은 `discord-notifications/terraform.tfstate.backup`의 Discord 웹훅**이었음 → 항목 15 참조.
>
> **조치 결과**: 양쪽 state를 `gochuchamchi-tfstate-307223751140`(버저닝/퍼블릭차단/SSE-S3, `use_lockfile`)로 이전,
> 로컬 평문 state 4개 삭제, PAT 로테이션 완료(Secret `resourceVersion 2390 → 33417`, hard refresh로 인증 검증).

### 현상
- `terraform.tfstate`(및 백업 2개)에 **GitHub PAT 실물이 평문 저장**되어 있음 (`github_pat_...` 확인됨)
- `data.aws_secretsmanager_secret_version` + `kubernetes_secret_v1` 사용으로 **RDS 마스터 비밀번호도 state에 평문 저장** (`secret_string` 2건)
- `variable`의 `sensitive = true`는 **plan/apply 출력에서만 마스킹**할 뿐, state 저장은 막지 못함 (Terraform의 구조적 한계)
- state가 로컬 백엔드로 관리되고 있어 유출 경로 통제가 불가능

### 리스크
- PAT 유출 시: gitops 저장소 write 권한 → **공급망 공격으로 임의 이미지 태그 배포 가능** (ArgoCD가 자동 sync)
- DB 비밀번호 유출 시: VPC 내부 진입만 성공하면 DB 전체 접근

### 조치

**1) PAT 즉시 폐기 및 재발급**
```
GitHub → Settings → Developer settings → Fine-grained tokens → Revoke
재발급 시: 대상 저장소를 gochuchamchi-gitops 하나로 제한, Contents: Read/Write만 부여
```

**2) State를 S3 백엔드로 이전**
```bash
# 백엔드 버킷 생성 (버저닝 + 퍼블릭 차단 필수)
aws s3api create-bucket --bucket gochuchamchi-tfstate-119408973151 \
  --region ap-northeast-2 \
  --create-bucket-configuration LocationConstraint=ap-northeast-2 --profile admin

aws s3api put-bucket-versioning --bucket gochuchamchi-tfstate-119408973151 \
  --versioning-configuration Status=Enabled --profile admin

aws s3api put-public-access-block --bucket gochuchamchi-tfstate-119408973151 \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true \
  --profile admin
```

```hcl
# backend.tf (Terraform 1.10+: DynamoDB 없이 S3 네이티브 잠금 지원)
terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-119408973151"
    key          = "eks/terraform.tfstate"
    region       = "ap-northeast-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

```bash
terraform init -migrate-state
# 이전 확인 후: 로컬 terraform.tfstate / *.backup 삭제
# git 히스토리에 올라간 적이 있다면 git filter-repo로 히스토리에서 제거 + PAT 재발급 재확인
```

**3) 근본 해결 (다음 스프린트)**: External Secrets Operator 도입
- 앱 Pod Identity에 이미 `secretsmanager:GetSecretValue` 권한 있음 → ESO가 Secrets Manager를 직접 동기화하면 **Terraform이 비밀번호를 만질 일 자체가 사라짐** → state 평문 문제 원천 차단
- `k8s-deploy.tf`의 `data.aws_secretsmanager_secret_version` / `kubernetes_secret_v1.gochuchamchi_db_secret` 제거 가능

### 면접 설명
> "Terraform state에는 시크릿이 평문으로 저장되는 구조적 한계가 있어서, state 자체를 시크릿으로 취급했습니다. S3 암호화 + 버저닝 + 퍼블릭 차단으로 보호하고 git에는 올리지 않으며, 근본적으로는 External Secrets Operator로 시크릿이 Terraform을 거치지 않는 구조로 전환했습니다."

---

## 2. 🔴 Bastion SSH 22번 전 세계 개방

### 현상
- `bastion_host_sg`: 22/tcp `0.0.0.0/0` 허용
- 동일 인스턴스에 이미 `AmazonSSMManagedInstanceCore` 부여됨 (SSM 접속 가능 상태)

### 리스크
- 상시 포트 스캐닝/브루트포스 대상. 키 파일 유출 시 즉시 침해
- SSH 접속은 감사 추적이 어려움 (SSM은 CloudTrail에 세션 기록 전부 남음)

### 조치 — SSH 완전 제거, SSM 단일화
```hcl
# securitygroups.tf
module "bastion_host_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-bastion-sg"
  description = "Bastion host security group (SSM only, no inbound)"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {}   # 인바운드 0개 — SSM은 아웃바운드 443만 필요

  egress_rules = {
    all = { ip_protocol = "-1", cidr_ipv4 = "0.0.0.0/0" }
  }
}
```
```hcl
# main.tf — bastion 모듈에서 key_name 제거 가능 (키 관리 리스크 자체 제거)
```
```bash
# 접속 방법
aws ssm start-session --target <bastion-instance-id> --profile admin --region ap-northeast-2
```

### 트레이드오프
- 비용: 변화 없음 / 보안: 인바운드 공격면 0 / 운영: `scp` 대신 S3 경유 파일 전달 필요 (이미 k8s_manifests 버킷 패턴 사용 중이므로 영향 없음)

### 면접 설명
> "SSH 키 관리 리스크와 인바운드 포트를 모두 제거하고 SSM Session Manager로 단일화했습니다. 접속 이력이 CloudTrail에 남아 KISA 진단 항목의 계정/접근 통제 요건과도 맞습니다."

---

## 3. 🔴 EKS API 엔드포인트 퍼블릭 무제한 노출

### 현상
- `endpoint_public_access = true` + CIDR 미지정 → 기본값 `0.0.0.0/0`
- 인증은 필요하지만 컨트롤플레인 API 서버가 인터넷에 직접 노출

### 조치
```hcl
# main.tf — module "eks"
endpoint_public_access       = true
endpoint_private_access      = true
endpoint_public_access_cidrs = ["<집 공인IP>/32"]   # curl ifconfig.me
```

### 트레이드오프
| 기준 | 구성 | 비고 |
|------|------|------|
| 프로덕션 | public 완전 차단 + private only + VPN/배스천 경유 | 최고 보안, 로컬 terraform 워크플로우 불가 |
| **현 프로젝트 (권장)** | public + CIDR /32 제한 | 로컬 helm/kubernetes provider apply 유지 |
| 주의점 | IP 변경 시(카페 등) apply로 CIDR 갱신 필요 | bastion은 private endpoint로 접근하므로 무영향 |

### 면접 설명
> "학습 환경에서는 로컬 Terraform 워크플로우를 유지하기 위해 퍼블릭 엔드포인트를 유지하되 소스 CIDR을 /32로 제한하는 절충을 택했고, 프로덕션 기준은 프라이빗 엔드포인트 단일화라는 점을 구분해서 이해하고 있습니다."

---

## 4. 🔴 S3 이미지 버킷 퍼블릭 액세스 차단 전체 해제

### 현상
- `block_public_acls / block_public_policy / ignore_public_acls / restrict_public_buckets` 전부 `false`
- 버킷 정책 `Principal: "*"` + `s3:GetObject` (ListBucket은 없어 객체 열거는 불가)

### 리스크
- URL 추측 시 모든 객체 읽기 가능
- 퍼블릭 차단이 꺼져 있어 **향후 실수로 넓은 정책이 추가돼도 방어선이 없음**

### 조치
- **프로덕션 패턴**: CloudFront + OAC — 버킷 완전 프라이빗, CloudFront만 읽기 허용, 앞단에 캐싱/WAF
- **현 단계**: 상품 이미지라는 공개 목적 데이터임을 감안해 현행 유지 가능하되, 의도를 문서화(본 보고서)하고 CloudFront OAC를 하드닝 스프린트 항목으로 등록

### 면접 설명
> "공개 목적 데이터라 퍼블릭 읽기를 의도적으로 허용했지만, 프로덕션이라면 CloudFront OAC로 원본 버킷을 차단하고 캐싱과 WAF를 앞단에 두는 것이 표준입니다."

---

## 5. 🟠 SG가 VPC CIDR 전체 허용 (SG 참조 미사용)

### 현상
| SG | 허용 범위 | 문제 |
|----|-----------|------|
| `add_node_sg` | 172.30.0.0/16 all traffic | VPC 내 어떤 자원이든 노드에 전 포트 접근 |
| `rds_sg` | 172.30.0.0/16 → 3306 | NAT/bastion 침해 시 DB 직행 |
| `redis_sg` | 172.30.0.0/16 → 6379 | 동일 |

### 조치 — 소스를 SG 참조로 좁히기 (Defense-in-Depth)
```hcl
# rds.tf
module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-rds-sg"
  description = "RDS accessible only from EKS nodes and bastion"
  vpc_id      = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      from_port                = 3306
      to_port                  = 3306
      protocol                 = "tcp"
      source_security_group_id = module.eks.node_security_group_id
      description              = "MariaDB from EKS nodes only"
    },
    {
      from_port                = 3306
      to_port                  = 3306
      protocol                 = "tcp"
      source_security_group_id = module.bastion_host_sg.security_group_id
      description              = "Schema init from bastion"
    }
  ]

  egress_rules = {
    all = { ip_protocol = "-1", cidr_ipv4 = "0.0.0.0/0" }
  }
}

# redis.tf — 동일 패턴 (6379, EKS 노드 SG만. bastion 규칙 불필요)
```

### 기술 배경
- ALB target-type `ip` 환경에서 파드는 노드 ENI의 secondary IP를 사용 → 트래픽 소스가 노드 SG로 식별되므로 SG 참조가 정상 동작
- `add_node_sg`의 all-traffic 규칙: EKS 모듈이 생성하는 기본 노드 SG가 노드↔노드/컨트롤플레인 통신을 이미 처리 → 추가 SG는 ALB→파드 헬스체크/트래픽 등 필요한 범위만 남기고 축소 검토

### 면접 설명
> "CIDR 기반 허용은 '네트워크 위치'를 신뢰하는 것이고, SG 참조는 '워크로드 정체성'을 신뢰하는 것입니다. 배스천이나 NAT가 침해돼도 DB 접근이 차단되는 계층 방어를 구성했습니다."

---

## 6. 🟠 ExternalDNS 권한 과다 (`hostedzone/*`)

### 현상
- `external_dns_hosted_zone_arns = ["arn:aws:route53:::hostedzone/*"]` — 계정 내 **모든** 호스팅존 레코드 수정 가능

### 조치
```hcl
# eks-pod-identity.tf
external_dns_hosted_zone_arns = [
  "arn:aws:route53:::hostedzone/${data.aws_route53_zone.this.zone_id}"
]
```

---

## 7. 🟠 ArgoCD internet-facing 노출

> ⚠️ **2026-07-30 재확인 — 조치 일부가 재구축으로 되돌아감**
> - **유지됨**: internal ALB 전환 (`argocd.tf`의 `scheme = "internal"` — 코드에 있어서 재구축에도 살아남음). 실측 확인: ALB `Scheme: internal`, 도메인이 사설 IP(`172.30.41.21`, `172.30.60.112`)로 해석
> - **되돌아감**: **admin 비밀번호 변경이 초기화됨**. `argocd-initial-admin-secret`이 2026-07-30T00:50:50Z에 재생성되어 여전히 존재하고, `admin.passwordMtime`이 설치 시각 그대로 = 변경 이력 없음
> - **원인**: 비밀번호 변경은 클러스터 안에서 수동으로 한 작업이라 Terraform state에 없어 destroy/apply로 사라짐
> - **위험도**: 낮음 (초기 비밀번호는 랜덤 생성값 + ALB가 internal이라 인터넷 노출 없음). 단 조치 항목으로는 **미이행 상태**
> - **재조치 필요**: 비밀번호 변경 후 `kubectl -n argocd delete secret argocd-initial-admin-secret`
> - 상세: `2026-07-30.md` §4.4

### 현상
- `alb.ingress.kubernetes.io/scheme: internet-facing` — ArgoCD UI가 인터넷에 노출
- ArgoCD는 클러스터 admin급 권한 + gitops write-back PAT를 보유한 **최고 가치 타겟**

### 조치 (단계별)

**즉시 (최소 변경)**
```bash
# 초기 admin 비밀번호 즉시 변경
argocd account update-password
# 또는 UI: User Info → Update Password
```

**하드닝 (권장)** — internal ALB 전환 + 배스천 경유 접근
```hcl
# argocd.tf — server.ingress.annotations
"alb.ingress.kubernetes.io/scheme" = "internal"
```
```bash
# 접근: SSM 포트포워딩 + kubectl port-forward
aws ssm start-session --target <bastion-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}' --profile admin
# bastion 내부에서:
kubectl -n argocd port-forward svc/argocd-server 8080:80
# 로컬 브라우저: http://localhost:8080
```

### 트레이드오프
- internal 전환 시 팀원 접근에 배스천 경유 필요 (운영 편의 ↓, 보안 ↑)
- `server.insecure: true`는 ALB TLS 종단 패턴에서 표준이므로 유지 가능 — 단 **internal 전환이 전제**

---

## 8. 🟠 GitHub Actions OIDC — sub 조건 필수 — ✅ 이미 구현돼 있었음

> **2차 점검 정정**: "구축 예정"으로 분류했으나, `ecr.tf`의 `aws_iam_role.github_actions_ecr_push`에
> **이미 `aud` + `sub` 양쪽 조건이 구현돼 있었음**
> (`StringLike`로 `repo:landoll9999/gochuchamchi-spring:ref:refs/heads/main` 고정). 추가 조치 불필요.

### 배경
- OIDC trust policy에서 `aud`만 검증하면 **타인의 저장소 워크플로우도 해당 Role을 assume 가능** (실제 빈번한 사고 유형)

### 조치 (구축 시 반영)
```hcl
data "aws_iam_policy_document" "github_oidc_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:landoll9999/gochuchamchi:ref:refs/heads/main"]
    }
  }
}
```
- 필요 시 `StringLike` + `repo:landoll9999/gochuchamchi:*`로 완화 가능하나, 배포용 Role은 `ref:refs/heads/main` 고정 권장

---

## 9. ⚡ t3.small max-pods=11 → 파드 Pending 임박 (최우선 트러블)

### 현상
- t3.small의 ENI 기반 max-pods는 **노드당 11개**
- 시스템 파드 계산: coredns 2 + kube-proxy 2 + vpc-cni 2 + pod-identity-agent 2 + efs-csi 4 + ALB controller 2 + external-dns 1 + cluster-autoscaler 1 + ArgoCD 스택 ~7 + image-updater 1 ≒ **2노드 22칸 중 20칸 이상 소진**
- 앱 파드 2~3개 배포 시점에 Pending 발생 예상
- Cluster Autoscaler가 노드를 늘려도 **노드당 11개 한계는 동일** → 비용만 증가

### 조치 — VPC CNI Prefix Delegation
```hcl
# main.tf — module "eks" addons
addons = {
  coredns                = {}
  eks-pod-identity-agent = { before_compute = true }
  kube-proxy             = {}
  vpc-cni = {
    before_compute = true
    configuration_values = jsonencode({
      env = { ENABLE_PREFIX_DELEGATION = "true" }
    })
  }
  aws-efs-csi-driver = {}
}
```
- 적용 시 t3.small max-pods **11 → 110** (EKS 모듈 21.x + AL2023 환경에서 bootstrap 자동 반영)
- private subnet을 /23으로 넓혀둔 설계가 이 설정과 결합되어야 실효성 발생 (prefix는 /28 블록 단위로 서브넷에서 할당됨)
- **주의**: 기존 노드에는 소급 적용 안 됨 → 설정 후 노드그룹 롤링 필요 (`desired_size` 조정 또는 인스턴스 refresh)

### 면접 설명
> "노드 스케일링을 논하기 전에 노드당 max-pods 병목을 먼저 확인했습니다. IP 고갈 문제로 오인하기 쉽지만 실제 병목은 ENI 슬롯이었고, prefix delegation으로 해결했습니다."

---

## 10. ⚡ EKS 인증 토큰 15분 만료 (긴 apply 시 Unauthorized)

### 현상
- `data.aws_eks_cluster_auth` 토큰은 **plan 시점에 1회 발급, 15분 만료**
- helm_release 다수 + `timeout = 600` 조합으로 apply가 길어지면 중간에 `Unauthorized` 발생하는 대표적 이슈

### 조치 — exec 플러그인 방식 전환 (호출 시마다 토큰 재발급)
```hcl
# providers.tf
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token",
        "--cluster-name", var.cluster_name,
        "--region", var.region,
        "--profile", var.aws_profile]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token",
      "--cluster-name", var.cluster_name,
      "--region", var.region,
      "--profile", var.aws_profile]
  }
}
# data.aws_eks_cluster_auth 는 제거 가능
```

---

## 11. ⚡ ACM 검증 완료 전 인증서 참조

### 현상
- Ingress(`k8s-deploy.tf`)와 ArgoCD(`argocd.tf`)가 `aws_acm_certificate.this.arn`을 직접 참조
- `aws_acm_certificate_validation` 완료 여부와 무관하게 ALB controller가 미검증 인증서를 붙이려다 실패 가능 (특히 클린 재생성 시)

### 조치 — validation 리소스의 ARN을 참조
```hcl
# k8s-deploy.tf / argocd.tf 공통
"alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate_validation.this.certificate_arn
```

---

## 12. ⚡ NAT 인스턴스 SPOF + S3 Gateway Endpoint 부재

### 현상
- t3.micro NAT 1대에 모든 아웃바운드 집중: 컨테이너 이미지 풀, ALB controller / ExternalDNS / Cluster Autoscaler의 AWS API 호출
- NAT 장애 시: 신규 파드 이미지 풀 실패, 컨트롤러들의 AWS API 호출 실패 → **조용한 고장** (기존 파드는 동작하므로 원인 파악 지연)

### 조치 — S3 Gateway Endpoint 추가 (무료)
```hcl
# main.tf
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "gochuchamchi-s3-endpoint" }
}
```
- **ECR 이미지 레이어는 실제로 S3에서 전송**되므로 NAT 트래픽/부하가 크게 감소
- 앱의 S3 이미지 업로드 트래픽도 NAT 우회 → 비용 절감 겸용

### 트레이드오프
| 기준 | 구성 | 비용 |
|------|------|------|
| 프로덕션 | NAT Gateway Multi-AZ + ECR/STS/EC2 Interface Endpoint | Interface 개당 월 ~$8 |
| **현 프로젝트** | NAT instance 1대 + **S3 Gateway(무료)** | 추가 비용 0 |

---

## 13. 🟡 schema init 시 DB 비밀번호 로그 노출

### 현상
- `mysql -p"$DB_PASS"` — 프로세스 목록(`ps`)에 비밀번호 노출
- SSM `get-command-invocation` 출력 및 로그에 커맨드 전문 잔존 가능

### 조치 — defaults-extra-file 방식
```powershell
# rds-schema-init.tf — $cmds 배열의 mysql 호출 교체
$cmds = @(
  "which mysql || sudo dnf install -y mariadb105",
  "aws s3 cp s3://${aws_s3_bucket.k8s_manifests.id}/db/schema.sql /home/ec2-user/schema.sql --region ${var.region}",
  'SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ''${module.rds.db_instance_master_user_secret_arn}'' --region ${var.region} --query SecretString --output text)',
  'DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)[''password''])")',
  'printf "[client]\nuser=admin\npassword=%s\nhost=${data.aws_db_instance.this.address}\n" "$DB_PASS" > /home/ec2-user/.my.cnf && chmod 600 /home/ec2-user/.my.cnf',
  'mysql --defaults-extra-file=/home/ec2-user/.my.cnf < /home/ec2-user/schema.sql; rm -f /home/ec2-user/.my.cnf'
)
```

---

## 14. 🟡 Redis 전송 암호화 / AUTH 미적용 — ✅ 조치완료 (2026-08-04)

> **조치 결과**: `aws_elasticache_replication_group`(단일 노드) 전환 +
> `transit_encryption_enabled` + `at_rest_encryption_enabled` + `auth_token` 적용.
> 앱은 `SPRING_DATA_REDIS_SSL_ENABLED=true` + K8s Secret(`gochuchamchi-redis-secret`)로 접속.
> 상세·검증 명령은 [2026-08-04.md](2026-08-04.md) 참고. 아래는 당시 판단 기록(보존).

### 현상
- `aws_elasticache_cluster` 리소스는 transit encryption / AUTH 토큰을 **지원하지 않음**
- 세션 데이터(로그인 상태)가 VPC 내 평문 전송

### 판단
- 현 단계: **항목 5의 SG 참조 좁히기로 커버** (EKS 노드 SG만 6379 허용)
- 운영 전환 시: `aws_elasticache_replication_group`(단일 노드 구성 가능)으로 마이그레이션 + `transit_encryption_enabled = true` + `auth_token` 적용

### 면접 설명
> "cluster 리소스의 암호화 미지원이라는 API 레벨 한계를 인지하고 있고, 현 단계에서는 네트워크 계층(SG 참조)으로 보완하며 운영 전환 시 replication_group 기반 암호화로 마이그레이션할 계획입니다."

---

## 15. 🚨 [긴급] discord-notifications state에 웹훅 URL 평문 저장 — ✅ 조치완료

### 현상 (2차 점검 신규 발견)
- `discord-notifications/terraform.tfstate.backup`(11,960 B)에 **Discord 웹훅 URL이 토큰째 평문 저장**
- `variables.tf`의 `sensitive = true`는 plan/apply 출력만 마스킹할 뿐 state 저장은 못 막음 — 항목 1과 동일한 구조적 한계
- 최초 점검의 명시 범위에 "notifications"가 포함돼 있었으나 누락됐던 항목

### 리스크
- 웹훅 URL 유출 시 **누구나 해당 Discord 채널에 임의 메시지 POST 가능** (인증이 URL 자체에 내장된 구조)
- ArgoCD sync 알림으로 위장한 피싱/허위 배포 알림 → 운영 판단 교란

### 조치
```hcl
# discord-notifications/backend.tf (신규)
terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-307223751140"
    key          = "discord-notifications/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "admin"
    encrypt      = true
    use_lockfile = true
  }
}
```
- `terraform init -migrate-state` → `terraform state pull`로 원격 상태 확인 → 로컬 `terraform.tfstate` / `.backup` 삭제
- 재검색으로 잔존 0건 확인

### 배운 점
> state를 "설정 파일"이 아니라 **시크릿 그 자체**로 취급해야 함. `sensitive = true`는 출력 마스킹일 뿐,
> 백엔드를 옮기지 않으면 `.backup` 파일 하나로 유출된다. **별도 root module이라고 관리에서 빠지지 않도록**
> state가 있는 모든 디렉토리를 목록화해서 점검해야 한다.

---

## 16. ⚡ metrics-server 미설치 → HPA 오토스케일링 미동작 — ✅ 조치완료

### 현상 (조치 중 발견)
- `kubectl get hpa` → `TARGETS: cpu: <unknown>/70%`, 이벤트에 `FailedGetResourceMetric`
- 원인: `metrics.k8s.io` API를 제공하는 metrics-server가 설치돼 있지 않음 (EKS는 기본 미포함)
- **HPA를 구성해뒀지만 실제로는 min 2에 고정된 채 스케일링이 전혀 동작하지 않는 상태**였음

### 조치
```hcl
# main.tf — module "eks" addons
metrics-server = {}
```

### 검증
```
# 적용 전: cpu: <unknown>/70%
# 적용 후: cpu: 1%/70%    <- 실제 메트릭 수집
kubectl -n gochuchamchi top pods   # 4~8m / ~166Mi 정상 출력
```

### 면접 설명
> "HPA 리소스가 존재한다고 오토스케일링이 동작하는 게 아니라는 걸 확인했습니다. EKS는 metrics-server가
> 기본 포함이 아니라서 `metrics.k8s.io`가 없으면 HPA가 `<unknown>` 상태로 조용히 멈춰 있습니다.
> '설정했다'와 '동작한다'를 분리해서 검증하는 습관의 사례입니다."

---

## 17. ⚡ EFS StorageClass가 access entry 전파 전 생성 → 403 — ✅ 조치완료

### 현상 (apply 중 실제 발생)
```
Error: storageclasses.storage.k8s.io is forbidden: User "arn:aws:iam::...:user/admin"
cannot create resource "storageclasses" in API group "storage.k8s.io" at the cluster scope
  with kubernetes_storage_class_v1.efs, on efs.tf line 56
```
- `depends_on`이 `[aws_efs_mount_target.this, module.efs_csi_pod_identity]`뿐이라 **`module.eks`를 기다리지 않음**
- 두 리소스 모두 빨리 끝나므로, `enable_cluster_creator_admin_permissions`가 만드는 access entry가
  **EKS 인증 웹훅에 전파되기 전에** StorageClass 생성 요청이 나감
- 같은 파일의 namespace/secret 등은 `depends_on = [module.eks]`가 있어 통과했음 (대조군)

### 조치
```hcl
# efs.tf
depends_on = [aws_efs_mount_target.this, module.efs_csi_pod_identity, module.eks]
```

### 기술 배경
- IAM/EKS access entry는 **최종 일관성(eventual consistency)** — 리소스 생성 완료와 권한 실효 시점이 다름
- Terraform의 `depends_on`은 **그래프 순서**만 보장하고 전파 시간은 보장하지 않지만,
  `module.eks` 전체를 기다리게 하면 access entry 생성까지 포함되어 실용적으로 충분한 간격이 확보됨
- 항목 12의 S3 버킷 `time_sleep` 패턴과 같은 계열의 문제 (그래프 순서 ≠ 실전파 완료)

### 면접 설명
> "권한 설정 자체는 맞는데 타이밍 때문에 실패하는 케이스였습니다. AWS의 IAM/access entry는 최종 일관성이라
> 리소스 생성 완료가 권한 실효를 의미하지 않습니다. 같은 파일의 다른 리소스는 `module.eks`에 의존해서
> 통과했다는 대조군이 있어서 원인을 특정할 수 있었습니다."

---

## 18. ⚡ destroy 시 SG "규칙" 선삭제로 ALB 정리 교착 (3차 재발) — ✅ 조치완료

### 현상 (2026-07-29 destroy 중 발생)
```
kubernetes_ingress_v1.gochuchamchi_web: Still destroying... [19m50s elapsed]
Error: Unable to uninstall Helm release argocd: … context deadline exceeded
Error: Ingress (gochuchamchi/gochuchamchi-web-ingress) still exists
```

### 기존 교착(트러블슈팅 로그 13.2 / 13.2-1)과 달랐던 점
**네트워크가 전부 정상이었음** — NAT `running`, private 라우트 2개 모두 NAT ENI 지시, public 라우트의 IGW 존재, 노드 2대 `running`, ALB 컨트롤러 파드도 `Running`. 겉보기엔 이상이 없어 원인 파악이 지연됨.

### 원인
컨트롤러 로그가 결정적이었음 — `DescribeSecurityGroups … i/o timeout`, `DescribeTargetHealth … i/o timeout`.
구성요소는 살아있는데 **통신만 차단** → 경로가 아니라 필터 문제.
확인 결과 **NAT 보안 그룹의 규칙이 0개**(`add_node_sg`도 0개)였음.

- 보안 그룹 "그룹"(`aws_security_group`)은 실행 중 인스턴스에 붙어 있어 삭제가 거부됨
- 그러나 **"규칙"은 별개 리소스**(`aws_vpc_security_group_ingress_rule` / `_egress_rule`)라 그 보호를 못 받고 먼저 삭제됨
- 인바운드 부재 → NAT가 노드 트래픽 수신 불가 / 아웃바운드 부재 → NAT가 인터넷 송신 불가
- → 컨트롤러의 AWS API 호출 전량 타임아웃 → ALB 정리 불가 → Ingress finalizer 영구 잔류

**왜 기존 `depends_on`으로 안 막혔나** — 항목 13.2-1과 동일한 함정:
`module.eks`가 `module.add_node_sg.id`를, `module.nat_instance`가 `module.nat_sg.id`를 참조하지만
그 `id`는 `aws_security_group` **리소스 하나의 출력**이라 그 리소스에만 순서가 걸린다.
같은 모듈 안의 규칙 리소스는 아무도 참조하지 않아 그래프상 자유롭게 먼저 삭제된다.

### 조치
```hcl
# eks-pod-identity.tf — helm_release.aws_load_balancer_controller
depends_on = [
  module.aws_lb_controller_pod_identity,
  module.eks,
  module.nat_instance,
  aws_route.private_subnet,
  module.vpc,
  module.nat_sg,        # 추가 — 규칙까지 보호하려면 모듈 전체를 명시
  module.add_node_sg,   # 추가
]
```

### 복구 절차 (finalizer 강제 제거 불필요했음)
```bash
# 1) NAT SG에 원래 규칙 2개 수동 복구
aws ec2 authorize-security-group-ingress --group-id <nat-sg> \
  --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=172.30.0.0/16}]'
aws ec2 authorize-security-group-egress --group-id <nat-sg> \
  --ip-permissions 'IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]'
# 2) 약 1분 후 컨트롤러가 스스로 ALB 2개 삭제 + finalizer 해제 (자동)
# 3) terraform destroy 재실행
```
> **통신만 되살리면 컨트롤러가 정상 절차대로 정리한다.** finalizer 강제 제거는 타겟그룹이
> 고아로 남으므로, 통신 복구가 불가능할 때의 최후 수단으로만 쓸 것.

### 부수 효과 — 항목 3(엔드포인트 IP 제한)이 진단을 도왔음
배스천이 이미 terminate돼 kubectl 경로가 없었으나, **작업 PC가 허용 CIDR(`/32`) 안이었으므로**
`aws eks get-token` + `curl`로 K8s REST API를 직접 호출해 파드 상태·로그·finalizer를 확인할 수 있었음.
(Windows Git Bash curl은 schannel 폐기목록 확인 실패로 `--ssl-no-revoke` 필요)

### 면접 설명
> "같은 교착이 세 번 재발했는데 매번 원인 리소스가 달랐습니다. NAT 인스턴스 → 퍼블릭 라우트 테이블 → 보안 그룹 규칙 순이었고,
> 공통 원인은 '모듈의 output을 참조하면 그 output을 만든 리소스 하나에만 순서가 걸린다'는 Terraform의 의존성 해석 방식이었습니다.
> 세 번째에야 패턴을 일반화해서, destroy 중 살아있어야 하는 컨트롤러의 의존성에 네트워크 모듈을 통째로 명시하는 것으로 정리했습니다."

---

## 부록 A. 조치 우선순위 로드맵

| 단계 | 항목 | 예상 작업량 | 결과 |
|------|------|-------------|------|
| **D-0 (오늘)** | #1 PAT 폐기 → State S3 이전 → 로컬/히스토리 정리 | 1~2h | ✅ 완료 (+#15 discord state 동반 이전) |
| **이번 주** | #2 SSH 제거 · #3 endpoint CIDR · #9 prefix delegation(+노드 롤링) | 반나절 | ✅ 완료 (클린 재구축이라 노드 롤링 불필요) |
| **다음 apply에 포함** | #5 SG 참조 · #6 ExternalDNS zone 제한 · #10 exec 토큰 · #11 ACM validation 참조 · #12 S3 endpoint · #13 schema init | 반나절 | ✅ 완료 (#5에 EFS 추가) |
| **하드닝 스프린트** | #7 ArgoCD internal · ESO 도입(#1 근본해결) · #14 Redis replication_group · #4 CloudFront OAC · #8 OIDC | 1~2주 (점진) | ✅ #7 완료 / ✅ #8 기구현 확인 / ✅ #14 완료 (2026-08-04 제로트러스트 DB 하드닝과 함께) / ⬜ ESO·#4 잔여 |

### 잔여 과제 (다음 스프린트)

> **2026-08-04 업데이트**: 잔여 과제는 [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md)로
> 이관해 추적한다 (전체 재점검에서 신규 발견 5건 추가 — 노드 SG 전 포트 개방,
> SSH 키 잔존, ArgoCD admin 비번 부활, NetworkPolicy 부재 등).
> 아래 ESO의 트리거 조건("state에 secret_string이 다시 들어가는 시점")은
> **redis auth_token + ArgoCD PAT 2건으로 이미 충족된 상태**다 — 백로그 B3.

| 항목 | 내용 | 트리거 조건 |
|------|------|-------------|
| ESO 도입 | External Secrets Operator로 Terraform이 시크릿을 만지지 않는 구조 전환 (#1 근본해결) | state에 `secret_string`이 다시 들어가는 시점 → **발동됨 (백로그 B3)** |
| #14 Redis 암호화 | `aws_elasticache_replication_group` + `transit_encryption_enabled` + `auth_token` | 실사용자 세션 데이터가 유의미해지는 시점 |
| #4 CloudFront OAC | 원본 버킷 완전 프라이빗화 + 캐싱/WAF | 트래픽 비용이 체감되거나 WAF가 필요해지는 시점 |
| RDS 하드닝 | `multi_az`, `deletion_protection`, `skip_final_snapshot=false`, `backup_retention` 상향 | 운영 전환 시 (현재는 학습용으로 의도적 완화) |

## 부록 B. 검증 명령어 모음

```bash
# 1. state 이전 후 시크릿 잔존 확인 (로컬에 남은 파일 대상)
grep -c "github_pat_\|secret_string" terraform.tfstate 2>/dev/null || echo "clean"

# 2. SSM 접속 확인
aws ssm start-session --target <bastion-id> --profile admin --region ap-northeast-2

# 3. EKS endpoint 접근 제한 확인
aws eks describe-cluster --name gochuchamchi-eks --profile admin \
  --query "cluster.resourcesVpcConfig.publicAccessCidrs"

# 9. prefix delegation 적용 확인
kubectl describe node | grep -A1 "Allocatable" | grep pods   # 110 나오면 성공
kubectl get ds -n kube-system aws-node -o yaml | grep -A1 PREFIX

# 12. S3 endpoint 경유 확인 (NAT 트래픽 감소 관찰)
aws ec2 describe-vpc-endpoints --profile admin \
  --filters Name=vpc-id,Values=<vpc-id> --query "VpcEndpoints[].ServiceName"

# 5. RDS SG 확인
aws ec2 describe-security-groups --group-ids <rds-sg-id> --profile admin \
  --query "SecurityGroups[].IpPermissions[].UserIdGroupPairs"
```

## 부록 C. 변경 이력

| 날짜 | 항목 | 내용 |
|------|------|------|
| 2026-07-29 | - | 최초 점검 및 보고서 작성 |
| 2026-07-29 | 전체 | 2차 점검(코드 대조 검증) — 항목 1 현황 정정, #15 discord 웹훅 평문 유출 신규 발견, #8 기구현 확인, #5에 EFS 누락분 추가 |
| 2026-07-29 | #1, #15 | 양쪽 state를 S3 백엔드(`gochuchamchi-tfstate-307223751140`, 버저닝+퍼블릭차단+SSE)로 이전, 로컬 평문 state 4개 삭제 |
| 2026-07-29 | #2,3,5,6,9,10,11,12,13 | 코드 조치 후 `terraform apply` (174 리소스) 완료 및 라이브 검증 |
| 2026-07-29 | #17 | apply 중 EFS StorageClass 403 발생 → `depends_on`에 `module.eks` 추가로 해결 |
| 2026-07-29 | #7 | ArgoCD internal ALB 전환 + 초기 admin 비밀번호 변경 |
| 2026-07-29 | #16 | HPA `FailedGetResourceMetric` 발견 → metrics-server addon 추가 |
| 2026-07-29 | #1 | GitHub PAT 로테이션 완료 (Secret RV 2390→33417, hard refresh 검증) |
| 2026-07-29 | #1 | 기존 PAT 폐기(Delete) 완료 — SSM 이력에 노출됐던 값 무효화 |
| 2026-07-29 | #18 | destroy 중 SG "규칙" 선삭제로 3차 교착 발생 → 컨트롤러 `depends_on`에 `module.nat_sg`/`module.add_node_sg` 추가 |
| 2026-07-30 | #7 | **재구축 후 재확인 — internal ALB는 유지, admin 비밀번호 변경은 초기화됨(미이행 상태로 회귀).** 코드에 없는 수동 조치는 destroy/apply로 사라짐 |
| 2026-07-30 | 신규 | EKS `endpoint_public_access_cidrs`를 단일 `/32` 하드코딩 → `list(string)` 변수로 전환. stale `/32`는 타인 재할당 위험이 있어 미사용 항목 삭제 원칙 명시 |

## 부록 D. 검증에 사용한 실제 명령 (배스천 경유)

로컬에 kubectl이 없고 EKS 엔드포인트가 `/32`로 제한된 환경에서, 배스천을 SSM으로 경유해 검증한 패턴:

```bash
# 배스천 인스턴스 ID 조회
BASTION_ID=$(aws ec2 describe-instances --profile admin --region ap-northeast-2 \
  --filters "Name=tag:Name,Values=gochuchamchi-bastion" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

# SSM RunShellScript로 kubectl 실행 (세션 진입 없이 단발 명령)
aws ssm send-command --instance-ids "$BASTION_ID" --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo -u ec2-user /home/ec2-user/bin/kubectl -n argocd get applications"]' \
  --region ap-northeast-2 --profile admin --query "Command.CommandId" --output text
```

> ⚠️ **주의**: SSM 명령 출력은 `get-command-invocation` 이력에 **30일간 보관되며 수동 삭제 불가**.
> Secret을 조회할 때 `-o yaml` / `-o json` / 이스케이프가 깨진 `-o jsonpath`를 쓰면 **base64 값이 그대로 이력에 남는다**
> (실제로 이번 점검 중 발생시켜 기존 PAT가 노출됐고, 로테이션으로 무효화함).
> 반드시 `-o custom-columns=RV:.metadata.resourceVersion,...` 처럼 **필드를 명시적으로 제한**할 것.

```bash
# ArgoCD UI 접근 (internal ALB — 호스트 기반 라우팅이라 hosts 등록 필수)
#   1) hosts에 추가(관리자 PowerShell): 127.0.0.1 argocd.gochuchamchi.shop
#   2) 포트포워딩 (한 줄로 실행 — cmd에서 \ 줄바꿈 불가)
aws ssm start-session --target <bastion-id> --profile admin --region ap-northeast-2 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<internal-alb-dns>"],"portNumber":["443"],"localPortNumber":["8443"]}'
#   3) 브라우저: https://argocd.gochuchamchi.shop:8443  (localhost:8443은 ALB가 404)
```

```powershell
# PAT 등 시크릿을 환경변수로 주입 (PowerShell 히스토리 파일에 안 남기기)
Set-PSReadLineOption -HistorySaveStyle SaveNothing   # 먼저 실행
$env:TF_VAR_argocd_git_pat = "<token>"
# 확인 (값 자체는 출력하지 않음)
if ($env:TF_VAR_argocd_git_pat) { "set, length=$($env:TF_VAR_argocd_git_pat.Length)" } else { "NOT SET" }
```

> `$env:`는 **해당 창에서만 유효**. 다른 창에서 `terraform apply`하면 값이 안 잡혀 Terraform이 프롬프트로 물어보고,
> 여기서 기존 값을 넣으면 **로테이션이 조용히 무효화된다**(실제로 1회 발생 — Secret의
> `managedFields[0].time`이 최초 생성 시각 그대로여서 발견).
