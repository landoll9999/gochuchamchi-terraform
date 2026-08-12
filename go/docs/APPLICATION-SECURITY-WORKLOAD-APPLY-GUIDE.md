# Workload 계정 — 애플리케이션 탐지/ALB 로그 적용 가이드

대상 계정은 **Workload `828885965304`**, 프로파일은 `workload-admin`이다. Log 담당자가 먼저 전용 ALB 버킷을 적용한 후 진행한다.

## 사전 조건

- Log 계정에 `gochuchamchi-alb-access-logs-564186750363` 버킷이 생성되어 있음
- Spring `main`에 구조화 보안 로그 코드가 병합되어 있음
- Spring GitHub Actions가 새 이미지를 빌드하고 GitOps 저장소의 이미지 태그를 갱신할 수 있음

Terraform은 Spring 또는 GitOps 코드를 내려받거나 이미지를 빌드하지 않는다. Terraform은 EKS/CloudWatch/ALB 설정만 적용한다.

## 추가되는 항목

- 애플리케이션 로그 Metric Filter
  - HTTP 4xx
  - HTTP 5xx
  - 로그인 실패
  - 권한 거부/차단
  - HIGH/CRITICAL 보안 이벤트
- `gochuchamchi-app-*` CloudWatch Alarm
- ALB Target 4xx 급증 Alarm
- Ingress ALB 액세스 로그 전달 설정
  - 대상: Log 계정 전용 S3
  - prefix: `alb`

알람 이름이 `gochuchamchi-`로 시작하므로 기존 `cloudwatch-notifications` EventBridge 규칙이 Discord/SNS 알림 파이프라인으로 전달한다.

## 적용

```powershell
git switch main
git pull origin main

aws sso login --profile workload-admin
aws sts get-caller-identity --profile workload-admin
```

`Account`가 반드시 `828885965304`인지 확인한다.

```powershell
cd go\terraform
terraform init -reconfigure
terraform fmt -check
terraform validate
terraform plan -out=workload-application-security.tfplan
terraform show workload-application-security.tfplan
terraform apply workload-application-security.tfplan
```

`plan`에서 EKS, RDS, Redis, 기존 S3의 교체 또는 삭제가 보이면 적용하지 말고 중단한다.

## 적용 후 확인

```powershell
aws logs describe-metric-filters `
  --profile workload-admin `
  --region ap-northeast-2 `
  --log-group-name /aws/containerinsights/gochuchamchi-eks/application

aws cloudwatch describe-alarms `
  --profile workload-admin `
  --region ap-northeast-2 `
  --alarm-name-prefix gochuchamchi-app-
```

실제 클러스터 이름이 다르면 첫 명령의 로그 그룹 이름을 Terraform output 또는 콘솔에서 확인해 바꾼다.

ALB 속성에는 다음 세 값이 있어야 한다.

```text
access_logs.s3.enabled = true
access_logs.s3.bucket  = gochuchamchi-alb-access-logs-564186750363
access_logs.s3.prefix  = alb
```

## 애플리케이션 이미지 배포 확인

Terraform 적용만으로는 새 Spring 로그가 나오지 않는다. Spring CI와 Argo CD 동기화가 끝난 뒤 파드 이미지와 로그를 확인한다.

```powershell
kubectl get pods -n gochuchamchi -o wide
kubectl logs -n gochuchamchi -l app=gochuchamchi-web --tail=100
```

로그에서 한 줄 JSON의 `eventCategory`가 `HTTP_ACCESS` 또는 `SECURITY_EVENT`로 출력되는지 확인한다. 비밀번호, JWT, Cookie, Authorization 헤더, 요청 Body는 기록되면 안 된다.
