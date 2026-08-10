# Management account

AWS Organizations 관리 계정(`307223751140`) 전용 Terraform 루트입니다.

- `organization/`: Organizations, OU, SCP, IAM Identity Center 권한 세트
- `audit/`: 조직 전체 CloudTrail

업무 워크로드, 로그 버킷, KMS 키, 백업 볼트는 이 계정에 만들지 않습니다.
