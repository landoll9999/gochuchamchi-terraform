# 보안 사고 대응 Runbook

이 문서는 보안 알람이 발생했을 때 팀원이 동일한 순서로 조사·차단·복구하기 위한 실행 매뉴얼이다. 탐지 정책을 설명하는 보고서가 아니라, 사고 중 그대로 따라 하는 절차서다.

## 1. 적용 환경

| 구분 | 값 |
|---|---|
| Management 계정 | `307223751140` |
| Security/Log 계정 | `564186750363` |
| Workload 계정 | `828885965304` |
| 서울 리전 | `ap-northeast-2` |
| CloudFront WAF 리전 | `us-east-1` |
| CloudWatch 보안 대시보드 | `gochuchamchi-security-overview` |
| Athena Workgroup | `gochuchamchi-security-logs` |
| Athena Database | `gochuchamchi_security_logs` |

AWS CLI 프로파일은 Management `management-admin`, Log `log-admin`, Workload `workload-admin`을 사용한다.

## 2. 대응 원칙

1. **증거를 먼저 확인하고 차단한다.** 단일 4xx나 로그인 실패 1건만으로 IP를 차단하지 않는다.
2. **WAF `BLOCK`은 공격 시도 차단이지 침해 성공이 아니다.** 애플리케이션·ALB·DB 영향까지 확인해야 성공 여부를 판단할 수 있다.
3. **WAF `ALLOW`도 정상 보장은 아니다.** 앱의 4xx/5xx, 로그인 실패, 권한 거부와 상관분석한다.
4. 원본 로그를 수정하거나 삭제하지 않는다. 중앙 로그 S3/Object Lock과 Athena 결과를 증거로 사용한다.
5. 비밀번호, JWT, Cookie, Authorization 헤더, 요청 Body를 Discord·GitHub Issue에 복사하지 않는다.
6. 긴급 변경은 담당자, 시간, 근거, 만료 시간을 기록한다. 사고 종료 후 Terraform 코드와 실제 설정의 차이를 제거한다.
7. 시간은 화면의 타임존을 확인하고 기록에는 UTC와 KST를 함께 남긴다.

## 3. 사고 등급

| 등급 | 기준 | 초기 대응 목표 |
|---|---|---|
| P1 긴급 | AWS 관리자 탈취, 데이터 변경·유출 정황, 서비스 전체 장애, 공격 요청의 명령 실행 정황 | 즉시 대응, 다른 작업 중단 |
| P2 높음 | WAF 우회 후 반복 5xx·권한 우회, 계정 탈취 의심, 특정 기능 장애 | 15분 이내 조사 시작 |
| P3 보통 | WAF가 정상 차단했고 내부 영향 없음, 반복 스캔·Rate Limit | 당일 분석·임시 차단 판단 |
| P4 관찰 | 단발성 차단, 정상 사용자 오동작 가능성 | 기록 후 추세 관찰 |

등급을 확정하기 전에는 우선 P2로 시작한다. 내부 영향이나 자격증명 탈취가 확인되면 P1으로 올린다.

## 4. 최초 5분 공통 절차

### 4.1 담당자 지정

- 대응 책임자 1명: 조치 승인과 등급 결정
- 조사 담당자 1명: CloudWatch/Athena 증거 수집
- 기록 담당자 1명: 타임라인과 변경사항 기록

인원이 부족하면 한 사람이 겸임하되, 차단처럼 서비스에 영향을 주는 변경은 가능하면 다른 팀원에게 근거를 확인받는다.

### 4.2 계정 확인

변경 전 반드시 현재 AWS 계정을 확인한다.

```powershell
aws sts get-caller-identity --profile management-admin
aws sts get-caller-identity --profile log-admin
aws sts get-caller-identity --profile workload-admin
```

조사만 할 때도 어느 계정·리전 화면인지 먼저 기록한다.

### 4.3 최초 기록

다음 값을 사고 기록에 먼저 적는다.

- 최초 알람 시간과 알람 이름
- 현재 사고 등급
- 관련 IP, 계정, URI, 요청 ID
- 현재 서비스 영향: 정상 / 부분 장애 / 전체 장애
- 지금까지 수행한 변경

