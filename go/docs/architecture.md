# 초기 구축 기록 — 아키텍처 / 파이프라인 / 상시 참고

> 날짜가 특정되지 않은 초기 구축 단계 기록입니다. 날짜별 작업 기록은 `README.md`의 목록을 참고하세요.

---

## 1. 목표
- `gochuchamchi-eks` Terraform 프로젝트로 EKS 클러스터 구축
- 로컬 PC의 k8s yaml 매니페스트를 배스천에 자동 전달 (scp 대체)
- kubectl apply → RDS/Redis 연동 → 도메인(`gochuchamchi.shop`) HTTPS 서비스까지 완료

---

## 2. 최종적으로 성공한 아키텍처

```
로컬 PC (k8s/gochuchamchi/*.yml)
   │ terraform apply
   ▼
S3 버킷 (gochuchamchi-k8s-manifests-<account_id>)
   │ null_resource + SSM send-command (aws s3 sync)
   ▼
배스천 EC2 (/home/ec2-user/k8s/)
   │ kubectl apply -f
   ▼
EKS 클러스터 (gochuchamchi-eks)
   ├─ Deployment (gochuchamchi-web) → RDS(MariaDB) 연결 (HikariCP)
   ├─ Service → ALB Controller가 Ingress 보고 ALB 자동 생성
   ├─ ExternalDNS → Route 53에 A 레코드 자동 등록
   └─ ACM 인증서로 HTTPS 종료
```

---

## 3. 핵심 성공 단계 (순서대로)

### 3.1 로컬 k8s 매니페스트 자동 배포 파이프라인 구축
`terraform/k8s-deploy.tf` 신규 생성:
- `aws_s3_bucket.k8s_manifests` : yaml 담을 S3 버킷
- `aws_s3_object.k8s_manifests` (`for_each = fileset(...)`) : 로컬 yaml → S3 업로드
  - **실제 경로**: `${path.module}/../k8s/gochuchamchi` (terraform 폴더 바깥), 확장자 `.yml`
- `aws_iam_role_policy.bastion_s3_manifests` : 배스천이 S3 읽을 권한
- `null_resource.sync_k8s_to_bastion` : yaml 해시(`filemd5`)가 바뀔 때마다 로컬에서 PowerShell `local-exec`로
  1. SSM `describe-instance-information`으로 배스천 `PingStatus: Online` 폴링 대기
  2. `aws ssm send-command`로 배스천에 `aws s3 sync s3://.../k8s /home/ec2-user/k8s --delete` 실행

### 3.2 배스천 EC2 이슈 해결
- **문제**: `al2023-ami-minimal` AMI라 SSM Agent 기본 미포함 → SSM 명령 전부 실패
  - **해결**: `userdata.sh.tpl` 맨 위에 SSM Agent 수동 설치 추가
    ```bash
    sudo dnf install -y amazon-ssm-agent
    sudo systemctl enable amazon-ssm-agent
    sudo systemctl start amazon-ssm-agent
    ```
  - `user_data_replace_on_change = true` 추가해 userdata 변경 시 인스턴스 강제 재생성
- **문제**: 루트 볼륨 2GB → SSM Agent+kubectl 설치 후 디스크 꽉 참 → 모든 SSM 명령 즉시 실패(`ResponseCode 1`, 실행시간 0.001초)
  - **해결**: `root_block_device = { size = 20, type = "gp3" }` (이 모듈 버전은 `size`/`type` 필드명 사용, `volume_size`/`volume_type` 아님)
- **문제**: SSH 키페어(`gochuchamchi-key.pem`)가 실제 AWS 키페어와 다른 파일이었음 (`Permission denied (publickey)`)
  - **해결**: 새 키페어 생성(`gochuchamchi-key-v2`) 후 `key_name` 변경 → 재생성

