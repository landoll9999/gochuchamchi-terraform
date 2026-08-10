# Terraform 1.10+: DynamoDB 없이 S3 네이티브 잠금(use_lockfile) 사용
terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-828885965304"
    key          = "eks/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "workload-admin"
    encrypt      = true
    use_lockfile = true
  }
}