## 5. 알람별 조회 위치

| 알람 또는 현상 | 1차 확인 | Athena 저장 쿼리 | 다음 판단 |
|---|---|---|---|
| `gochuchamchi-waf-total-blocked` | 대시보드 WAF 위젯 | `07`, `08` | 어떤 규칙·IP·URI가 증가했는가 |
| `gochuchamchi-waf-rate-limit-blocked` | WAF Rate Limit 추이 | `08` | 단일 IP 폭주인가 분산 공격인가 |
| `gochuchamchi-waf-sqli-blocked` | WAF SQLi 규칙 | `07`, `16` | 차단 후 앱까지 유사 요청이 도달했는가 |
| `gochuchamchi-waf-known-bad-blocked` | WAF Known Bad 규칙 | `07`, `08` | 반복 IP와 대상 URI가 무엇인가 |
| `gochuchamchi-app-http-4xx` | 앱 4xx 위젯 | `09`, `10`, `14`, `15` | 정상 오류인가 스캔·인증 공격인가 |
| `gochuchamchi-app-http-5xx` | 앱 5xx 위젯 | `11`, `15`, `16` | 공격 요청이 내부 예외를 유발했는가 |
| `gochuchamchi-app-login-failure` | 인증·권한 위젯 | `12`, 필요 시 `10` | 동일 IP가 여러 계정을 공격하는가 |
| `gochuchamchi-app-access-denied` | 인증·권한 위젯 | `12`, `13`, `16` | 정상 권한 부족인가 우회 시도인가 |
| `gochuchamchi-app-high-security-event` | HIGH/CRITICAL 위젯 | `13`, `16` | 계정·권한·중요 데이터 변경인가 |
| ALB Target 4xx/5xx·Unhealthy | 가용성 위젯 | `11`, `14`, `15` | ALB 거부인가 Spring 내부 오류인가 |
| AWS 콘솔 변경·CloudTrail 의심 | 알림의 actor/eventName | `01`, `02`, `03` | 누가 어느 IP에서 무엇을 변경했는가 |
| 포트 스캔·네트워크 이상 | VPC Flow Logs | `04`, `05`, `06` | REJECT만 있었나 ACCEPT·대량 전송이 있었나 |
| Firehose 지연 | 로그 수집 위젯 | 해당 Firehose 상태 | 공격이 아니라 탐지 공백인가 |

## 6. Athena 조회 절차

1. Log 계정 `564186750363`으로 접속한다.
2. 리전을 `ap-northeast-2`로 선택한다.
3. Athena Query editor를 연다.
4. Workgroup을 `gochuchamchi-security-logs`로 변경한다.
5. Database를 `gochuchamchi_security_logs`로 선택한다.
6. Saved queries에서 위 표의 번호를 실행한다.
7. 중요한 결과는 Query execution ID와 실행 시간을 사고 기록에 남긴다.

> **중요:** 현재 Athena `cloudtrail_logs` 테이블은 Workload 계정 `828885965304`의 Organization Trail S3 경로만 조회한다. 따라서 `01`~`03`은 Workload 조사용이며 Management·Log 계정의 전체 이력을 보장하지 않는다. Management 또는 Log 계정 사고는 해당 계정·리전의 CloudTrail **Event history**와 중앙 S3 원본 경로를 추가 확인한다. 이 두 계정용 Athena 테이블 추가는 후속 구현 항목이다.

저장 쿼리 역할은 다음과 같다.

- `01` 최근 CloudTrail 관리 이벤트
- `02` 실패한 AWS API 호출
- `03` AWS 리소스 쓰기·변경 이벤트
- `04` VPC Flow Logs REJECT 상위
- `05` 포트 스캔 후보
- `06` 네트워크 전송량 상위
- `07` WAF 차단 요청 상세
- `08` WAF 공격 IP 집계
- `09` 애플리케이션 상태 코드 집계
- `10` 애플리케이션 4xx 상위 IP·URI
- `11` 애플리케이션 5xx·예외·파드
- `12` 로그인 실패·권한 거부
- `13` HIGH/CRITICAL 보안 이벤트
- `14` ALB/Target 상태 코드 집계
- `15` ALB 오류 요청 상세
- `16` WAF가 허용했지만 앱에서 실패한 요청 상관분석