### 3.3 VS Code Remote-SSH (SSM 경유) 접속 구성
`~/.ssh/config`:
```
Host gochuchamchi-bastion
    HostName <배스천 인스턴스 ID>
    User ec2-user
    IdentityFile C:\Users\<user>\.ssh\gochuchamchi-key-v2.pem
    ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters "portNumber=%p" --profile admin --region ap-northeast-2
```
- 로컬에 **Session Manager Plugin** 별도 설치 필요 (`SessionManagerPluginSetup.exe`)
- 인스턴스가 재생성될 때마다 `HostName`을 새 인스턴스 ID로 갱신 필요

### 3.4 K8s 리소스 배포 + RDS 연동
1. `kubectl apply -f /home/ec2-user/k8s/` → namespace/serviceaccount/configmap/deployment/service/ingress/hpa 7개 리소스 생성
2. **`CreateContainerConfigError`**: Deployment가 참조하는 `gochuchamchi-db-secret`이 클러스터에 없음
   - Secrets Manager(`rds!db-...`)에서 비밀번호 조회 후 K8s Secret 생성:
     ```bash
     SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id '<ARN>' --region ap-northeast-2 --query SecretString --output text)
     DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")
     kubectl -n gochuchamchi create secret generic gochuchamchi-db-secret --from-literal=DB_PASS="$DB_PASS"
     ```
3. `02-configmap-app.yml`의 `DB_HOST`/`SPRING_DATA_REDIS_HOST` 플레이스홀더를 실제 엔드포인트로 교체 후 재적용 + `kubectl rollout restart`
4. 로그에서 `HikariPool-1 - Start completed` 확인 → RDS 연결 성공

### 3.5 ALB / HTTPS / 도메인 연결
- **문제**: Ingress `ADDRESS`가 계속 비어있음
  - **원인**: `05-ingress-web.yml`의 `certificate-arn`이 플레이스홀더(`REPLACE_WITH_NEW_ACM_CERT_ARN`)로 남아있어 ALB Controller가 리스너 생성 실패 (`CertificateNotFound`)
  - **해결**: 실제 ACM ARN으로 교체 후 재적용 → ALB 정상 생성
- ExternalDNS 로그에서 `6 record(s) were successfully updated` 확인 → Route 53 A 레코드 자동 등록
- 브라우저에서 `https://gochuchamchi.shop` 접속 성공

### 3.6 DB 스키마 적용
- 배스천에 `mariadb105` 클라이언트 설치 (`sudo dnf install -y mariadb105`)
- `schema.sql` (users, notices, products, product_sizes)을 RDS `gochuchamchi` DB에 적용
  ```bash
  mysql -h <rds_endpoint> -u admin -p"$DB_PASS" gochuchamchi < schema.sql
  ```
- (확인 결과 테이블은 이미 존재했으나, `IF NOT EXISTS`라 안전하게 스킵됨 — 500 에러의 원인은 스키마 부재가 아니었음)

---

## 4. 두 번째 세션 트러블슈팅 (Route53 data 전환 이후)

### 4.1 Route 53 존 재생성 문제 → data 소스 전환
- **문제**: `resource "aws_route53_zone"`로 되어 있어 `destroy`/`apply`마다 존이 재생성 → 네임서버가 매번 바뀌어 가비아 재설정 + NS 전파(수십 분~1시간) + ACM 재검증을 반복
- **해결**: `dns.tf`에서 `resource "aws_route53_zone" "this"` → `data "aws_route53_zone" "this"`로 전환, 이후 모든 `aws_route53_zone.this.*` 참조를 `data.aws_route53_zone.this.*`로 교체
- **효과**: destroy/apply를 반복해도 존과 네임서버가 그대로 유지되어, 이후 재구축 시 ACM 검증이 몇 분 내로 끝남

