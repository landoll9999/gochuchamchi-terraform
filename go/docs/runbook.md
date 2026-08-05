# 운영 런북 — 자주 쓰는 명령어

작업 목적별로 찾아 쓰는 치트시트입니다. 원인 분석과 배경은 날짜별 기록([README.md](README.md))과 [pitfalls-checklist.md](pitfalls-checklist.md)에 있습니다.

**전제**: 리전 `ap-northeast-2`, AWS 프로필 `admin`, 로컬 PC는 Windows PowerShell.

---

## 0. 먼저 확인할 것 — 재생성될 때마다 바뀌는 값

아래 값들은 **destroy/apply마다 바뀝니다.** 명령어를 복사하기 전에 현재 값을 확인하세요.

| 값 | 확인 방법 | 바뀌는 시점 |
|---|---|---|
| 배스천 인스턴스 ID | `terraform output bastion_ip` 로는 안 나옴 → 아래 명령 | 배스천 재생성마다 |
| ALB DNS 이름 | 아래 명령 | ALB 재생성마다 |
| 내 공인 IP | `curl checkip.amazonaws.com` | 작업 네트워크 변경 시 |

```powershell
cd C:\terraform\go\go\terraform

# 고정 값들 (엔드포인트/ARN/버킷 등)
terraform output

# 배스천 인스턴스 ID
aws ec2 describe-instances --filters "Name=tag:Name,Values=gochuchamchi-bastion" "Name=instance-state-name,Values=running" `
  --region ap-northeast-2 --profile admin --query "Reservations[].Instances[].InstanceId" --output text

# ALB 목록 (Scheme으로 앱/ArgoCD 구분)
aws elbv2 describe-load-balancers --region ap-northeast-2 --profile admin `
  --query "LoadBalancers[].{Name:LoadBalancerName,Scheme:Scheme,DNS:DNSName,State:State.Code}" --output table
```

**작업 네트워크가 바뀌었으면 먼저 이것부터** — 안 하면 `kubectl`/`terraform apply`가 전부 TCP 타임아웃 (2026-07-30 §2):

```powershell
curl checkip.amazonaws.com
aws eks describe-cluster --name gochuchamchi-eks --region ap-northeast-2 --profile admin `
  --query "cluster.resourcesVpcConfig.publicAccessCidrs" --output text
```
불일치하면 `terraform/variables.tf`의 `endpoint_public_access_cidrs`에 추가 후:
```powershell
terraform apply -target=module.eks   # 엔드포인트만 먼저 (2~5분)
```
> 안 쓰는 `/32`는 삭제할 것 — 유동 IP는 타인에게 재할당됨

---

## 1. 접속

### 1.1 kubectl (로컬 PC에서 직접)

내 IP가 EKS 허용목록에 있으면 배스천 없이 바로 됩니다.

```powershell
aws eks update-kubeconfig --name gochuchamchi-eks --region ap-northeast-2 --profile admin
kubectl get nodes
```

### 1.2 배스천 (SSM)

```powershell
aws ssm start-session --target <bastion-instance-id> --region ap-northeast-2 --profile admin
```
접속 직후 **반드시** 사용자 전환 (기본 접속자는 `ssm-user`이고 `/home/ec2-user`가 700이라 kubectl 접근 불가):
```bash
sudo su - ec2-user     # '-' 필수 (로그인 셸이어야 PATH/kubeconfig 적용)
```
그래도 `kubectl: command not found`이면:
```bash
export PATH=$PATH:/home/ec2-user/bin
export KUBECONFIG=/home/ec2-user/.kube/config
```

> 공인 IP(`terraform output bastion_ip`)로 **직접 SSH는 불가** — SG 인바운드가 0개이고 모든 접속이 SSM 경유입니다.

### 1.3 ArgoCD UI

> **변경 예정 (2026-08-05, dev 브랜치)** — ALB를 `internet-facing` + `inbound-cidrs`(= `endpoint_public_access_cidrs`)로 바꿔 **`https://argocd.gochuchamchi.shop` 직접 접속**으로 전환합니다. 그 apply가 끝나면 아래 port-forward 절차 대신 브라우저에서 도메인을 바로 열면 됩니다. 접속이 안 되면 먼저 **현재 IP가 `endpoint_public_access_cidrs`에 있는지** 확인하세요 — 목록 밖에서는 TCP 연결 단계에서 끊깁니다(§2026-08-05 §2). 아직 apply 전이라면 아래 절차가 유효합니다.

ArgoCD ALB는 **internal**이라 `https://argocd.gochuchamchi.shop`을 브라우저에서 직접 열면 타임아웃됩니다(정상). port-forward로 붙습니다.

```powershell
kubectl port-forward -n argocd svc/argocd-server 8080:80
```
→ 브라우저 **`http://localhost:8080`**

- **`8080:80`** 이고 **`http`** 입니다. `8080:443` + `https`로 붙으면 `connection reset by peer`로 끊깁니다 — ALB가 TLS를 종료하는 구성이라 파드는 평문으로 뜹니다
- **이 창을 닫으면 터널이 죽습니다.** 브라우저는 별도 창에서
- 계정 `admin`, 비밀번호:
  - `TF_VAR_argocd_admin_password_bcrypt`를 설정해서 apply했다면(백로그 B4) **그 해시의 원본 비밀번호**로 로그인 — 재구축해도 유지됩니다
  - 설정 안 했다면 초기 비밀번호:
  ```powershell
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
  ```

