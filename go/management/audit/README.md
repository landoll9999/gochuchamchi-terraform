# Management / audit

이 루트는 Security/Log의 archive 루트가 성공한 뒤 실행합니다.

1. log-archive에서 bucket name과 KMS key ARN을 확인합니다.
2. terraform.tfvars.example을 복사해 실제 KMS key ARN을 넣습니다.
3. Management 계정 자격증명으로 plan/apply합니다.

기존 2계정 코드에서 이미 gochuchamchi-org-trail을 만들었다면 새로 생성하지 말고
해당 Trail을 이 state로 import해야 합니다. Log state의 removed 블록을 먼저 적용해
실물 Trail을 보존한 뒤 import하는 순서를 사용합니다.
