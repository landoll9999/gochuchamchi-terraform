terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# ../terraform state를 전혀 참조하지 않고, 클러스터 이름만으로 접속 정보를 독립적으로
# 구성한다 (state 완전 분리 -> 이 디렉토리의 apply/destroy가 메인 인프라에 영향 없음).
# 이 데이터소스 조회 자체가 ../terraform apply로 클러스터가 이미 떠 있어야 성공한다.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