### 1.4 RDS (MariaDB) — 배스천에서만

RDS는 `publicly_accessible = false`입니다. 배스천 접속(§1.2) 후 **아래를 통째로 복사해서 붙여넣으세요.**

**① 로컬 PowerShell** — 인스턴스 ID는 §0에서 조회 (재구축마다 바뀝니다)

```powershell
aws ssm start-session --target <bastion-instance-id> --region ap-northeast-2 --profile admin
```

**② 배스천 접속 직후**

```bash
sudo su - ec2-user
```

> **(2026-08-04 제로트러스트 이후)** `--ssl`이 **필수**입니다 — `require_secure_transport=1`이라 평문 접속은 핸드셰이크에서 거부됩니다. K8s Secret에는 이제 **앱 계정(`gochuchamchi-db-app`) 비밀번호만** 있고, 마스터(admin) 비밀번호는 Secrets Manager에만 있습니다(구 `gochuchamchi-db-secret`은 삭제됨).

**③ 앱 계정으로 접속 — 일상 조회는 이걸로 (DML만 가능)**

```bash
which mysql || sudo dnf install -y mariadb105
rm -f ~/.my.cnf
DB_HOST=$(kubectl -n gochuchamchi get cm gochuchamchi-config -o jsonpath='{.data.DB_HOST}')
DB_PASS=$(kubectl -n gochuchamchi get secret gochuchamchi-db-app -o jsonpath='{.data.DB_PASS}' | base64 -d)
echo "HOST=$DB_HOST  PASS_LEN=${#DB_PASS}"
MYSQL_PWD="$DB_PASS" mysql --ssl -h "$DB_HOST" -u gochuchamchi_app gochuchamchi
```

**④ 마스터(admin)로 접속 — DDL/GRANT 등 관리 작업일 때만**

ARN은 로컬에서 `terraform output -raw rds_secret_arn`으로 조회해서 붙여넣습니다 (재구축마다 바뀝니다):

```bash
SECRET_ARN='<terraform output -raw rds_secret_arn 값>'
DB_HOST=$(kubectl -n gochuchamchi get cm gochuchamchi-config -o jsonpath='{.data.DB_HOST}')
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region ap-northeast-2 --query SecretString --output text | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")
MYSQL_PWD="$DB_PASS" mysql --ssl -h "$DB_HOST" -u admin gochuchamchi
```

**막힐 때**

```bash
export PATH=$PATH:/home/ec2-user/bin                        # kubectl: command not found
export KUBECONFIG=/home/ec2-user/.kube/config
rm -f ~/.my.cnf                                             # Access denied (using password: NO)
kubectl -n gochuchamchi get secret gochuchamchi-db-app      # PASS_LEN=0
mysql --ssl ...                                             # ERROR 3159 (secure transport required) -> --ssl 누락
```

**왜 앱 비밀번호는 kubectl이고 마스터는 Secrets Manager인가** — 앱 자격증명은 배스천 프로비저너가 K8s Secret(`gochuchamchi-db-app`)으로 직접 주입하므로(`db-zero-trust.tf`) kubectl로 꺼내는 게 제일 빠릅니다. 마스터 비밀번호는 제로트러스트 전환으로 **K8s에서 완전히 제거**됐고(state에도 없음), 배스천 IAM이 이 스택의 마스터 시크릿 ARN 1개에만 GetSecretValue를 갖고 있어 Secrets Manager 경유가 유일한 경로입니다. ARN은 재구축마다 바뀌므로 하드코딩하지 말고 매번 `terraform output`으로 조회하세요 (배스천 역할에는 `rds:DescribeDBInstances`가 없어 ARN을 스스로 못 찾습니다).

**왜 `MYSQL_PWD`인가** — mysql은 비밀번호를 ①명령줄 `-p` ②옵션 파일 ③`MYSQL_PWD` 순으로 찾습니다.
- ①은 `ps` 목록과 SSM 로그에 비밀번호가 그대로 남아서 못 씁니다
- ②(`~/.my.cnf`)는 옵션 파일이 `#`을 주석으로 해석하기 때문에, RDS가 생성한 랜덤 비밀번호에 `#`이 섞이면 값이 잘려 조용히 실패합니다
- ③은 `ps`에 안 나오고 파싱 규칙도 없어 특수문자에 안전합니다. 명령 앞에 `VAR=값`을 붙이면 그 명령에만 적용되고 셸에 남지 않습니다

주의할 점:

- **`max_connections`가 30**이고 HikariCP가 파드당 5개를 씁니다. 확인 후 반드시 `exit` (방치하면 `Too many connections`)
- **`SHOW TABLES`가 비어 있으면** 스키마가 적용되지 않은 것입니다 → **§5.1**. `USE gochuchamchi`가 되는데 테이블만 없는 상태가 정상처럼 보이니 주의 (DB 자체는 RDS의 `DBName` 설정이 만듭니다)
- **`Access denied ... (using password: NO)`가 나오면** 순서대로 확인하세요
  1. `~/.my.cnf`가 남아 있는지 — mysql은 이 파일을 **옵션 없이도 자동으로 읽고**, 옵션 파일이 `MYSQL_PWD`보다 우선순위가 높습니다. 깨진 파일 하나가 이후 모든 접속을 오염시킵니다. `rm -f ~/.my.cnf`
  2. `PASS_LEN=0`이면 kubectl이 실패한 것입니다. `kubectl -n gochuchamchi get secret gochuchamchi-db-app`로 Secret 존재 여부부터 확인 — 없으면 프로비저너가 안 돈 것: 로컬에서 `terraform taint null_resource.provision_app_db_user` 후 `terraform apply`

