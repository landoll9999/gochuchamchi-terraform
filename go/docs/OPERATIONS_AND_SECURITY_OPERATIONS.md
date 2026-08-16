# 운영·보안 관제 운영 원칙

## 역할 분리

| 도구 | 담당 | 사용 시점 |
|---|---|---|
| Grafana | 서비스 부하, 장애, EKS·RDS·Redis 상태 | 서비스가 느리거나 오류가 날 때 |
| EventBridge → SNS → Discord | 즉시 위험 알림 | IAM 변경, GuardDuty, WAF·CloudWatch 경보 발생 시 |
| Athena | 상세 조사, 상관 분석, 감사 증적 | 알림이 의심스럽거나 사후 감사가 필요할 때 |
| 중앙 S3 로그 아카이브 | 변경 방지 장기 보관 | Athena의 원본 증적 저장소 |

## Grafana 대시보드

1. **01 Service & Dependencies**: ALB 5XX·비정상 Target, RDS·Redis 오류를 보고 사용자 영향과 의존성 장애를 확인한다.
2. **02 Platform Health**: Worker Node, Pod 상태, CPU·메모리, Pending Pod, 재시작 횟수를 확인한다.
3. **03 Application Logs**: 애플리케이션 ERROR/WARN, Exception, Pod별 로그·오류량을 확인한다.

Grafana는 운영 화면이다. 공격 IP·CloudTrail 원문·VPC Flow 원문을 상시 대시보드에 올리지 않는다.

## Discord 알림을 받은 뒤 Athena 조사

1. 알림의 행위자·IP·UTC 시각·계정·이벤트가 예상한 작업인지 먼저 확인한다.
2. 의심스러우면 Athena 콘솔에서 `security_logs` 데이터베이스와 보안 로그 Workgroup을 선택한다.
3. Saved queries에서 알림 유형에 맞는 `IR-*` 쿼리를 연다.
4. 쿼리 상단의 `YYYY/MM/DD`, `REPLACE_WITH_SOURCE_IP`, `REPLACE_WITH_ACTOR_FRAGMENT`만 실제 값으로 바꿔 실행한다.
5. 결과를 근거로 권한 회수·격리·차단·사고 기록 여부를 결정한다.

| 알림 유형 | 실행할 쿼리 |
|---|---|
| IAM 변경·AssumedRole 활동 | `IR-01`, `IR-02` |
| WAF 차단·웹 공격 | `IR-03`, `IR-05` |
| 포트 스캔·비정상 통신 | `IR-04` |
| DB 인증 실패·DDL·권한 변경 | `IR-06` |

Athena는 S3 적재 지연이 있을 수 있으므로, 실시간 차단이나 격리는 Athena 결과를 기다리지 않는다. 즉시 대응은 기존 EventBridge·GuardDuty·격리 Lambda 경로가 담당한다.
