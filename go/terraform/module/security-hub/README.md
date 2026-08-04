# Security Hub module

현재 AWS provider 리전에서 Security Hub CSPM을 활성화하고 보안 표준을 명시적으로 관리하는 독립 모듈입니다.
이 폴더에는 provider 설정이 없으며 호출하는 루트 모듈의 AWS provider를 상속합니다.

## 기본 구성

- Security Hub CSPM 활성화
- AWS 기본 표준 자동 활성화 비활성화
- AWS Foundational Security Best Practices v1.0.0 명시적 활성화
- CIS AWS Foundations Benchmark v3.0.0 선택적 활성화
- 새 Control 자동 활성화
- `SECURITY_CONTROL` 방식의 통합 Control Finding 사용

Security Hub 표준은 AWS Config의 리소스 기록을 이용하므로 AWS Config 모듈을 먼저 적용해야 합니다.
GuardDuty는 이후 활성화하면 Security Hub와 자동으로 연동되므로 별도 Product Subscription을 만들지 않습니다.

## 메인 코드 연결 (적용 완료)

루트 `terraform/security-hub.tf`에서 다음과 같이 호출하고 있습니다.

```hcl
module "security_hub" {
  source = "./module/security-hub"

  enable_foundational_security_best_practices = true
  enable_cis_aws_foundations_benchmark_v3     = var.security_hub_enable_cis_benchmark_v3
  auto_enable_new_controls                    = true

  depends_on = [
    module.aws_config
  ]
}
```

현재는 FSBP만 활성화되어 있습니다. CIS 점검이 필요해지면 루트 `variables.tf`의
`security_hub_enable_cis_benchmark_v3` 기본값을 `true`로 바꾸거나
`-var="security_hub_enable_cis_benchmark_v3=true"`로 적용합니다.

## 주의사항

- Security Hub는 계정과 리전별로 활성화됩니다. 이 모듈은 현재 provider 리전 하나를 대상으로 합니다.
- 해당 리전에 Security Hub가 이미 활성화되어 있다면 새로 생성하지 말고 Terraform으로 import해야 합니다.
- 표준을 활성화하면 보안 검사 및 Finding 수집 비용이 발생할 수 있습니다.
- 보안 점수와 일부 Finding은 AWS Config 기록이 시작된 후 시간이 지나야 표시됩니다.