### 4.2 IAM 그룹의 explicit deny로 다수 리소스 AccessDenied
- **증상**: `s3:GetBucketPublicAccessBlock`, `rds:DescribeDBSubnetGroups` 등 다수 액션이 `AccessDenied ... explicit deny in an identity-based policy: DenySensitiveServices`로 실패
- **원인**: 사용하던 IAM 사용자가 `3pro`라는 그룹(그날 새로 생성됨) 소속이었고, 그 그룹에 `DenySensitiveServices` 정책이 붙어 있었음. Explicit deny는 `AdministratorAccess`보다 우선 적용됨
- **해결**: 콘솔에서 해당 사용자를 `3pro` 그룹에서 제거 → 즉시 `terraform plan`이 정상화됨
- **교훈**: 갑자기 특정 서비스만 AccessDenied가 나면 사용자에게 직접 붙은 정책뿐 아니라 **소속 그룹의 정책**도 반드시 확인 (`aws iam list-groups-for-user`, `aws iam list-attached-group-policies`)

### 4.3 RDS `Too many connections`
- **증상**: 파드 재시작/롤링 중 `Error: 1040-08004: Too many connections`가 반복 발생, 새 커넥션조차 거부되어 모니터링 쿼리도 실패
- **원인**: `db.t3.micro`의 `max_connections`가 30으로 낮은데, Spring Boot(HikariCP) 기본 풀 사이즈가 파드당 10개 → 파드 2개만으로 20개, 배스천 클라이언트까지 더하면 순식간에 한도 초과
- **응급 조치**: `aws rds reboot-db-instance`로 모든 유휴/좀비 연결 강제 종료
- **근본 조치**: ConfigMap에 HikariCP 풀 크기 제한 추가
  ```yaml
  SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE: "5"
  SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE: "2"
  ```

### 4.4 회원가입 `Unknown column 'name' in 'INSERT INTO'`
- **원인**: 최초 작성한 `schema.sql`의 `users` 테이블에 애플리케이션이 실제로 쓰는 컬럼(`name`, `phone`, `birthdate`, `gender`, `nationality`, `address`)이 빠져 있었음
- **해결**: `ALTER TABLE users ADD COLUMN ...`으로 누락 컬럼 추가 (→ §5 최종 자동화 구조에서 `schema.sql` 자체를 최종본으로 교정)

### 4.5 회원가입 `Incorrect string value` (한글 깨짐)
- **원인**: 4.4에서 추가한 컬럼들이 문자셋을 지정하지 않아 테이블 기본 문자셋(`latin1` 등)을 물려받음 → 한글(멀티바이트) INSERT 시 예외
- **해결**: `ALTER TABLE ... CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci`로 전체 테이블 변환 (→ §5 최종 자동화 구조에서 `schema.sql`에 `utf8mb4` 기본 지정으로 반영)

### 4.6 로그인은 되는데 세션이 자꾸 풀림 (파드마다 로그인 상태가 다름)
- **증상**: 로그인 응답(302)과 `Set-Cookie: JSESSIONID=...`는 정상인데, ALB가 요청을 다른 파드로 분산시키면 그 파드는 세션을 몰라 다시 로그인 화면으로 튕김
- **원인 확정**: 애플리케이션 jar 안에 `spring-session-data-redis`, `spring-boot-starter-data-redis`, `lettuce-core` 관련 클래스가 전혀 없었음(`unzip -l app.jar | grep redis` 결과 없음) → `SPRING_SESSION_STORE_TYPE=redis` 환경변수를 줘도 관련 auto-configuration이 클래스패스에 없어 조용히 무시되고 파드별 인메모리 세션으로 동작
- **근본 해결**: `gochuchamchi-spring` 저장소의 `pom.xml`에 의존성 추가 + `application.yml`에 `spring.data.redis`/`spring.session` 설정 추가 → GitHub Actions로 재빌드/재푸시 → 새 이미지 태그로 K8s 배포
  ```xml
  <dependency>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-data-redis</artifactId>
  </dependency>
  <dependency>
    <groupId>org.springframework.session</groupId>
    <artifactId>spring-session-data-redis</artifactId>
  </dependency>
  ```
  ```yaml
  spring:
    data:
      redis:
        host: ${SPRING_DATA_REDIS_HOST:localhost}
        port: ${SPRING_DATA_REDIS_PORT:6379}
    session:
      store-type: redis
      redis:
        namespace: gochuchamchi:session
      timeout: 3600
  ```
