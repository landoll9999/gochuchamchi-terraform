# WAF Workload 계정 Apply 가이드

## 담당 계정

| 구분 | 값 |
|---|---|
| AWS 계정 | Workload `828885965304` |
| AWS CLI 프로파일 | `workload-admin` |
| 적용 폴더 | `go/terraform` |
| 적용 담당 | Workload 계정 담당자 |

Log 계정 `564186750363`의 WAF 로그 수신부, Firehose, 중앙 S3 및 Athena
`waf_logs` 테이블은 이미 적용돼 있다. Workload에서는 WAF 로그 송신부, 공격 알람,
CloudFront Origin 검증과 ALB 우회 차단만 적용한다.

## 이번 변경 내용

- WAF 로그 그룹에서 Log 계정 Destination으로 보내는 구독 필터
- WAF 전체 차단 알람
- WAF Rate Limit 차단 알람
- WAF SQL Injection 차단 알람
- WAF Known Bad Inputs 차단 알람
- `us-east-1` WAF 알람을 서울 리전 알림 허브로 전달하는 EventBridge 배선
- CloudFront가 ALB로 보낼 때 추가하는 Origin 검증 헤더
- Origin 검증 헤더가 있는 요청만 앱 Target Group으로 전달하는 ALB 조건

기존 WAF 규칙 4개는 그대로 유지한다.

1. `rate-limit-per-ip`
2. `AWSManagedRulesCommonRuleSet`
3. `AWSManagedRulesKnownBadInputsRuleSet`
4. `AWSManagedRulesSQLiRuleSet`

## 1. Git 반영 확인

먼저 다음 PR이 팀 검토 후 `main`에 병합돼 있어야 한다.

```text
feat/waf-completion
```

병합 후 실행한다.

```powershell
cd <gochuchamchi-terraform 저장소 경로>

git switch main
git pull origin main
git status
```

`git status`가 다음과 비슷해야 한다.

```text
On branch main
Your branch is up to date with 'origin/main'.
nothing to commit, working tree clean
```

로컬 수정이 남아 있으면 임의로 삭제하거나 덮어쓰지 말고 팀에 먼저 공유한다.

## 2. AWS SSO 로그인 및 계정 확인

```powershell
aws sso login --profile workload-admin

aws sts get-caller-identity `
  --profile workload-admin
```

반드시 다음 값인지 확인한다.

```text
Account: 828885965304
```

다른 계정이 나오거나 프로파일이 없으면 Apply를 중단한다. Management 또는 Log 계정
프로파일로 대신 실행하면 안 된다.

## 3. Terraform 초기화와 정적 검증

```powershell
cd .\go\terraform

terraform init -reconfigure
terraform fmt -check
terraform validate
```

`terraform validate` 결과가 다음이어야 한다.

```text
Success! The configuration is valid.
```

## 4. Plan 생성

```powershell
terraform plan `
  -out waf-workload.plan
```

Plan에서 다음 변경이 보여야 한다.

### 새로 생성되는 주요 리소스

```text
aws_cloudwatch_log_subscription_filter.waf_log_archive
aws_cloudwatch_metric_alarm.waf_total_blocked
aws_cloudwatch_metric_alarm.waf_rate_blocked
aws_cloudwatch_metric_alarm.waf_sqli_blocked
aws_cloudwatch_metric_alarm.waf_known_bad_blocked
aws_cloudwatch_event_rule.waf_alarm_state_change
aws_cloudwatch_event_target.waf_alarm_seoul_event_bus
aws_iam_role.waf_alarm_region_forwarder
aws_iam_role_policy.waf_alarm_region_forwarder
random_password.cloudfront_origin_verify
```

### 제자리 갱신되는 주요 리소스

```text
aws_cloudfront_distribution.edge
kubernetes_ingress_v1.gochuchamchi_web
```

CloudFront에는 Origin Custom Header가 추가되고, Ingress에는 동일 헤더를 검사하는
ALB listener 조건이 추가된다.

## 5. 반드시 중단해야 하는 Plan

다음 항목이 하나라도 보이면 Apply하지 말고 plan 전체를 팀에 공유한다.

- `destroy`가 1개 이상 있음
- CloudFront Distribution 교체
- ALB 또는 EKS 클러스터 교체
- RDS, EFS, S3, Redis 삭제 또는 교체
- WAF Web ACL 삭제 또는 교체
- 예상하지 않은 대량 변경
- `AccessDenied`, `Forbidden`, 계정 ID 불일치