### 1.5 Redis — 배스천에서만

**(2026-08-04 제로트러스트 이후)** `--tls`와 AUTH가 **필수**입니다. 비밀번호는 `-a` 대신 `REDISCLI_AUTH` 환경변수로 넘깁니다 (`-a`는 `ps` 목록에 그대로 노출).

```bash
sudo dnf install -y redis6      # 없으면

REDIS_HOST=$(kubectl -n gochuchamchi get cm gochuchamchi-config -o jsonpath='{.data.SPRING_DATA_REDIS_HOST}')
REDIS_PASS=$(kubectl -n gochuchamchi get secret gochuchamchi-redis-secret -o jsonpath='{.data.SPRING_DATA_REDIS_PASSWORD}' | base64 -d)

REDISCLI_AUTH="$REDIS_PASS" redis6-cli --tls -h "$REDIS_HOST" -p 6379 PING
REDISCLI_AUTH="$REDIS_PASS" redis6-cli --tls -h "$REDIS_HOST" KEYS 'gochuchamchi:session*'
```

엔드포인트는 RDS와 같은 이유로 ConfigMap에서 가져옵니다 — 재구축하면 주소가 바뀝니다.

- `NOAUTH Authentication required` → AUTH 누락 (정상 동작의 증거이기도 함 — 무인증 차단 확인)
- 응답 없이 멈춤/연결 리셋 → `--tls` 누락

---

## 2. 상태 확인

### 2.1 앱

```powershell
kubectl -n gochuchamchi get all
kubectl -n gochuchamchi get pods -o wide
kubectl -n gochuchamchi logs -l app=gochuchamchi-web --tail=100
kubectl -n gochuchamchi describe pod -l app=gochuchamchi-web | Select-Object -Last 30
kubectl -n gochuchamchi get deploy gochuchamchi-web -o jsonpath='{.spec.template.spec.containers[*].image}'
```

### 2.2 컨트롤러

```powershell
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=30
kubectl -n external-dns logs deployment/external-dns --tail=30
kubectl -n argocd get applications
kubectl -n argocd logs deployment/argocd-image-updater-controller --tail=30
```

### 2.3 ALB / 타겟 헬스

**타겟그룹을 `TargetGroups[0]`으로 조회하지 말 것** — ALB가 여러 개라 엉뚱한 그룹을 봅니다. 이름으로 필터하세요.

```powershell
# 앱 타겟그룹 헬스 (k8s-gochucha-* 가 앱, k8s-argocd-* 가 ArgoCD)
$tg = aws elbv2 describe-target-groups --region ap-northeast-2 --profile admin `
  --query "TargetGroups[?starts_with(TargetGroupName,'k8s-gochucha')].TargetGroupArn" --output text
aws elbv2 describe-target-health --target-group-arn $tg --region ap-northeast-2 --profile admin `
  --query "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}" --output table
```

| State | 의미 |
|---|---|
| `initial` / `Elb.RegistrationInProgress` | 등록 중 (1~2분 후 정상) |
| `healthy` | 정상 |
| `unhealthy` | 파드 헬스체크 실패 → 파드 로그 확인 |
| **타겟 0개** | 파드가 아예 없음 → `kubectl get pods`부터 |

### 2.4 DNS / 사이트

ALB가 재생성된 뒤에는 레코드가 최신 ALB를 가리키는지 교차 확인해야 합니다.

```powershell
aws route53 list-resource-record-sets --hosted-zone-id Z09871632JXCAV3R6Z65M --profile admin `
  --query "ResourceRecordSets[?Type=='A'].{Name:Name,Alias:AliasTarget.DNSName}" --output table

curl.exe -s -o NUL -w "%{http_code}`n" https://gochuchamchi.shop
```

### 2.5 ECR 이미지

```powershell
aws ecr describe-images --repository-name gochuchamchi --region ap-northeast-2 --profile admin `
  --query "sort_by(imageDetails,&imagePushedAt)[].{Tags:imageTags,Pushed:imagePushedAt}" --output table
```
**비어 있으면 파드가 `ImagePullBackOff`가 됩니다** → §3.1로

---

## 3. 배포

### 3.1 앱 재배포 (이미지 빌드 → ECR → ArgoCD 자동 sync)

```powershell
gh workflow run "Deploy to Amazon ECR" --repo landoll9999/gochuchamchi-spring
gh run watch --repo landoll9999/gochuchamchi-spring
```
이후 흐름은 자동입니다: ECR push → Image Updater 감지 → `gochuchamchi-gitops` write-back 커밋 → ArgoCD sync → 롤링 업데이트

### 3.2 `ImagePullBackOff` 복구

이미지를 올려도 **최대 5분간 자동 회복되지 않습니다** (kubelet pull 백오프). 기다리지 말고 파드를 지우세요.

```powershell
kubectl -n gochuchamchi delete pod -l app=gochuchamchi-web
kubectl -n gochuchamchi rollout status deploy/gochuchamchi-web --timeout=180s
```
> GitOps 관리 리소스이므로 `rollout restart`(template에 annotation 추가)보다 **파드 삭제**가 깔끔합니다

### 3.3 강제 재기동 / ArgoCD 수동 sync