- **검증**: 재배포 후 로그에 `Bootstrapping Spring Data Redis repositories` 확인 → 파드 2개를 오가도 로그인 상태 유지 확인 완료

### 4.7 배포 후 yaml이 실제로 반영 안 되는 문제 (S3 sync 무반응)
- **증상**: 로컬 yaml 수정 → `terraform apply` → `kubectl apply` 했는데 `deployment.apps/gochuchamchi-web unchanged`로 나오고 실제 파일도 예전 내용 그대로
- **원인**: `aws s3 sync`가 파일 mtime 비교 로직 때문에 실제로 내용이 바뀌었는데도 "이미 최신"이라 판단해 스킵
- **해결**: 배스천에서 `aws s3 sync ... --exact-timestamps` 옵션으로 강제 동기화. Terraform 쪽에서도 `null_resource`가 재실행되도록 `terraform taint null_resource.sync_k8s_to_bastion` 후 재적용 필요할 때가 있었음

---

## 5. 최종 자동화 구조

이번 세션 이후로는 **`terraform apply` 한 번으로 웹 접속 + 회원가입/로그인/게시글 작성까지 바로 동작**하도록 아래를 자동화함:
- S3 버킷을 먼저 생성한 뒤 나머지 인프라를 이어서 생성 (`deploy.ps1` 스크립트로 2단계 apply)
- ConfigMap/Ingress의 `DB_HOST`, `REDIS_HOST`, `certificate-arn`을 Terraform이 실제 값으로 자동 렌더링 (더 이상 수동으로 ARN/엔드포인트를 옮겨 적을 필요 없음)
- RDS 생성 후 `schema.sql`을 자동으로 적용 (utf8mb4, 전체 컬럼 포함한 최종본)
- `gochuchamchi-db-secret`(K8s Secret)도 Terraform이 배스천을 통해 자동 생성

자세한 코드는 프로젝트의 `k8s-deploy.tf`, `rds-schema-init.tf`, `deploy.ps1`, `k8s/gochuchamchi/schema.sql` 참고.

## 6. 자주 쓴 디버깅 명령 모음 (배스천, PATH 설정 후)

```bash
export PATH=$PATH:/home/ec2-user/bin
export KUBECONFIG=/home/ec2-user/.kube/config

# 리소스 상태
kubectl -n gochuchamchi get all

# 파드 상세/이벤트
kubectl -n gochuchamchi describe pod -l app=gochuchamchi-web | tail -30

# 로그
kubectl -n gochuchamchi logs -l app=gochuchamchi-web --tail=100

# ALB Controller / ExternalDNS 로그
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=30
kubectl -n external-dns logs deployment/external-dns --tail=30

# 재배포
kubectl apply -f /home/ec2-user/k8s/
kubectl -n gochuchamchi rollout restart deployment/gochuchamchi-web
kubectl -n gochuchamchi rollout status deployment/gochuchamchi-web --timeout=90s
```

로컬 PC(PowerShell)에서 자주 쓴 패턴:
```powershell
# yaml 수정 후 배스천 자동 동기화
terraform apply

# SSM 명령 (따옴표/특수문자 있는 명령은 반드시 JSON 파일로)
Set-Content -Path cmd.json -Encoding ascii -Value @'
{ "commands": ["..."] }
'@
$cmdId = aws ssm send-command --instance-ids <id> --document-name "AWS-RunShellScript" --parameters file://cmd.json --region ap-northeast-2 --profile admin --query "Command.CommandId" --output text
aws ssm get-command-invocation --command-id $cmdId --instance-id <id> --region ap-northeast-2 --profile admin
```

### RDS(MariaDB) 접속 — 배스천 경유

