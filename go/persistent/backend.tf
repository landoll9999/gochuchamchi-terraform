# Terraform 1.10+: DynamoDB 없이 S3 네이티브 잠금(use_lockfile) 사용
# (../terraform, ../discord-notifications 와 동일 패턴, key만 다름)
terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-307223751140"
    key          = "persistent/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "admin"
    encrypt      = true
    use_lockfile = true
  }
}