```powershell
kubectl -n gochuchamchi rollout restart deploy/gochuchamchi-web
kubectl -n argocd patch application gochuchamchi --type merge -p '{\"operation\":{\"sync\":{}}}'
```

---

## 4. Terraform

```powershell
cd C:\terraform\go\go\terraform

terraform validate
terraform plan
terraform apply
terraform state list
```

### 4.1 apply 시 주의

- **작업 네트워크가 바뀌었으면 §0을 먼저** — 안 하면 `kubernetes_*`/`helm_release.*`만 전부 타임아웃되고 **apply가 절반만 성공**합니다
- 엔드포인트 허용목록을 고쳤다면 2단계로:
  ```powershell
  terraform apply -target=module.eks
  terraform apply
  ```
- 로컬 Helm 차트(`charts/`)의 템플릿만 고치면 반영 안 됨 → `Chart.yaml`의 `version`도 올릴 것
- **`plan -out`으로 계획을 파일에 박고 그 파일로 apply할 것** — refresh 사이에 상태가 바뀌어도 확인한 계획만 실행됩니다. 인자에 `.`이 있으므로 **따옴표 필수**:
  ```powershell
  terraform plan "-out=tfplan.binary"
  # 출력에서 "N to add, N to change, 0 to destroy" 를 눈으로 확인한 뒤
  terraform apply "tfplan.binary"
  ```
- **`AlreadyExists` 계열 에러(`BucketAlreadyOwnedByYou`, `EntityAlreadyExists`, `Limit exceeded`)는 지우지 말고 `import`** — "실물은 있는데 state가 모른다"는 뜻입니다. 특히 S3 버킷은 이름이 계정 전역 유일이라 우회할 수 없습니다:
  ```powershell
  terraform import "aws_s3_bucket.cloudwatch_log_archive" "gochuchamchi-cloudwatch-log-archive-307223751140"
  terraform plan   # 반드시 "0 to destroy" 확인 후 apply
  ```
  import 직후 plan에서 **교체가 계획되지 않는지 반드시 볼 것** — 코드에 없는 설정(Object Lock 등)이 실물에 켜져 있으면 교체가 잡힐 수 있습니다 (2026-08-04 §5.6, 2026-08-05 §1)

### 4.2 destroy 시 주의

destroy는 **ALB 정리 교착**이 반복 발생한 이력이 있습니다 (2026-07-29 §1.2, §1.2-1, §1.2-2 — 3회).

```powershell
terraform destroy
```

멈추면 (`Ingress ... still exists`, `Unable to uninstall Helm release argocd`) — **finalizer를 강제로 뜯기 전에 통신 복구를 먼저** 시도하세요. 컨트롤러가 살아있으면 경로만 되살려주면 알아서 정리합니다.

```powershell
# 1. 컨트롤러 로그에서 i/o timeout 확인
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=30

# 2. 무엇이 먼저 지워졌는지 순서대로 확인
aws ec2 describe-route-tables --region ap-northeast-2 --profile admin --query "RouteTables[].{ID:RouteTableId,Routes:Routes[].GatewayId}"
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=<nat-sg>" --region ap-northeast-2 --profile admin
```

| 증상 | 먼저 지워진 것 | 복구 |
|---|---|---|
| NAT 인스턴스 없음 | NAT/private 라우트 | 재생성 어려움 → finalizer 강제 제거 |
| 전부 살아있는데 통신만 안 됨 | public 라우트 테이블 | IGW 경로 수동 복구 |
| 전부 살아있고 라우트도 정상 | **SG "규칙"** (그룹은 남아있음) | 규칙 수동 복구 → 1분 후 자동 정리됨 |

**destroy 후 확인** (과금/고아 리소스):
```powershell
aws ec2 describe-addresses --region ap-northeast-2 --profile admin          # 미사용 EIP
aws elbv2 describe-target-groups --region ap-northeast-2 --profile admin    # 고아 타겟그룹
```

#### 4.2-1 destroy가 ALB 말고 다른 데서 막힐 때 (2026-08-04 §5)

| 증상 | 원인 | 조치 |
|---|---|---|
| **helm uninstall 실패 + 네임스페이스 고착 + `context deadline exceeded`가 동시에** | **Kyverno 고아 웹훅** (아래 최우선 확인) | 웹훅 삭제 |
| `timeout while waiting ... (timeout: 5m0s)` | AWS 비동기 작업이 기본 타임아웃 초과 | **AWS 실물부터 조회.** 이미 끝나 있으면 `terraform state rm`(delete 실패) 또는 `untaint`(create 실패) |
| 네임스페이스가 `Terminating`에서 안 끝남 | `NotReady` 노드의 파드 **또는 Kyverno 웹훅** | `kubectl get ns <n> -o json`의 condition으로 남은 gvr 확인 → `kubectl delete pod --grace-period=0 --force` |
| `BucketNotEmpty` | 버전 누적 | `force_destroy = true`. **단, 고친 뒤 apply를 한 번 돌려야 반영됨**(아래) |
| `BucketNotEmpty`인데 `force_destroy`가 이미 true | **Object Lock COMPLIANCE** | 기한 전엔 못 지움 → `terraform state rm`으로 관리 제외, 기한 후 수동 삭제 |
| `Error locating chart` / `Kubernetes cluster unreachable` | 작업 PC 네트워크(PMTUD) | **인프라 문제 아님.** 재시도로 진행됨 → §6.3 |

**⚠️ 최우선 확인 — `kubectl delete`조차 거부당하면 Kyverno 웹훅이다** (2026-08-04 §6.1)