Plan을 사람이 확인하기 좋게 출력하려면:

```powershell
terraform show -no-color waf-workload.plan |
  Out-File .\waf-workload-plan.txt -Encoding utf8
```

`waf-workload-plan.txt`를 팀 채널에 공유하고 승인받는다. 이 파일에는 비밀값이 표시될
수 있으므로 공개 저장소나 외부 채널에는 올리지 않는다.

## 6. Apply

Plan 확인이 끝난 뒤 저장된 plan만 적용한다.

```powershell
terraform apply waf-workload.plan
```

Apply 도중 오류가 발생하면 즉흥적으로 AWS 콘솔에서 리소스를 수정하지 말고 오류
전문을 저장해 공유한다.

적용 완료 후:

```powershell
terraform plan
```

최종 결과가 다음이어야 한다.

```text
No changes. Your infrastructure matches the configuration.
```

## 7. 정상 접속 확인

```powershell
curl.exe -I https://gochuchamchi.shop
curl.exe -I https://www.gochuchamchi.shop
```

정상적인 HTTP 응답이 와야 한다. CloudFront 변경 전파 중에는 잠시 기다린 뒤 다시
확인한다.

## 8. ALB 직접 우회 차단 확인

일반 인터넷에서는 ALB 보안 그룹에서 먼저 차단된다. 관리자 허용 IP에서 테스트할
경우에도 Origin 검증 헤더가 없으므로 애플리케이션으로 전달되면 안 된다.

ALB DNS 확인:

```powershell
aws elbv2 describe-load-balancers `
  --region ap-northeast-2 `
  --profile workload-admin `
  --query "LoadBalancers[?Type=='application'].[LoadBalancerName,DNSName]" `
  --output table
```

직접 요청:

```powershell
curl.exe -k -I `
  -H "Host: gochuchamchi.shop" `
  https://<ALB-DNS-NAME>
```

기대 결과:

- 외부 IP: 연결 차단 또는 타임아웃
- 관리자 허용 IP: listener 기본 응답 또는 `403`
- 애플리케이션의 정상 `200` 응답이 나오면 안 됨

## 9. WAF 차단 시험

본인들이 관리하는 `gochuchamchi.shop`에 SQLi 형태의 쿼리스트링을 1회만 보내
AWS Managed SQLi 규칙이 차단하는지 확인한다.

```powershell
curl.exe -I "https://gochuchamchi.shop/?q=%27%20OR%201%3D1--"
```

예상 결과는 `403`이다. 부하 테스트가 아니므로 반복 호출하지 않는다.

## 10. Workload CloudWatch에서 실시간 로그 확인

AWS 콘솔에서 다음 위치로 이동한다.

```text
계정: 828885965304
리전: us-east-1 (버지니아 북부)
CloudWatch Logs Insights
로그 그룹: aws-waf-logs-gochuchamchi-edge
```

쿼리:

```sql
fields
    @timestamp,
    action,
    terminatingRuleId,
    httpRequest.clientIp,
    httpRequest.country,
    httpRequest.httpMethod,
    httpRequest.uri,
    httpRequest.args
| filter action = "BLOCK"
| sort @timestamp desc
| limit 100
```

시험 요청의 IP, URI, `BLOCK` Action과 SQLi 관련 terminating rule이 보여야 한다.

## 11. Log 담당자에게 확인 요청

Workload Apply와 차단 시험이 끝나면 Log 담당자에게 다음 내용을 전달한다.

```text
Workload WAF Apply 완료
적용 계정: 828885965304
적용 시간: <KST 시간>
SQLi 차단 시험 시간: <KST 시간>
CloudWatch WAF 로그 확인: 성공/실패
Log 계정 S3 및 Athena 유입 확인 요청
```

Log 담당자는 약 5분 후 다음을 확인한다.

```text
S3: s3://gochuchamchi-log-archive-564186750363/cloudwatch/waf/
Athena DB: gochuchamchi_security_logs
Athena Table: waf_logs
저장 쿼리: 07-waf-blocked-request-details
```

## 완료 기준

- Workload 최종 plan이 `No changes`
- CloudFront 정상 URL 접속 성공
- ALB 직접 우회 실패
- SQLi 시험 요청 WAF `403`
- Workload CloudWatch WAF 로그 확인
- Log 계정 중앙 S3 객체 생성
- Athena `waf_logs`에서 동일 차단 요청 확인
- WAF 알람이 기존 알림 채널에 전달됨