## 7. WAF 공격 대응

### 7.1 WAF가 차단한 경우

1. `07-waf-blocked-request-details`로 규칙, IP, 국가, Method, URI, Query String을 확인한다.
2. `08-waf-top-attacking-ips`로 동일 IP의 차단 횟수와 대상 URI 수를 확인한다.
3. 같은 시간대 `16-waf-allow-application-failure-correlation`을 실행한다.
4. 앱 5xx·권한 거부·DB 변경이 없다면 **방어 성공**으로 기록한다.
5. 반복성이 높으면 임시 IP 차단 여부를 판단한다.

WAF 로그의 주요 필드는 `action`, `terminatingRuleId`, `clientIp`, `httpMethod`, `uri`, `args`다. WAF가 차단한 첫 번째 종료 규칙만으로 요청의 모든 악성 요소를 설명할 수는 없다.

### 7.2 WAF가 허용했지만 공격이 의심되는 경우

다음 중 하나가 있으면 P2 이상으로 조사한다.

- 동일 시간대 애플리케이션 5xx 발생
- 로그인 실패 또는 권한 거부 반복
- 평소 사용하지 않는 URI·Method 호출
- WAF `ALLOW` 요청과 앱 오류의 CloudFront Request ID가 일치
- 같은 actor의 중요 계정·권한 변경
- DB 감사 로그의 비정상 DDL/DML 또는 대량 조회 정황

조사 순서는 `16` → `11` → `15` → 필요 시 DB 감사 로그다. 내부 데이터 변경이나 명령 실행이 확인되면 P1으로 올린다.

## 8. IP 차단 판단 기준

### 8.1 차단 근거가 강한 경우

- SQLi·Known Bad 규칙에 반복 차단됨
- 5분 동안 로그인 또는 관리자 URI를 비정상적으로 반복 호출함
- 여러 계정에 같은 방식으로 로그인을 시도함
- 존재하지 않는 URI·다수 URI를 자동화된 형태로 탐색함
- WAF 차단 후에도 다른 공격 경로로 지속 시도함
- 정상 업무 요청 없이 공격 패턴만 반복됨

### 8.2 차단을 보류할 경우

- 단일 4xx 또는 로그인 실패 1~2건뿐임
- 회사·학교·통신사 NAT처럼 여러 사용자가 IP를 공유할 수 있음
- 정상 모니터링, 검색엔진, 결제·외부 API 제공자의 IP일 가능성이 있음
- 같은 IP지만 User-Agent·세션·행동이 서로 다른 정상 사용자로 보임

### 8.3 차단 기간

| 상황 | 권장 기간 |
|---|---|
| 조사 중 반복 요청을 멈추기 위한 긴급 조치 | 1시간 |
| SQLi·자동 스캔 등 명확한 악성 반복 | 24시간 |
| 장기 차단 | 책임자 승인 및 오탐 검토 후 결정 |

모든 차단에는 IP/CIDR, 근거 쿼리 ID, 시작·만료 시각, 승인자와 해제 결과를 기록한다. IP가 여러 개로 계속 바뀌면 IP 차단을 확대하기보다 Rate Limit, Challenge/CAPTCHA, URI·Method 정책을 사용한다.

### 8.4 현재 구현 상태

현재 Terraform에는 긴급 차단용 `aws_wafv2_ip_set`이 없다. 따라서 이 Runbook 작성 시점에는 반복 가능한 표준 IP 차단 명령이 준비되지 않았다.

- P1/P2에서 임시 콘솔 차단이 필요하면 Workload 담당자와 책임자 승인을 받고 수행한다.
- CloudFront WAF 리소스이므로 반드시 `us-east-1`에서 작업한다.
- 수동 변경은 사고 기록에 남기고, 사고 종료 전에 Terraform 코드로 이관하거나 원복한다.
- 다음 보안 작업에서 긴급 차단 IP Set, 만료 관리, 검증 절차를 코드로 추가한다.

