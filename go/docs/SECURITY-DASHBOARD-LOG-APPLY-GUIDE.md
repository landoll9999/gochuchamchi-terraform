# Log 계정 — 보안 대시보드 적용 가이드

대상 계정은 **Log `564186750363`**, 프로파일은 `log-admin`이다. Workload 담당자보다 먼저 적용한다.

## 생성 항목

- 서울 OAM Sink: ALB·애플리케이션 보안 메트릭 수신
- 버지니아 OAM Sink: CloudFront WAF 메트릭 수신
- CloudWatch Dashboard `gochuchamchi-security-overview`
  - 총 8개 위젯
  - WAF 차단, 4xx/5xx, 인증·권한 이벤트, 가용성, Firehose 상태만 요약
  - IP·URI·사용자 상세 조사는 기존 Athena 저장 쿼리 `09`~`16` 사용

원시 로그를 계정 간 CloudWatch로 다시 공유하지 않는다. 원시 로그는 기존처럼 중앙 S3/Object Lock에 보관하고 Athena에서 조회하며, 대시보드에는 Workload 메트릭만 공유한다.

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
terraform plan -out security-dashboard-log.tfplan
terraform show security-dashboard-log.tfplan
terraform apply security-dashboard-log.tfplan
```

정상 plan은 대시보드 1개, OAM Sink 2개, Sink Policy 2개의 **5개 추가**가 핵심이다. 기존 리소스의 삭제나 교체가 보이면 중단한다.

## Workload 담당자에게 전달할 값

```powershell
terraform output -raw oam_sink_arn_seoul
terraform output -raw oam_sink_arn_us_east_1
```

두 ARN을 Workload 담당자에게 전달한다. 이 단계 직후 대시보드는 생성되지만 Workload OAM Link가 생기기 전까지 WAF·ALB·애플리케이션 그래프는 비어 있을 수 있다.

## 최종 확인

Workload 적용이 끝난 뒤 Log 계정에서 CloudWatch → 대시보드 → `gochuchamchi-security-overview`를 연다. Firehose 위젯은 Log 계정 자체 지표이므로 바로 표시되고, 나머지는 실제 트래픽/보안 이벤트가 발생한 뒤 표시된다.
