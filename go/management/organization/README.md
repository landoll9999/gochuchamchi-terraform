# Management / organization

이 루트는 307223751140에서만 실행합니다.

초기 순서:

1. Management 계정에 tfstate 버킷을 먼저 준비합니다.
2. 이 루트를 apply해 Organization, OU, SCP를 만듭니다.
3. 기존 계정 564186750363과 828885965304를 콘솔에서 초대하고 각 계정 root가 수락합니다.
4. Log 계정은 Security OU, Workload 계정은 Workloads OU로 이동합니다.
5. IAM Identity Center를 Management 콘솔에서 활성화합니다.
6. enable_identity_center_configuration=true로 변경해 Permission Set을 만듭니다.
7. Log 아카이브 구축·검증 후 enable_log_archive_protection_scp=true로 잠급니다.

계정 초대·수락과 사용자/그룹 할당은 이메일·Principal ID가 필요한 일회성 절차라
이 Terraform state에 포함하지 않습니다.