## 9. 애플리케이션 계정 탈취 대응

### 9.1 의심 기준

- 동일 계정이 짧은 시간에 여러 국가·IP에서 로그인됨
- 여러 실패 직후 낯선 IP에서 로그인 성공
- 로그인 뒤 비밀번호·이메일·권한·배송지 등 중요 정보 변경
- 사용자가 수행하지 않은 주문·상품·관리자 작업 존재
- 동일 세션에서 비정상 URI 접근 또는 권한 거부 반복

### 9.2 목표 절차

1. 계정을 일시 잠금해 신규 로그인을 중단한다.
2. 해당 사용자의 모든 Spring Session과 Refresh Token을 폐기한다.
3. 최근 로그인, 권한 변경, 주문·상품·데이터 변경을 조사한다.
4. 검증된 비밀번호 재설정 절차를 통해 사용자가 새 비밀번호를 설정하게 한다.
5. 필요하면 MFA와 복구 수단을 재등록한다.
6. 본인 확인과 영향 조사가 끝난 후 계정을 해제한다.

### 9.3 현재 구현 상태와 금지사항

현재 Terraform 저장소에서는 사용자별 계정 잠금 API, 사용자별 Redis 세션 삭제 방식, Refresh Token 폐기 기능을 확인할 수 없다. 따라서 다음 조치를 임의로 실행하지 않는다.

- 사용자 테이블 구조를 확인하지 않고 DB를 직접 `UPDATE`
- Redis에서 `FLUSHALL` 또는 전체 세션 삭제
- 운영자가 임의의 공용 비밀번호로 변경
- 비밀번호·세션 토큰을 Discord나 문서에 기록

Spring 저장소에서 계정 상태 필드, 세션-사용자 매핑, 비밀번호 재설정 기능을 확인한 뒤 이 절차에 정확한 관리자 명령/API를 추가해야 한다. 그 전에는 애플리케이션 담당자에게 P1/P2로 에스컬레이션하고, 필요하면 WAF에서 관련 공격 IP·URI를 임시 제한한다.

## 10. AWS 팀원 계정 탈취 대응

대상은 IAM Identity Center 사용자다. Management 계정 담당자가 수행한다.

### 10.1 즉시 조치

1. 의심 사용자의 username과 Identity Store User ID를 확인한다.
2. 긴급 Deny SCP가 준비돼 있다면 해당 User ID를 넣어 기존 IAM Role 세션의 작업을 차단한다.
3. 해당 사용자의 직접 Permission Set 할당을 제거한다.
4. 그룹을 통한 권한이면 관련 그룹에서 사용자를 제거한다.
5. IAM Identity Center → Users → 대상 사용자 → **Active sessions**에서 세션을 삭제한다.
6. 세션 삭제 후 **Disable user access**로 신규 로그인을 막는다.
7. 비밀번호와 MFA를 재설정한다.
8. Workload 권한 사용 여부는 Log 계정 Athena에서 `01`, `02`, `03`을 실행해 조사한다.
9. Management·Log 계정 자체 작업은 각 계정 CloudTrail Event history와 중앙 S3 원본을 별도로 조사한다.

현재 Permission Set 세션 시간은 코드상 4시간이다. 포털 세션을 삭제하거나 사용자를 비활성화해도 이미 발급된 IAM Role 세션은 별도로 지속될 수 있으므로, 즉시 권한 차단이 필요할 때는 User ID 기반 Deny SCP가 필요하다.

### 10.2 조사할 CloudTrail 이벤트

- IAM·Identity Center·Organizations·CloudTrail 설정 변경
- Access Key, 정책, 역할, 사용자 생성·수정
- S3 버킷 정책·Object Lock·KMS 정책 변경 시도
- WAF·CloudFront·Security Group 변경
- 로그 삭제·중지 시도
- 평소와 다른 source IP, User-Agent, 리전

### 10.3 복구 조건

