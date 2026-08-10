# AWS Config module

기존 중앙 로그 S3 버킷에 AWS Config 구성 이력과 스냅샷을 저장하는 재사용 모듈입니다.
이 폴더 자체에는 AWS provider 설정이 없으며, 호출하는 루트 모듈의 provider를 상속합니다.

## 생성 리소스

- AWS Config customer-managed Configuration Recorder
- AWS Config S3 Delivery Channel
- Configuration Recorder Status
- AWS Config IAM Role
- `AWS_ConfigRole` AWS 관리형 정책 연결
- 중앙 S3 전달용 최소 IAM 정책

기본적으로 모든 현재/미래 지원 리소스를 `CONTINUOUS` 방식으로 기록하고 글로벌 IAM 리소스도 포함합니다.
Config Rule은 Security Hub 구성 단계에서 중복되지 않도록 이 모듈에 포함하지 않았습니다.

## 메인 코드 연결 (적용 완료)

루트 `terraform/aws-config.tf`에서 다음과 같이 호출하고 있습니다.

```hcl
module "aws_config" {
  source = "./module/aws-config"

  name_prefix    = "gochuchamchi"
  s3_bucket_name = aws_s3_bucket.cloudwatch_log_archive.id
  s3_bucket_arn  = aws_s3_bucket.cloudwatch_log_archive.arn
  s3_key_prefix  = local.aws_config_s3_key_prefix

  include_global_resource_types = true
  snapshot_delivery_frequency   = var.aws_config_snapshot_delivery_frequency

  tags = local.cloudwatch_log_archive_tags

  depends_on = [
    aws_s3_bucket_policy.cloudwatch_log_archive,
    aws_s3_bucket_server_side_encryption_configuration.cloudwatch_log_archive,
    aws_s3_bucket_versioning.cloudwatch_log_archive
  ]
}
```

전달 주기는 루트 `variables.tf`의 `aws_config_snapshot_delivery_frequency`로 조정합니다.

저장 경로는 다음 형태입니다.

```text
s3://<중앙-로그-버킷>/config/AWSLogs/<계정ID>/Config/
```

## 주의사항

- 이 모듈은 현재 프로젝트처럼 AWS Config와 S3가 같은 계정에 있는 구성을 대상으로 합니다.
- AWS Config Configuration Recorder와 Delivery Channel은 계정/리전당 하나만 만들 수 있습니다.
- 해당 리전에 기존 Recorder 또는 Delivery Channel이 있다면 새로 만들지 말고 Terraform으로 import해야 합니다.
- AWS Config는 기록한 Configuration Item 수와 Rule 평가 수에 따라 비용이 발생합니다.