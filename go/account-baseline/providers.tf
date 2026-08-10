# =============================================================================
# 계정 기준선(account-baseline) 계층
#
# 여기 있는 것들의 공통점 — "지워도 돈이 안 아끼는데, 지우면 apply가 실패하는 것"
#
#   계정당 하나만 존재한다      GuardDuty 디텍터 / Config 레코더 / Security Hub /
#                              Inspector2 enabler / ECR 레지스트리 스캔 설정
#   destroy가 실패하거나 느리다  Inspector2는 5분 타임아웃 후 tainted로 남는다 (8/4 §5.2)
#   재구축이 오히려 비용이다      Config는 apply 한 사이클에 구성 항목 수천 건을 기록한다
#   애초에 못 지운다            로그 아카이브 버킷은 Object Lock COMPLIANCE (8/4 §5.5)
#
# 유휴 비용은 사실상 0이다 — 전부 사용량 과금인데, 클러스터가 꺼져 있으면 사용량도 0이다.
# 그래서 이 계층은 일일 스케일다운 대상이 아니다. destroy하지 않는다.
#
# 계층 관계:
#   persistent/        ECR·서명 KMS·OIDC·시크릿      — destroy 안 함
#   account-baseline/  여기                          — destroy 안 함
#   terraform/         VPC·EKS·RDS·Redis·엔드포인트   — 일일 스케일다운 대상
#
# 참조 방향은 항상 terraform/ -> account-baseline/ 한 방향이다.
# 반대 방향(baseline이 VPC/EKS를 참조)은 만들지 않는다 — 그러면 일일 운영이
# 이 계층을 다시 건드리게 되고 분리한 의미가 없어진다.
# =============================================================================

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

data "aws_caller_identity" "current" {}
