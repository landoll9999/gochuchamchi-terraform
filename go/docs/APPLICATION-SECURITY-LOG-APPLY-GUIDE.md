# Log 계정 — 애플리케이션/ALB 로그 적용 가이드

대상 계정은 **Log `564186750363`**, 프로파일은 `log-admin`이다. Workload보다 반드시 먼저 적용한다.

## 추가되는 항목

- Spring 애플리케이션 로그용 Athena `application_logs` 테이블
- HTTP 상태 코드, 4xx/5xx, 보안 실패, HIGH/CRITICAL, WAF ALLOW 상관분석 저장 쿼리
- Workload ALB 액세스 로그 전용 S3 버킷
  - `gochuchamchi-alb-access-logs-564186750363`
  - SSE-S3, 버전 관리, Object Lock COMPLIANCE
- ALB 액세스 로그용 Athena `alb_access_logs` 테이블과 저장 쿼리

ALB 로그 버킷을 별도로 만드는 이유는 ALB 액세스 로그가 SSE-S3만 지원해, 기존 KMS 암호화 중앙 로그 버킷에 직접 기록할 수 없기 때문이다.

## 적용

```powershell
git switch main
git pull origin main

aws sso login --profile log-admin
aws sts get-caller-identity --profile log-admin
```

`Account`가 반드시 `564186750363`인지 확인한다.

```powershell
cd go\log-archive
terraform init -reconfigure
terraform fmt -check
terraform validate
terraform plan -out=log-application-security.tfplan
terraform show log-application-security.tfplan
terraform apply log-application-security.tfplan
```

`plan`에서 기존 중앙 S3, CloudTrail, Firehose의 교체 또는 삭제가 보이면 적용하지 말고 중단한다.

## 적용 후 전달할 값

```powershell
terraform output -raw alb_access_log_bucket_name
terraform output -raw athena_application_table_name
terraform output -raw athena_alb_access_log_table_name
```

예상 ALB 버킷 이름은 `gochuchamchi-alb-access-logs-564186750363`이다. 이 버킷이 생성된 다음 Workload 담당자가 적용한다.

## Workload 적용 후 확인

```powershell
aws s3api list-objects-v2 `
  --profile log-admin `
  --bucket gochuchamchi-alb-access-logs-564186750363 `
  --prefix alb/AWSLogs/828885965304/ `
  --max-items 20
```

`ELBAccessLogTestFile` 또는 실제 `.log.gz` 객체가 보여야 한다. Athena 데이터베이스 `gochuchamchi_security_logs`에는 다음 테이블이 보여야 한다.

- `application_logs`
- `alb_access_logs`
- 기존 `cloudtrail_logs`, `vpc_flow_logs`, `waf_logs`

애플리케이션 로그는 새 Spring 이미지가 EKS에 배포된 뒤부터 구조화 이벤트가 쌓인다.