```
Error from server (InternalError): failed calling webhook "validate.kyverno.svc-fail":
service "kyverno-svc" not found
```

Kyverno의 resource webhook은 helm이 아니라 컨트롤러가 런타임에 등록하므로,
`helm uninstall` 후에도 웹훅만 남는다. `failurePolicy: Fail`이라 API 서버가 모든
변경 요청을 거부하고, 그 결과 **위 표의 여러 증상이 한꺼번에** 나타난다.

```powershell
kubectl get validatingwebhookconfigurations -o name | Select-String kyverno
kubectl get svc -n kyverno          # 비어 있으면 고아 확정
kubectl delete validatingwebhookconfiguration <위에서 나온 것들>
```

코드에는 `kyverno.tf`의 `failurePolicy = "Ignore"`로 예방해두었다.

⚠️ **`terraform destroy`는 config가 아니라 prior state를 읽는다.** `force_destroy`를
`.tf`에서 고치고 바로 destroy하면 반영되지 않는다. 실제 state 값 확인:

```powershell
aws s3 cp "s3://gochuchamchi-tfstate-307223751140/eks/terraform.tfstate" state.json --profile admin
```

⚠️ **Object Lock 확인은 파괴적 작업 전에 실물로** (코드 주석을 믿지 말 것):

```powershell
aws s3api get-object-lock-configuration --bucket <bucket> --profile admin
aws s3api get-object-retention --bucket <bucket> --key <key> --version-id <vid> --profile admin
```

`Mode: COMPLIANCE`는 **루트 계정도 기한 단축·삭제가 불가능하다.**

---

## 5. 재구축 후 복구 체크리스트

**Terraform 코드 밖에 있는 상태는 destroy/apply에서 살아남지 못합니다.** apply 성공 후 아래를 순서대로 확인하세요.

- [ ] **ArgoCD PAT 주입** — **가장 먼저.** 안 하면 앱이 아예 배포되지 않습니다 (2026-08-04 §4.3). Terraform은 값이 빈 Secret 컨테이너만 만들고 값은 사람이 넣습니다
  ```
  aws secretsmanager put-secret-value --secret-id gochuchamchi/argocd/git-pat --secret-string file://pat.txt --region ap-northeast-2 --profile admin
  del pat.txt
  ```
  PAT 스코프는 `Contents: Read/write`(image-updater의 git write-back 때문). **파일 끝에 개행이 있으면 인증이 조용히 실패**합니다. 주입 확인:
  ```powershell
  kubectl get externalsecret -n argocd     # STATUS=SecretSynced, READY=True 여야 함
  ```
- [ ] **파드에서 DNS가 되는지** — NetworkPolicy가 DNS를 막으면 앱이 전부 500입니다 (2026-08-04 §4.4)
  ```powershell
  kubectl -n gochuchamchi exec deploy/gochuchamchi-web -- getent hosts <RDS 엔드포인트>
  ```
- [ ] **apply 전: 지난 destroy에서 못 지운 리소스를 먼저 import** — AWS에 남아 있는데 state에 없으면 `BucketAlreadyOwnedByYou` / `Limit exceeded`로 apply가 막힙니다 (2026-08-04 §5.1, §5.6). import 후 **반드시 `plan`으로 재생성 계획이 없는지 확인**
  ```powershell
  # Object Lock 때문에 남은 로그 아카이브 버킷 (2026-09-02까지 삭제 불가)
  terraform import aws_s3_bucket.cloudwatch_log_archive gochuchamchi-cloudwatch-log-archive-307223751140
  terraform plan "-target=aws_s3_bucket.cloudwatch_log_archive"   # "No changes"여야 함

  # 계정당 1개인 리소스 — AWS가 자동 생성해둔 게 있으면 인수
  aws ce get-anomaly-monitors --profile admin --region us-east-1 --query "AnomalyMonitors[?MonitorType=='DIMENSIONAL'].MonitorArn" --output text
  terraform import aws_ce_anomaly_monitor.services "<위 ARN>"
  ```
- [ ] **ECR 이미지 적재** — `aws ecr describe-images`가 비어있으면 §3.1 워크플로 실행 (`force_delete = true`라 destroy가 이미지까지 지웁니다)
- [ ] **DB 스키마 적용 확인** — `SHOW TABLES`에 4개(`users`/`notices`/`products`/`product_sizes`)가 보여야 합니다 → 없으면 **§5.1**
- [ ] **사이트 200 확인** — `curl` 5회 (§2.4). 503이면 §2.3의 타겟 수부터
- [ ] **Route 53 레코드가 신규 ALB를 가리키는지** — §2.4 교차 확인
- [ ] **ArgoCD admin 비밀번호 재변경** — 초기 비밀번호로 돌아갑니다
  ```powershell
  kubectl -n argocd delete secret argocd-initial-admin-secret   # 변경 후
  ```
- [ ] **회원 role 등 DB 직접 변경 원복 확인** — `schema.sql`은 테이블만 만들고 데이터는 관리하지 않습니다
  ```sql
  SELECT id, username, role FROM users WHERE role='admin';
  ```
- [ ] **배스천 인스턴스 ID 갱신** — `~/.ssh/config`의 `HostName` (VS Code Remote-SSH 쓰는 경우)
- [ ] **S3 정적 자산** — `aws_s3_object`로 코드에 넣지 않은 파일은 사라집니다 (과거 `texture.png` 403 사례)

