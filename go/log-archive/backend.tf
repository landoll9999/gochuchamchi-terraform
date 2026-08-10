# 이 계층의 state는 Security/Log 계정(564186750363)의 전용 tfstate 버킷을 쓴다.
# Workload(828885965304)와 Management(307223751140)의 자격증명은 이 state에
# 접근하지 않는다.
terraform {
  backend "s3" {
    bucket       = "gochuchamchi-tfstate-564186750363"
    key          = "log-archive/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "log-admin"
    encrypt      = true
    use_lockfile = true
  }
}
