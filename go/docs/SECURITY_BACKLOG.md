# 보안 잔여 과제 백로그 (2026-08-04 전체 재점검)

SECURITY_AUDIT_REPORT(18개 항목, 대부분 조치완료)와 2026-08-04 제로트러스트 DB 하드닝
**이후에도 남아 있는** 문제만 모은 문서. 새 발견 5건 + 기존 추적 항목 정리.

## 우선순위 요약

| # | 항목 | 위험도 | 상태 (2026-08-04 **apply 완료 · 사이트 동작 검증 완료**) |
|---|---|---|---|
| B1 | 노드 SG가 VPC 전체에 전 포트 개방 | 🔴 높음 | ✅ 완료 — `add_node_sg` 인그레스 제거, `add_cluster_sg` 배스천 SG 참조로 축소 |
| B2 | 노드·NAT에 SSH 키페어 잔존 | 🟠 중간 | ✅ 완료 — `key_name` 전면 제거 |
| B3 | ArgoCD PAT가 tfstate에 평문 → ESO 도입 | 🟠 중간 (파급 큼) | ✅ 완료 — `eso.tf` + `charts/eso-config`, PAT 주입·ESO 동기화 확인(`SecretSynced`). **PAT 미주입 상태로 apply하면 앱이 통째로 안 뜬다**(2026-08-04 §4.3) |
| B4 | ArgoCD admin 초기 비밀번호가 재구축마다 부활 | 🟠 중간 | ✅ 코드완료 — `TF_VAR_argocd_admin_password_bcrypt` 설정해야 활성화 |
| B5 | NetworkPolicy 0개 — 클러스터 내부 east-west 무제한 | 🟡 낮음~중간 | ✅ 완료 — 단 최초 규칙에 **DNS 결함**이 있어 앱 전체 500. DNS egress를 서비스 CIDR까지 열어 수정(2026-08-04 §4.4) |
| B6 | 기타 알려진 잔여 | 🟡 낮음 | 🔶 부분 — GuardDuty ✅ / S3 OAC·verify-full·ECR IMMUTABLE·앱 계층 ⬜ (아래 사유) |

> **apply에서 실제로 드러난 결함 2건** (상세: `2026-08-04.md` §4)
> - **B3** — Terraform이 값 없는 Secret 컨테이너만 만들므로 **PAT 수동 주입이 안 되면
>   ArgoCD가 저장소에 붙지 못하고 앱이 배포되지 않는다.** apply는 성공하는데 사이트는
>   503(`Backend service does not exist`)이 된다. 재구축 체크리스트(runbook §5) 맨 앞에 넣었다.
> - **B5** — DNS egress를 VPC CIDR로만 열어 **DNS가 전면 차단**됐다. 파드는 kube-dns
>   **ClusterIP**(서비스 CIDR)로 질의하는데 그 대역이 VPC CIDR 밖이다. 3306/6379/443
>   규칙이 정확해도 호스트명을 못 풀어 전부 무의미해진다. netpol 검증은 반드시
>   `exec -- getent hosts <RDS 엔드포인트>`부터 할 것.

### apply 절차 (B1~B6 반영분)

1. `terraform init` (eso_pod_identity 모듈은 설치됨 — helm repo 추가는 apply가 알아서)
2. `terraform plan` 확인: `add_node_sg`/`add_cluster_sg` 규칙 교체, 노드그룹 launch template 변경(→롤링),
   NAT 인스턴스 **재생성**(key_name 제거), ESO 리소스 4개 create, `kubernetes_secret_v1.gitops_repo_creds` destroy,
   vpc-cni 설정 변경, NetworkPolicy 2개 create, GuardDuty detector create
3. `terraform apply` — 트래픽 적은 시간대 (노드 롤링 + NAT 재생성으로 수 분 단절 구간 있음)
4. **PAT 주입 (필수, 1회)** — 기존 PAT는 state에 노출됐던 값이므로 **재발급해서** 넣기.
   값을 argv에 싣지 않도록 파일 경유(주입 후 삭제, 파일 끝 개행 금지):
   ```
   aws secretsmanager put-secret-value --secret-id gochuchamchi/argocd/git-pat --secret-string file://pat.txt --region ap-northeast-2 --profile admin
   ```
   스코프는 `Contents: Read/write`(image-updater의 git write-back). 확인:
   `kubectl get externalsecret -n argocd` → `SecretSynced`/`Ready=True`