### 5.1 DB 스키마 수동 적용

`null_resource.apply_db_schema`가 자동으로 해주지만, **실패해도 terraform이 성공으로 기록할 수 있습니다** (2026-08-03 §3). state에 리소스가 있어도 테이블이 없을 수 있으니 위 체크리스트로 실물을 확인하세요.

증상은 **회원가입 500**입니다. 앱 로그에 이렇게 찍힙니다:

```
BadSqlGrammarException: Table 'gochuchamchi.users' doesn't exist
```

`schema.sql`은 `CREATE TABLE IF NOT EXISTS` 기반이라 **몇 번 실행해도 안전합니다.** 배스천 접속(§1.4 ①②) 후:

```bash
export PATH=$PATH:/home/ec2-user/bin
export KUBECONFIG=/home/ec2-user/.kube/config

aws s3 cp s3://gochuchamchi-k8s-manifests-307223751140/db/schema.sql ~/schema.sql --region ap-northeast-2

# 스키마는 마스터(admin) 권한 필요 — 비밀번호는 Secrets Manager에서 (§1.4 ④)
SECRET_ARN='<terraform output -raw rds_secret_arn 값>'
DB_HOST=$(kubectl -n gochuchamchi get cm gochuchamchi-config -o jsonpath='{.data.DB_HOST}')
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region ap-northeast-2 --query SecretString --output text | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")

MYSQL_PWD="$DB_PASS" mysql --ssl -h "$DB_HOST" -u admin < ~/schema.sql
MYSQL_PWD="$DB_PASS" mysql --ssl -h "$DB_HOST" -u admin gochuchamchi -e 'SHOW TABLES; SELECT id,username,role FROM users;'
```

파드 재시작은 **불필요합니다** — 커넥션 풀은 그대로고 테이블만 생기면 바로 반영됩니다.

terraform 프로비저너 자체를 다시 돌리려면 (트리거가 그대로라 `apply`만으로는 재실행 안 됨):

```powershell
terraform taint null_resource.apply_db_schema
terraform apply
```

---

## 6. 트러블슈팅 빠른 판별

### 6.1 "접속이 안 된다"

| 에러 | 원인 | 조치 |
|---|---|---|
| `ERR_CONNECTION_TIMED_OUT` | 사설 IP로 직접 접속 (internal ALB) | 터널을 먼저 띄울 것 (§1.3) |
| `ERR_CONNECTION_REFUSED` | 로컬 리스너 없음 = port-forward 죽음 | port-forward 재실행, 창 열어두기 |
| `ERR_SSL_PROTOCOL_ERROR` / `connection reset` | 평문 리스너에 TLS 시도 | `https` → `http` |
| `HTTP 503` | 백엔드 타겟 없음 | §2.3 타겟 수 → 파드 상태 |
| `HTTP 503` + 본문 `Backend service does not exist` | **Service 자체가 없음** (ALB 컨트롤러가 넣는 fixed-response) | §6.7 |
| `HTTP 502` (일시적) | 롤아웃/등록 중 | 1~2분 후 재확인 |
| `HTTP 500` (특정 페이지만) | 앱은 떴는데 DB/Redis 연결 실패 | §6.8 |

```powershell
netstat -ano | findstr :8080      # LISTENING 유무로 REFUSED 확정
```

### 6.2 `terraform apply`가 kubernetes/helm만 실패

**TCP 타임아웃**이면 자격증명 문제가 아니라 **EKS 엔드포인트 허용목록** 문제입니다 (§0).
`Unauthorized`가 뜨면 그건 별개(토큰/권한).
`Error locating chart`는 EKS가 아니라 **차트 저장소**에 못 닿은 것이라 또 별개 → §6.3.

### 6.3 `helm_release`가 `Error locating chart`로 실패

```
Error: Error locating chart
  Unable to locate chart argo-cd: looks like "https://argoproj.github.io/argo-helm" is not a
  valid chart repository or cannot be reached: read tcp 192.168.31.51:55946->185.199.109.153:443:
  wsarecv: A connection attempt failed because the connected party did not properly respond ...
```

**일시적 네트워크 장애가 아닙니다.** 재시도하면 진도만 조금 나가고 다음 차트에서 같은 에러가 납니다 (2026-08-03: LB controller → argocd 순으로 2회 연속). 원인은 작업 PC의 **PMTUD 블랙홀**입니다.

- 회선의 실제 경로 MTU는 **1492**(PPPoE)인데 이더넷 어댑터는 **1500**
- 1500바이트 패킷이 드롭될 때 라우터가 ICMP `fragmentation needed`를 **안 돌려줍니다** → OS가 MTU를 낮춰야 한다는 걸 영영 모름
- TCP 연결과 TLS 핸드셰이크 초반은 작은 패킷이라 성공 → **`Test-NetConnection`은 멀쩡히 통과합니다**
- 서버가 큰 응답(helm `index.yaml`은 300KB~1.5MB)을 풀사이즈 세그먼트로 보내는 순간 그 패킷만 증발 → 읽기에서 타임아웃

진단 — 응답 자체가 없으면(`Packet needs to be fragmented` 메시지조차 없으면) 블랙홀 확정:

```powershell
ping -f -l 1472 185.199.109.153     # 1472+28=1500 -> 무응답이면 블랙홀
ping -f -l 1464 185.199.109.153     # 1464+28=1492 -> 정상이면 경로 MTU 1492 확정
netsh interface ipv4 show subinterfaces
```

