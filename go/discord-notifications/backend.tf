# Terraform 1.10+: DynamoDB 없이 S3 네이티브 잠금(use_lockfile) 사용
terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-828885965304"
    key          = "discord-notifications/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "workload-admin"
    encrypt      = true
    use_lockfile = true

    # (2026-08-13) SSE-KMS. encrypt=true 만 두면 terraform 이 AES256 을 명시적으로
    # 보내 버킷 기본 암호화를 덮어쓴다 — 이유는 ../terraform/backend.tf 주석 참고.
    kms_key_id = "arn:aws:kms:ap-northeast-2:828885965304:alias/gochuchamchi-tfstate"
  }
}