RDS는 `publicly_accessible = false` + `database_subnets`이라 **배스천에서만** 접속된다.
`mysql -p"$PASS"`는 `ps` 목록과 SSM 로그에 비밀번호가 남으므로 `defaults-extra-file`을 쓴다
(`rds-schema-init.tf`가 쓰는 방식과 동일).

```bash
# 배스천 접속: aws ssm start-session --target <bastion-id> --region ap-northeast-2 --profile admin
sudo su - ec2-user
which mysql || sudo dnf install -y mariadb105

SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id '<rds!db-... ARN>'   --region ap-northeast-2 --query SecretString --output text)
DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)['password'])")

printf "[client]
user=admin
password=%s
host=<rds-endpoint>
" "$DB_PASS" > ~/.my.cnf
chmod 600 ~/.my.cnf

mysql --defaults-extra-file=~/.my.cnf gochuchamchi

rm -f ~/.my.cnf   # 작업 끝나면 반드시 삭제
```

- 시크릿 ARN에 `!`가 포함되므로 **작은따옴표 필수** (bash 히스토리 확장 방지)
- 접속 정보는 `terraform output` 및 `aws rds describe-db-instances`로 확인
- `db.t3.micro`의 `max_connections`는 30이고 HikariCP가 파드당 5개를 쓴다 —
  **mysql 세션도 커넥션을 차지하므로 확인 후 반드시 `exit`** (방치하면 `Too many connections`)

자주 쓰는 조회:
```sql
SHOW TABLES;
SELECT id, username, name, email, role, created_at FROM users ORDER BY id;
SHOW STATUS LIKE 'Threads_connected';
```

---

## 7. 다른 PC로 작업 환경 옮길 때 체크리스트

- [ ] **SSH 키 파일**: `gochuchamchi-key-v2.pem`을 새 PC의 `C:\Users\<user>\.ssh\`에 복사
- [ ] **Session Manager Plugin 설치**: 새 PC에서도 별도 설치 필요
  ```powershell
  Invoke-WebRequest -Uri "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/windows/SessionManagerPluginSetup.exe" -OutFile "$env:USERPROFILE\Downloads\SessionManagerPluginSetup.exe"
  Start-Process "$env:USERPROFILE\Downloads\SessionManagerPluginSetup.exe" -Wait
  ```
  설치 후 새 터미널에서 `session-manager-plugin` 실행해 정상 설치 확인
- [ ] **`~/.ssh/config` 재구성** (배스천 인스턴스가 재생성됐다면 `HostName`을 최신 인스턴스 ID로 갱신):
  ```
  Host gochuchamchi-bastion
      HostName <배스천 인스턴스 ID>
      User ec2-user
      IdentityFile C:\Users\<user>\.ssh\gochuchamchi-key-v2.pem
      ProxyCommand aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters "portNumber=%p" --profile admin --region ap-northeast-2
  ```
- [ ] **AWS CLI 프로필 설정**: `aws configure --profile admin` (Access Key/Secret Key/리전 `ap-northeast-2` 입력)
- [ ] **Terraform 프로젝트 폴더 전체 이전**: `C:\terraform\gochuchamchi-eks\` (하위 `terraform/`, `k8s/gochuchamchi/*.yml` 포함) — 아직 Git으로 관리하지 않는다면 이번 기회에 리포지토리화 추천
  ```powershell
  cd C:\terraform\gochuchamchi-eks
  git init
  git add .
  git commit -m "initial commit"
  # 원격 저장소(GitHub 등) 연결 후 push
  ```
  새 PC에서는 `git clone`으로 받은 뒤 `terraform init`부터 다시 실행
- [ ] **최신 인스턴스 ID / 엔드포인트 확인**: 새 PC에서 작업 재개 전 아래로 현재 상태 재확인
  ```powershell
  terraform output
  aws ec2 describe-instances --filters "Name=tag:Name,Values=gochuchamchi-bastion" "Name=instance-state-name,Values=running" --region ap-northeast-2 --profile admin --query "Reservations[*].Instances[*].[InstanceId,LaunchTime]" --output table
  ```

