# 3계정 최종 구조

## 계정 매핑

| 역할 | 계정 ID | 실행 프로파일 |
|---|---:|---|
| Management | 307223751140 | management-admin |
| Security/Log | 564186750363 | log-admin |
| Workload | 828885965304 | workload-admin |

## Terraform 루트

### Management

- management/organization: Organizations, OU, SCP, IAM Identity Center Permission Set
- management/audit: Organization Trail

### Security/Log

- log-archive: S3 Object Lock, KMS, Firehose, CloudWatch Logs Destination, Athena/Glue

### Workload

- persistent: ECR, 데이터·서명 KMS, GitHub OIDC, Secret 컨테이너
- account-baseline: GuardDuty, Config, Security Hub, Inspector, 계정 하드닝
- cloudwatch-notifications: SNS, EventBridge, Lambda, GuardDuty 대응
- terraform: 매일 생성·삭제하는 현재 런타임 state
- discord-notifications: EKS가 뜬 뒤 적용하는 Kubernetes 알림 설정

각 루트에는 계정 ID guard가 들어 있어 다른 계정 프로파일로 apply하면 중단된다.

## 최초 구축 순서

1. 세 계정에서 각각 tfstate 버킷을 준비한다. 프로젝트 루트에서 아래 스크립트를
   계정별로 한 번씩 실행하면 계정 ID를 검증하고 버저닝·퍼블릭 차단·암호화·TLS 정책을 설정한다.

   ```powershell
   .\scripts\bootstrap-state.ps1 -Account management
   .\scripts\bootstrap-state.ps1 -Account log
   .\scripts\bootstrap-state.ps1 -Account workload
   ```

2. Management의 management/organization을 적용한다.
3. 564186750363과 828885965304를 Organization에 초대하고 각 계정에서 수락한다.
4. Log를 Security OU, Workload를 Workloads OU로 이동한다.
5. Log 계정에서 log-archive를 적용한다.
6. Management 계정에서 management/audit를 적용한다.
7. Workload의 persistent, account-baseline, cloudwatch-notifications를 적용한다.
8. Workload의 terraform을 적용하고 EKS 생성 후 discord-notifications를 적용한다.
9. Log 아카이브 검증 후 Management에서 enable_log_archive_protection_scp=true로 잠근다.

## 기존 state 주의

이 변경은 backend 계정 ID도 바꾼다. 실제 AWS 리소스가 이미 존재한다면
terraform init -migrate-state 또는 새 계정 apply를 바로 실행하면 안 된다.

- 기존 564 계정의 Workload를 828 계정에 재구축할 계획이면 828의 새 backend에서
  시작하고, 기존 564 Workload는 기존 코드/state로 별도 teardown한 뒤 Log 계정으로
  전환한다.
- 기존 307 계정에 Log 리소스가 이미 있다면 Object Lock과 KMS 상태를 먼저 확인하고
  564로 새 아카이브를 구축한다. 잠긴 로그 객체를 강제로 이동·삭제하지 않는다.
- 기존 Org Trail이 Log state에 있다면 log-archive의 removed 블록으로 실물 삭제 없이
  state에서 분리한 뒤 management/audit state로 import한다.

## 일일 운영

매일 건드리는 루트:

- terraform
- discord-notifications

매일 건드리지 않는 루트:

- management/organization
- management/audit
- log-archive
- persistent
- account-baseline
- cloudwatch-notifications

현재 terraform state에는 RDS, EFS, 상품 이미지 S3, 백업 리소스가 아직 함께 있다.
원격 state를 확인하지 않고 파일만 이동하면 삭제·재생성 계획이 생기므로 이번 계정
분리에서는 주소를 유지했다. 다음 단계에서 state 이관 계획과 함께 runtime/data를
분리한다.

## 도쿄 DR

현재 비용 우선 운영에서는 `enable_dr`의 기본값을 `false`로 설정했다. 서울 Security/Log 계정의
cross-account Backup Vault와 Vault Lock을 별도 단계로 만든 뒤 도쿄 복사를 활성화한다.
