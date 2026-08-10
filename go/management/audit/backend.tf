terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-307223751140"
    key          = "management/audit/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "management-admin"
    encrypt      = true
    use_lockfile = true
  }
}