5. **DNS 확인** — netpol 적용 후 가장 먼저. 여기서 막히면 나머지 검증이 전부 무의미:
   `kubectl -n gochuchamchi exec deploy/gochuchamchi-web -- getent hosts <RDS 엔드포인트>`
6. 검증: 사이트 로그인/상품조회/이미지 업로드, `kubectl -n argocd get secret gochuchamchi-gitops-repo-creds`,
   ArgoCD UI 저장소 연결 상태, k8s-network-policies.tf 헤더의 검증 명령
7. 문제 시 롤백: NetworkPolicy만 문제면 `kubectl -n gochuchamchi delete netpol --all` (한 줄, 즉효)

---

## 용어 해설 — "ESO 트리거가 발동됐다"는 게 무슨 말인가

**배경.** `terraform.tfstate`는 Terraform이 관리하는 모든 리소스의 속성값을 통째로
저장하는 파일이다. 변수에 `sensitive = true`를 붙여도 그건 **화면 출력만 가려줄 뿐**,
state 파일 안에는 값이 평문 JSON으로 그대로 들어간다. 그래서 state에 시크릿이 들어가면
"state 파일을 읽을 수 있는 사람/파이프라인 = 시크릿을 아는 사람"이 된다.

**7/29에 정한 규칙.** 감사 #1에서 state 안의 시크릿(GitHub PAT 등)을 전부 정리하고
state를 S3(암호화+잠금)로 옮기면서, 이렇게 기준을 정해뒀다:

> "앞으로 **state에 secret_string이 다시 들어가는 시점**이 오면, 그때는 임시조치가
> 아니라 ESO를 도입한다" — 이 조건문이 "ESO 도입 **트리거**"

**지금 상태.** 그 "다시 들어가는 시점"이 이미 와 있다. state에 시크릿이 현재 2개 있다:

| 시크릿 | 어디서 들어가나 | 왜 불가피했나 |
|---|---|---|
| Redis AUTH 토큰 | `redis.tf`의 `random_password` + `auth_token` 인자 | auth_token은 리소스 인자로만 설정 가능 |
| **ArgoCD GitHub PAT** | `argocd.tf:84` `kubernetes_secret_v1`의 data | ArgoCD 저장소 자격증명을 Terraform으로 만들고 있음 |

즉 **자신이 정한 도입 조건이 충족됐는데 ESO는 아직 없는 상태** — 이걸 "트리거가
발동됐다"고 표현한 것. 규칙대로라면 ESO 도입이 지금 해야 할 일 목록에 올라와 있어야
맞다. (앱 DB 비밀번호는 8/4 작업으로 state를 우회시켰지만, 위 2개는 구조상 남아 있음)

**ESO(External Secrets Operator)가 뭔가.** 클러스터 안에 설치하는 오퍼레이터로,
AWS Secrets Manager의 값을 **클러스터가 직접** 읽어서 K8s Secret으로 동기화해준다.
흐름이 이렇게 바뀐다:

```
지금:  Secrets Manager ─(terraform이 값을 읽음)→ tfstate에 평문 ─→ K8s Secret
ESO:   Secrets Manager ─(클러스터 안의 ESO가 직접 동기화)→ K8s Secret
                          └─ Terraform은 값을 아예 안 만짐 → state에 안 남음
```

---

## B1. 🔴 노드 SG가 VPC 전체에 전 포트 개방

### 현상

`securitygroups.tf`의 `add_node_sg`(EKS 워커 노드에 부착)가 VPC CIDR 전체
(`172.30.0.0/16`)에서 **모든 프로토콜·모든 포트** 인바운드를 허용한다.
`add_cluster_sg`(컨트롤플레인 443)도 소스가 VPC CIDR 전체다.

### 리스크

8/4 작업으로 RDS/Redis SG는 "네트워크 위치가 아니라 워크로드 정체성(SG 참조)을
신뢰"하도록 조였는데, 정작 노드 계층에는 이 원칙이 적용되지 않았다. NAT 인스턴스,
배스천 등 VPC 내 아무 자원이 침해되면 노드의 kubelet(10250), NodePort 전 범위로
측면이동이 가능하다. 제로트러스트 서사의 정확히 반대 지점이 노드에 남아 있는 것.

### 조치 방안

- EKS 모듈이 자체 생성하는 노드 SG(`node_security_group`)가 클러스터 내부 통신
  규칙을 이미 다 갖고 있다 → `add_node_sg`가 실제로 필요한 규칙이 뭔지부터 확인
  (아마도 "없음"이거나, 있어도 특정 포트+SG 참조 몇 개)
