# 2026-08-11 WAF 완성 작업 및 적용 가이드

## 적용 구조

```text
Internet
  -> CloudFront
     -> AWS WAF (Rate / Common / KnownBad / SQLi)
        -> Origin 검증 헤더
           -> ALB Listener 조건
              -> EKS 애플리케이션

WAF request log (Workload, us-east-1)
  -> CloudWatch Logs
     -> cross-account Destination (Log, us-east-1)
        -> Firehose (Log, ap-northeast-2)
           -> Object Lock S3
              -> Athena waf_logs
```

## 계정별 상태

### Log 계정 `564186750363`

2026-08-11 적용 완료.

- `gochuchamchi-waf-log-archive` Firehose
- `gochuchamchi-waf-log-archive` cross-account Logs Destination (`us-east-1`)
- 중앙 S3 `cloudwatch/waf/` 경로
- Glue/Athena `waf_logs` 테이블
- Athena 저장 쿼리 `07-waf-blocked-request-details`
- Athena 저장 쿼리 `08-waf-top-attacking-ips`
- 적용 결과: `8 added, 3 changed, 0 destroyed`
- 재확인 결과: `No changes`

### Workload 계정 `828885965304`

Workload 담당자가 아래 절차로 적용한다. 계정 분리를 유지하기 위해 Log 담당자에게
Workload 관리자 권한을 추가로 부여하지 않는다.

```powershell
git switch main
git pull origin main

aws sso login --profile workload-admin
aws sts get-caller-identity --profile workload-admin
```

출력의 Account가 반드시 `828885965304`인지 확인한다.

```powershell
cd .\go\terraform
terraform init -reconfigure
terraform validate
terraform plan -out waf-workload.plan
```

Plan에서 다음 유형의 변경을 확인한다.

- WAF CloudWatch Alarm 4개 추가
- WAF 알람의 `us-east-1 -> ap-northeast-2` EventBridge 전달 추가
- WAF CloudWatch Log Group의 중앙 아카이브 구독 필터 추가
- CloudFront Origin Custom Header 추가
- 애플리케이션 ALB listener에 동일 헤더 조건 추가
- 기존 WAF 규칙 4개 유지
- 리소스 삭제 또는 ALB/CloudFront 교체가 없어야 함

확인 후 저장된 plan을 적용한다.

```powershell
terraform apply waf-workload.plan
terraform plan
```

마지막 `terraform plan`은 `No changes`여야 한다.

## 적용 후 확인

### 1. 정상 사용자 경로

```powershell
curl.exe -I https://kycj.click
```

정상 응답이 와야 한다.

### 2. ALB 직접 우회

일반 인터넷에서는 ALB 보안 그룹 단계에서 막혀야 한다. 관리자 허용 IP에서 시험하면
CloudFront Origin 검증 헤더가 없으므로 앱 Target Group으로 전달되지 않아야 한다.

```powershell
curl.exe -k -I -H "Host: kycj.click" https://<ALB-DNS-NAME>
```

`403` 또는 listener 기본 응답이 나오고 애플리케이션 `200`이 나오지 않아야 한다.

### 3. WAF 안전 시험

우리 도메인에 SQLi 형태의 쿼리스트링을 1회만 보내 차단 여부를 확인한다.

```powershell
curl.exe -I "https://kycj.click/?q=%27%20OR%201%3D1--"
```

예상 결과는 WAF `403`이다. 반복 실행하지 않는다.

## 실시간 공격 로그 확인

CloudWatch 리전을 `us-east-1`로 바꾸고 Logs Insights에서
`aws-waf-logs-gochuchamchi-edge`를 선택한다.

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

## 중앙 Athena 확인

Firehose 버퍼 때문에 Workload 적용 및 테스트 후 S3 객체가 나타날 때까지 약 5분 기다린다.

- 계정: Log `564186750363`
- 리전: `ap-northeast-2`
- Workgroup: `gochuchamchi-security-logs`
- Database: `gochuchamchi_security_logs`
- Table: `waf_logs`

```sql
SHOW TABLES IN gochuchamchi_security_logs;
```

`cloudtrail_logs`, `vpc_flow_logs`, `waf_logs`가 보여야 한다.

오늘 차단된 요청:

```sql
SELECT
    from_unixtime("timestamp" / 1000.0) AS event_time,
    terminatingruleid,
    httprequest.clientip,
    httprequest.country,
    httprequest.httpmethod,
    httprequest.uri,
    httprequest.args
FROM gochuchamchi_security_logs.waf_logs
WHERE year = date_format(current_timestamp, '%Y')
  AND month = date_format(current_timestamp, '%m')
  AND day = date_format(current_timestamp, '%d')
  AND action = 'BLOCK'
ORDER BY event_time DESC
LIMIT 100;
```

## 공격 판정 문구

- `BLOCK`: WAF가 차단한 공격 시도. 침해 성공을 의미하지 않는다.
- `COUNT/ALLOW`에서 공격 패턴 확인: 앱 및 DB 감사 로그까지 긴급 조사한다.
- WAF 차단 후 앱/DB 영향 없음: 방어 성공.
- 앱 도달 및 비정상 SQL/데이터 접근 확인: 실제 침해 가능성이 높다.