조치 — **관리자 권한** PowerShell (재부팅 불필요, 되돌리려면 `mtu=1500`):

```powershell
netsh interface ipv4 set subinterface "이더넷" mtu=1492 store=persistent
```

> **브라우저와 `Test-NetConnection`은 정상인데 helm/대용량 다운로드만 실패**하면 이걸 의심하세요. GitHub Pages 고유 문제가 아니라 큰 응답을 주는 모든 호스트에 해당합니다.
> MTU를 못 바꾸는 환경이면 `terraform apply -parallelism=1`이 동시 연결 수를 줄여 확률만 낮춰줍니다 — 근본 해결이 아니고 apply가 훨씬 느려집니다.

### 6.4 갑자기 특정 서비스만 `AccessDenied`

사용자에게 직접 붙은 정책뿐 아니라 **소속 그룹의 정책**도 확인 (explicit deny는 `AdministratorAccess`를 이깁니다).

```powershell
aws sts get-caller-identity --profile admin
aws iam list-groups-for-user --user-name admin --profile admin
```

### 6.5 SSM으로 원격 명령 (따옴표 많은 명령)

PowerShell 이스케이프 지옥을 피하려고 **반드시 JSON 파일로** 넘깁니다.

```powershell
Set-Content -Path cmd.json -Encoding ascii -Value @'
{ "commands": ["echo hello"] }
'@
$cmdId = aws ssm send-command --instance-ids <bastion-id> --document-name "AWS-RunShellScript" `
  --parameters file://cmd.json --region ap-northeast-2 --profile admin --query "Command.CommandId" --output text
aws ssm get-command-invocation --command-id $cmdId --instance-id <bastion-id> --region ap-northeast-2 --profile admin
```
> `Out-File -Encoding utf8`은 BOM을 붙여서 AWS CLI가 파일을 못 읽습니다 → `Set-Content -Encoding ascii`

### 6.6 배스천이 없는데 클러스터를 봐야 할 때

작업 PC가 EKS 허용 IP면 `kubectl` 없이도 REST API를 직접 호출할 수 있습니다.

```bash
EP=$(aws eks describe-cluster --name gochuchamchi-eks --query cluster.endpoint --output text)
TOK=$(aws eks get-token --cluster-name gochuchamchi-eks --query status.token --output text)
curl --ssl-no-revoke -H "Authorization: Bearer $TOK" "$EP/api/v1/nodes"
```
> Windows Git Bash의 curl은 schannel을 써서 폐기목록 확인에 실패하므로 `--ssl-no-revoke` 필요

### 6.7 503 `Backend service does not exist`

**ALB 문제가 아닙니다.** AWS LB Controller가 Ingress 백엔드 Service를 못 찾으면 그 룰의
액션을 이 문구의 fixed-response 503으로 채웁니다. 즉 **Service가 클러스터에 없다**는 뜻입니다.

```powershell
# 1) 정말 fixed-response인지 확인 (grafana 등 다른 룰이 정상이면 ALB·DNS·ACM은 무죄)
$lb = aws elbv2 describe-load-balancers --region ap-northeast-2 --profile admin --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-gochuchamchiweb')].LoadBalancerArn" --output text
$ls = aws elbv2 describe-listeners --load-balancer-arn $lb --region ap-northeast-2 --profile admin --query "Listeners[?Port==``443``].ListenerArn" --output text
aws elbv2 describe-rules --listener-arn $ls --region ap-northeast-2 --profile admin

# 2) Service가 없으면 위로 거슬러 올라감
kubectl -n gochuchamchi get svc,deploy,pods         # 비어 있으면 GitOps 미배포
kubectl -n argocd get app gochuchamchi -o wide      # Sync=Unknown이면 저장소 접근 실패
kubectl -n argocd get app gochuchamchi -o jsonpath="{.status.conditions}"
kubectl get externalsecret -n argocd                # SecretSyncedError면 PAT 미주입 (§5)
```

`authentication required: Repository not found` → PAT 문제입니다. §5 체크리스트의 PAT
주입 항목으로 가세요. 2026-08-04 §4.3이 이 경로였습니다.

### 6.8 앱은 떴는데 특정 페이지만 500

로그의 **예외 종류로 계층이 갈립니다.**

```powershell
kubectl -n gochuchamchi logs deploy/gochuchamchi-web --tail=200 | Select-String "ERROR|Caused by"
```

| 예외 | 원인 | 조치 |
|---|---|---|
| `UnknownHostException` | **DNS 차단** — NetworkPolicy가 서비스 CIDR을 안 열었을 때 | 아래 DNS 확인 |
| `NOAUTH` (Redis) | AUTH 비밀번호 미주입 | `envFrom`에 `gochuchamchi-redis-secret` 있는지 |
| `BadSqlGrammarException: Table ... doesn't exist` | 스키마 미적용 | §5.1 |
| `Access denied for user` | DB 비밀번호 불일치 | §1.4, `gochuchamchi-db-app` Secret 확인 |

**DNS부터 확인하세요** — 막혀 있으면 DB·Redis 규칙이 아무리 정확해도 전부 실패합니다.

```powershell
kubectl -n gochuchamchi exec deploy/gochuchamchi-web -- getent hosts <RDS 엔드포인트>
kubectl -n gochuchamchi exec deploy/gochuchamchi-web -- env | Select-String "REDIS|DB_"
kubectl -n gochuchamchi get netpol web-allow -o jsonpath="{.spec.egress[0].to}"
# -> 10.100.0.0/16(서비스 CIDR)이 없으면 DNS가 막힌 상태 (2026-08-04 §4.4)
```

