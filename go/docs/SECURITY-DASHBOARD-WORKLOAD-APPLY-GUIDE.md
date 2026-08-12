# Workload 계정 — 보안 대시보드 메트릭 연결 가이드

대상 계정은 **Workload `828885965304`**, 프로파일은 `workload-admin`이다. Log 담당자가 OAM Sink 두 개를 적용하고 ARN을 전달한 뒤 진행한다.

## 생성 항목

- 서울 OAM Link 1개
  - `AWS/ApplicationELB`
  - `Gochuchamchi/ApplicationSecurity`
- 버지니아 OAM Link 1개
  - `AWS/WAFV2`

원시 로그, Spring 로그 본문, 개인정보를 Log 계정 CloudWatch로 복제하지 않는다. 숫자형 메트릭만 공유한다.

## ARN을 현재 PowerShell 세션에 설정

Log 담당자가 전달한 실제 ARN으로 `<...>` 부분을 교체한다.

```powershell
$env:TF_VAR_log_archive_oam_sink_arn_seoul = "<ap-northeast-2 Sink ARN>"
$env:TF_VAR_log_archive_oam_sink_arn_us_east_1 = "<us-east-1 Sink ARN>"
```

ARN은 보안 비밀은 아니지만 계정별 적용값이므로 저장소의 공용 `tfvars`에는 하드코딩하지 않는다.

## 적용

```powershell
git switch main
git pull origin main

aws sso login --profile workload-admin
aws sts get-caller-identity --profile workload-admin
```

`Account`가 반드시 `828885965304`인지 확인한다.

```powershell
cd go\account-baseline
terraform init -reconfigure
terraform fmt -check
terraform validate
terraform plan -out security-dashboard-workload.tfplan
terraform show security-dashboard-workload.tfplan
terraform apply security-dashboard-workload.tfplan
```

이번 변경의 핵심은 `aws_oam_link.security_monitoring_seoul`, `aws_oam_link.security_monitoring_us_east_1` **2개 추가**다. 전체 account-baseline root를 계획하므로 그 외 기존 리소스 변경도 반드시 검토하고, 예상 밖 삭제·교체가 보이면 중단한다.

이 Link는 매일 생성·삭제하는 `go\terraform`이 아니라 1회성 `go\account-baseline`에서 관리한다. 향후 account-baseline을 다시 plan/apply할 때도 두 환경변수가 반드시 있어야 하며, 없으면 Terraform이 삭제를 계획하는 대신 필수 변수 오류로 중단한다.

## 적용 후 확인

```powershell
aws oam list-links --profile workload-admin --region ap-northeast-2
aws oam list-links --profile workload-admin --region us-east-1
```

각 리전에 Link가 1개씩 보여야 한다. 이후 Log 담당자가 `gochuchamchi-security-overview`에서 WAF, ALB, 애플리케이션 보안 메트릭을 확인한다.

PowerShell을 닫기 전 환경변수를 지우려면 다음을 실행한다.

```powershell
Remove-Item Env:TF_VAR_log_archive_oam_sink_arn_seoul
Remove-Item Env:TF_VAR_log_archive_oam_sink_arn_us_east_1
```
