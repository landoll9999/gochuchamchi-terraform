# =============================================================================
# Security/Log 계정 계층 — 564186750363
#
# 계정 관계:
#   307223751140  Management — Organizations/SCP/Identity Center/Org Trail
#   564186750363  Security/Log — 이 계층(S3/KMS/Object Lock/Firehose/Athena)
#   828885965304  Workload — EKS/VPC/RDS와 애플리케이션
#
# apply 주체는 log-admin이다. Workload나 Management에서 이 계정의 관리자
# 역할을 AssumeRole하는 신뢰 경로를 만들지 않는다.
#
# Org Trail 리소스는 ../management/audit에서 관리하고, 실제 로그만 여기 저장한다.
# Workload는 고정된 버킷·Destination ARN을 조립해 이 계정으로 로그를 보낸다.
# =============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.log_profile
}

# CloudFront 범위 WAF의 CloudWatch Logs는 us-east-1에만 존재한다. WAF 로그
# 구독용 cross-account Destination만 버지니아에 만들고, 실제 Firehose/S3/Athena는
# 기존 서울 리전 Log 계정에 유지한다.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.log_profile
}

data "aws_caller_identity" "current" {}

# Security/Log 계정이 Organization에 가입한 뒤 현재 Organization ID를 읽는다.
data "aws_organizations_organization" "current" {}

locals {
  org_id              = data.aws_organizations_organization.current.id
  workload_account_id = var.workload_account_id
}