- 의심 세션과 할당이 모두 제거됨
- 비밀번호와 MFA 재설정 완료
- 악성 변경사항이 원복됨
- CloudTrail 조사 범위와 결과가 기록됨
- 책임자가 재활성화를 승인함

AWS 공식 절차 참고:

- [IAM Identity Center 활성 Role 세션 폐기](https://docs.aws.amazon.com/singlesignon/latest/userguide/revoke-user-permissions.html)
- [Identity Center 세션 동작](https://docs.aws.amazon.com/singlesignon/latest/userguide/authconcept.html)

## 11. 로그 수집 장애 대응

Firehose 지연이나 Athena 데이터 누락은 공격 자체가 아니라 **탐지 공백**이다.

1. 대시보드 `Central log-delivery pipeline health`에서 어떤 stream이 지연됐는지 확인한다.
2. Log 계정 서울 리전에서 Firehose 상태와 `DeliveryToS3.DataFreshness`, `ThrottledRecords`를 확인한다.
3. 대상 S3 prefix의 최신 객체 시간을 확인한다.
4. Workload 로그 그룹과 subscription filter 상태를 확인한다.
5. WAF 로그 문제라면 Workload `us-east-1` 로그 그룹과 Log 계정 `us-east-1` Destination을 함께 확인한다.
6. 수집 공백 시작·종료 시간과 영향받은 로그 종류를 사고 기록에 남긴다.

수집 장애 중에는 "알람이 없었다"를 "공격이 없었다"로 판단하지 않는다.

## 12. 사고 종료 조건

다음 항목을 모두 확인해야 종료한다.

- 공격 또는 장애의 시작·종료 시간이 확인됨
- 영향을 받은 계정·URI·리소스·데이터 범위가 확인됨
- 악성 세션·권한·변경이 제거 또는 원복됨
- 임시 차단의 만료 또는 장기 정책 전환이 결정됨
- 로그 수집이 정상이며 증거가 보존됨
- 정상 사용자 경로와 서비스 상태가 검증됨
- 재발 방지 작업의 담당자와 기한이 지정됨

## 13. 사고 기록 양식

```markdown
# SEC-YYYYMMDD-NN 사고 기록

- 등급: P1 / P2 / P3 / P4
- 최초 탐지 시각(UTC/KST):
- 종료 시각(UTC/KST):
- 최초 알람:
- 대응 책임자 / 조사 담당자 / 기록 담당자:
- 영향 계정·서비스·사용자:

## 타임라인

| 시각 | 담당자 | 확인·조치 | 근거 또는 결과 |
|---|---|---|---|

## 주요 증거

- Athena Query execution ID:
- 관련 IP/CIDR:
- 관련 URI·Method:
- request_id / cloudfront_request_id:
- CloudTrail actor / eventName / source IP:

## 차단·복구

- 차단 대상과 근거:
- 시작·만료 시각:
- 계정 잠금·세션 폐기 여부:
- 비밀번호·MFA 초기화 여부:
- 원복·복구 검증:

## 결론

- 공격 시도 / 방어 성공 / 침해 의심 / 침해 확인 / 오탐:
- 영향 범위:
- 재발 방지 작업, 담당자, 기한:
```

## 14. 후속 구현 목록

Runbook을 실제로 끝까지 실행하려면 다음 기능을 추가해야 한다.

- Terraform 관리 긴급 WAF IPv4/IPv6 IP Set과 만료 절차
- 로그인·관리자 URI 전용 Rate Limit
- 애플리케이션 사용자 계정 잠금·해제 관리자 기능
- 사용자별 Spring Session·Refresh Token 전체 폐기
- 안전한 비밀번호 재설정과 MFA 재등록
- Identity Center User ID 기반 긴급 Deny SCP 사전 준비
- Management·Log 계정 CloudTrail용 Athena 테이블과 저장 쿼리
- DB 감사 로그와 애플리케이션 사용자·요청 ID 상관분석 절차

이 항목이 구현될 때마다 이 문서의 "현재 구현 상태"를 실제 명령과 검증 방법으로 교체한다.