즉효 롤백은 `kubectl -n gochuchamchi delete netpol --all` (terraform이 다음 apply에서 복원).
단 **GitOps 관리 리소스를 `kubectl patch`로 고친 건 selfHeal이 몇 분 뒤 원복**하므로
진단용으로만 쓰고 해결은 gitops 저장소 커밋으로 하세요.

---

## 7. 고정 값 참조

재구축(destroy/apply)해도 **바뀌지 않는** 값들입니다.

| 항목 | 값 |
|---|---|
| 클러스터 | `gochuchamchi-eks` |
| 리전 / 프로필 | `ap-northeast-2` / `admin` |
| 계정 ID | `307223751140` |
| RDS | 인스턴스 ID `gochuchamchi-db` / DB `gochuchamchi` / user `admin` / port `3306` |
| ECR | `307223751140.dkr.ecr.ap-northeast-2.amazonaws.com/gochuchamchi` |
| 이미지 S3 | `gochuchamchi-images-307223751140` |
| 매니페스트 S3 | `gochuchamchi-k8s-manifests-307223751140` |
| tfstate S3 | `gochuchamchi-tfstate-307223751140` |
| Route 53 존 | `Z09871632JXCAV3R6Z65M` (`gochuchamchi.shop`) |
| 앱 저장소 | `landoll9999/gochuchamchi-spring` |
| GitOps 저장소 | `landoll9999/gochuchamchi-gitops` |
| 네임스페이스 | `gochuchamchi`, `argocd`, `external-dns`, `kube-system` |

### 재구축마다 바뀌는 값 — 하드코딩 금지

아래는 문서에 적어두면 반드시 낡습니다. 필요할 때 조회해서 쓰세요.

| 항목 | 조회 방법 |
|---|---|
| RDS 엔드포인트 | `kubectl -n gochuchamchi get cm gochuchamchi-config -o jsonpath='{.data.DB_HOST}'` |
| RDS 앱 계정 비밀번호 | `kubectl -n gochuchamchi get secret gochuchamchi-db-app -o jsonpath='{.data.DB_PASS}' \| base64 -d` |
| RDS 마스터 비밀번호 | K8s에 없음 — Secrets Manager 경유 (§1.4 ④, ARN은 `terraform output -raw rds_secret_arn`) |
| Redis 엔드포인트 | `kubectl -n gochuchamchi get cm gochuchamchi-config -o jsonpath='{.data.SPRING_DATA_REDIS_HOST}'` |
| Redis AUTH 토큰 | `kubectl -n gochuchamchi get secret gochuchamchi-redis-secret -o jsonpath='{.data.SPRING_DATA_REDIS_PASSWORD}' \| base64 -d` |
| RDS 시크릿 ARN | `terraform output -raw rds_secret_arn` (로컬) |
| 배스천 IP / ID | `terraform output bastion_ip` / `terraform output bastion_id` (로컬) |
| ALB 주소 | `kubectl -n gochuchamchi get ingress` |
| Grafana 비밀번호 | `terraform output -raw grafana_admin_password` (로컬) |

EKS 엔드포인트도 클러스터를 재생성하면 바뀝니다. 로컬 kubectl이 `no such host`를 뱉으면 kubeconfig가 낡은 것이니 `aws eks update-kubeconfig --name gochuchamchi-eks --region ap-northeast-2 --profile admin`으로 갱신하세요.

전체 목록은 `terraform output`으로 확인하세요.

---

## 8. 관측 · 감사 스택

**2026-08-03 기준 아래는 전부 apply 완료 상태입니다.** (2026-07-30까지는 "코드만 있고 state에 없음"이었습니다.)

확인: `terraform state list | Select-String -Pattern "athena|cloudtrail|firehose|grafana|observability"`

### 8.1 Grafana

```powershell
terraform output -raw grafana_admin_password    # 계정: admin
```

브라우저 **`https://grafana.gochuchamchi.shop`** — ArgoCD와 달리 **internet-facing**이라 터널 없이 바로 열립니다.

- 앱 ALB와 **같은 ALB를 공유**합니다 (ingress group `gochuchamchi-web`, `group.order=30`). `kubectl -n monitoring get ingress grafana`의 ADDRESS가 앱과 동일하게 나오는 게 정상입니다
- CloudWatch 데이터소스는 Pod Identity로 붙습니다 — 역할 ARN은 `terraform output grafana_iam_role_arn`

### 8.2 Athena (CloudTrail 조회)

| 항목 | 값 |
|---|---|
| Glue DB | `gochuchamchi_security_logs` |
| 테이블 | `cloudtrail_logs` |
| Workgroup | `gochuchamchi-security-logs` |

저장된 쿼리 3개(`recent_management_events`, `write_events`, `failed_api_calls`):

```powershell
aws athena list-named-queries --work-group gochuchamchi-security-logs --region ap-northeast-2 --profile admin
```

### 8.3 Container Insights / 로그 장기보관

```powershell
kubectl -n amazon-cloudwatch get pods                       # cloudwatch-agent, fluent-bit
aws eks describe-addon --cluster-name gochuchamchi-eks --addon-name amazon-cloudwatch-observability `
  --region ap-northeast-2 --profile admin --query "addon.status"
```

CloudWatch → Firehose → S3 장기보관 스트림은 `application` / `control-plane` 2개입니다.
