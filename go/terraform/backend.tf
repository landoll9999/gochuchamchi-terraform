# Terraform 1.10+: DynamoDB 없이 S3 네이티브 잠금(use_lockfile) 사용
terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-828885965304"
    key          = "eks/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "workload-admin"
    encrypt      = true
    use_lockfile = true

    # (2026-08-13) SSE-S3 -> SSE-KMS.
    #   encrypt=true 만 두고 kms_key_id 를 비우면 terraform 이 AES256 을 "명시적으로"
    #   보내기 때문에 버킷 기본 암호화(KMS)를 덮어써 버린다. 즉 버킷만 바꿔서는
    #   state 가 계속 SSE-S3 로 저장된다. 여기에 키를 적어야 실제로 적용된다.
    #   키는 scripts/bootstrap-state.ps1 이 만든다(terraform 밖 — 자기 state 를
    #   암호화하는 키를 자기가 관리하면 지웠을 때 복구 수단까지 잠긴다).
    #   별칭 ARN 을 쓰는 이유는 키를 재생성해도 이 값이 안 바뀌게 하기 위해서다.
    kms_key_id = "arn:aws:kms:ap-northeast-2:828885965304:alias/gochuchamchi-tfstate"
  }
}