- `add_cluster_sg`의 443 소스를 VPC CIDR → `module.bastion_host_sg.id` SG 참조로 축소
  (컨트롤플레인에 사설로 붙는 건 배스천뿐. 노드는 EKS 모듈의 자체 SG로 통신)
- 검증: 적용 후 파드 스케줄/ALB 타겟 등록/`kubectl logs` 정상 동작 확인
  (kubelet 10250은 컨트롤플레인·모듈 SG 규칙으로 커버되는지 먼저 plan에서 확인)

---

## B2. 🟠 노드·NAT에 SSH 키페어 잔존

### 현상

감사 #2에서 배스천 SSH는 완전히 제거했지만(`ingress_rules = {}` + key 없음),
노드그룹(`main.tf`의 `key_name`)과 NAT 인스턴스(`main.tf`의 `key_name`)에는
`gochuchamchi-key-v2` 키페어가 아직 붙어 있다.

### 리스크

노드그룹과 NAT 모두 SSM(Session Manager)이 붙어 있어 키가 필요 없다. B1(VPC 내부
전 포트 개방)과 결합하면 VPC 내부에서 노드 22번 포트가 실제로 열려 있는 상태 —
키 파일 하나 유출이 노드 쉘 접근으로 직결된다.

### 조치 방안

`key_name` 두 줄 제거(+ `variables.tf`의 `key_name` 변수 자체 제거). 접속은 지금도
SSM으로 하고 있으므로 운영 변화 없음. 노드그룹은 launch template 변경이라 **노드
롤링 발생** — 트래픽 적은 시간대에 적용.

---

## B3. 🟠 ArgoCD PAT가 tfstate에 평문 → ESO 도입 (위 용어 해설 참고)

### 현상

`argocd.tf`의 `kubernetes_secret_v1.gitops_repo_creds`가 `var.argocd_git_pat`를
받아 K8s Secret을 만들면서 PAT가 state에 평문으로 남는다. Redis auth_token도 동일.

### 리스크

state는 S3 암호화+잠금 뒤에 있어 즉시 위험은 아니지만, 이 PAT는 gitops 저장소
**Contents: Read/write** 권한이다. 탈취 시나리오가 공급망 공격으로 직결된다:
PAT로 gitops에 커밋 → ArgoCD가 그 매니페스트를 **자동으로 클러스터에 배포**.
state 접근 = 클러스터 배포 권한과 등가가 되는 셈.

### 조치 방안 (ESO 도입 — 1~2일)

1. PAT·Redis AUTH 토큰을 Secrets Manager로 이동 (PAT는 이 기회에 로테이션)
2. ESO helm 차트 설치 + Pod Identity로 해당 시크릿 2개만 Get 권한 부여
   (8/4에 만든 "정확한 ARN만" 원칙 그대로)
3. `ExternalSecret` CR 2개 작성 → `kubernetes_secret_v1` 리소스 2개 삭제
4. 검증: `terraform state pull | Select-String "password\|pat"` 에서 값 미검출
5. 앱 DB 시크릿(`gochuchamchi/app/db-credentials`)도 이관하면 배스천의 K8s Secret
   주입 단계를 없앨 수 있음 (DB_SECRET_SETUP.md 참고)

---

## B4. 🟠 ArgoCD admin 초기 비밀번호가 재구축마다 부활

### 현상

2026-07-30 변경 이력에 이미 기록된 문제: admin 비밀번호 변경은 UI 수동 조치라
destroy/apply 후 `argocd-initial-admin-secret`(초기 비밀번호) 상태로 회귀한다.
**지금도 초기 비밀번호일 가능성이 높다.**

### 리스크

internal ALB라 인터넷 노출은 없지만, ArgoCD는 argocd.tf 주석에 스스로 적어둔
"클러스터 admin급 권한 + PAT를 쥔 최고가치 타겟"이다. 초기 비밀번호는 네임스페이스
접근 권한만 있으면 누구나 `kubectl get secret`으로 읽을 수 있다.

### 조치 방안

- 차트 values에 `configs.secret.argocdServerAdminPassword`(bcrypt 해시)를 코드로 지정
  → 재구축해도 유지. 해시 원문은 state에 안 들어가고 해시만 들어감
- 적용 후 `argocd-initial-admin-secret` 삭제가 자동으로 안 되면 수동 삭제 1회
- (장기) admin 계정 비활성 + SSO — 포트폴리오 단계에서는 과함

---

## B5. 🟡 NetworkPolicy 0개 — 클러스터 내부 east-west 무제한

### 현상

클러스터에 NetworkPolicy가 하나도 없다. 모든 파드가 노드 SG를 공유하므로 grafana,
external-dns, image-updater 등 **어떤 파드든** RDS 3306 / Redis 6379에 네트워크로
도달할 수 있다.

### 리스크

지금은 DB 계정 분리(DML만)·REQUIRE SSL·Redis AUTH가 2차 방어를 해주지만,
"파드 하나가 침해되면"의 가정에서 네트워크 계층 차단이 없다. RDS SG의 "EKS 노드만
허용"은 **노드 단위**지 파드 단위가 아니다.

### 조치 방안

- vpc-cni addon에 `enableNetworkPolicy: "true"` (main.tf의 configuration_values에 추가)
- gochuchamchi 네임스페이스에 기본 거부 + 앱 파드만 3306/6379 egress 허용 정책
- 시스템 네임스페이스는 건드리지 않는 것부터 시작 (외부 컨트롤러들이 많아 깨지기 쉬움)

---

## B6. 🟡 기타 알려진 잔여

| 항목 | 내용 | 상태/사유 |
|---|---|---|
| GuardDuty 미활성 | 위협 **탐지** 계층 부재 해소 | ✅ `guardduty.tf` — 기본 탐지 활성(30일 무료). 확장 기능(EKS Protection 등)은 운영 전환 시 |
| S3 이미지 버킷 퍼블릭 read | CloudFront OAC + WAF로 이관 | ⬜ 보류 — 앱이 S3 URL을 직접 생성하는 구조라 **앱 코드 수정 없이는 이미지가 깨짐**. 앱 저장소와 함께 진행해야 함 |
| JDBC `sslMode=trust` → `verify-full` | RDS CA 번들을 파드에 마운트 필요 | ⬜ 보류 — Deployment가 gitops 저장소 관리라 **이 저장소만으로는 볼륨 마운트 불가**. gitops 수정과 함께 진행 |
| ECR `MUTABLE` + latest 태그 | digest 고정 / IMMUTABLE 전환 | ⬜ 보류 — 현재 CI(latest 덮어쓰기)·Image Updater(latest 전략)가 깨짐. 워크플로 재설계와 세트 |
| 앱 계층 미점검 | 세션 쿠키 플래그, CSRF, 업로드 검증 등 | ⬜ 별도 — gochuchamchi-spring 저장소 점검 필요 |
| Redis auth_token state 잔존 | ElastiCache **리소스 인자**라 Terraform이 값을 직접 넣어야 함 — ESO로도 구조적으로 못 뺌 (`eso.tf` 주석 참고) | ⬜ 한계 — 완전 제거는 out-of-band 로테이션(ignore_changes + CLI) 설계 필요. state는 S3 암호화+잠금 뒤 |

---

## 진행 기록

| 날짜 | 항목 | 내용 |
|---|---|---|
| 2026-08-04 | - | 최초 작성 (제로트러스트 DB 하드닝 후 전체 재점검) |
| 2026-08-04 | B1,B2 | `add_node_sg` 인그레스 전면 제거 + `add_cluster_sg` 배스천 SG 참조로 축소, `key_name` 변수·사용처 전면 제거 (SETUP-NEW-WORKER.txt 동기화) |
| 2026-08-04 | B3 | ESO 도입 — `eso.tf`(Secret 컨테이너 + pod identity 최소권한 + helm 2개) + `charts/eso-config`(ClusterSecretStore/ExternalSecret). `kubernetes_secret_v1.gitops_repo_creds`·`var.argocd_git_pat` 삭제 → PAT의 state 경유 자체가 소멸. apply 후 PAT 재발급·주입 필요 |
| 2026-08-04 | B4 | `argocd_admin_password_bcrypt` 변수(bcrypt 해시만 허용하는 validation) + 차트 `configs.secret` 조건부 주입. runbook §1.3 동기화 |
| 2026-08-04 | B5 | vpc-cni `enableNetworkPolicy=true` + `k8s-network-policies.tf` (gochuchamchi ns 기본거부, 웹앱은 VPC→8080 인그레스 / DNS·3306·6379·443·pod-identity-agent 이그레스만) |
| 2026-08-04 | B6 | `guardduty.tf` 기본 탐지 활성. 나머지 4건은 보류 사유 명시(위 표) — 이 저장소 단독으로 조치 불가한 것들 |
