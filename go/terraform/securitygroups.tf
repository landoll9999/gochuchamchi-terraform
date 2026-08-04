module "add_cluster_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-add-cluster-sg"
  description = "Bastion to EKS Control Plane communication"
  vpc_id      = module.vpc.vpc_id

  # (2026-08-04 백로그 B1) 소스를 VPC CIDR 전체 -> 배스천 SG 참조로 축소.
  # 이 SG의 존재 이유는 이름 그대로 "배스천 -> 컨트롤플레인"뿐이다. 노드/파드의
  # API 통신은 EKS 모듈이 자체 생성하는 cluster SG 규칙(노드 SG 참조)이 담당하므로
  # VPC 전체를 열어둘 이유가 없다 — rds_sg를 SG 참조로 조인 것과 같은 논리.
  ingress_rules = {
    https_from_bastion = {
      from_port                    = 443
      to_port                      = 443
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.bastion_host_sg.id
      description                  = "EKS API from bastion only"
    }
  }
  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}

module "add_node_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-add-node-sg"
  description = "Additional security group for EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  # (2026-08-04 백로그 B1) "VPC 전체에서 모든 프로토콜·포트 허용" 인그레스를 제거.
  # 필요한 노드 통신은 전부 EKS 모듈의 자체 노드 SG가 이미 커버한다:
  #   - 노드<->노드, 컨트롤플레인->kubelet(10250)/webhook: 모듈 기본 규칙
  #   - ALB->파드(8080): aws-load-balancer-controller가 클러스터 태그가 붙은
  #     모듈 노드 SG에 타겟그룹용 규칙을 동적으로 추가/삭제함
  # 이 SG가 열려 있으면 NAT/배스천 등 VPC 내 아무 자원이 침해됐을 때 kubelet·
  # NodePort로 측면이동이 가능했다 (제로트러스트: 네트워크 위치는 신뢰 근거가 아님).
  # SG 자체는 유지 — eks-pod-identity.tf의 destroy 순서 고정(depends_on)이 이 모듈을
  # 참조하고 있고, 나중에 노드에 정말 필요한 규칙이 생기면 여기에 "정확한 소스 SG
  # 참조"로만 추가할 것.
  ingress_rules = {}
  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}

module "bastion_host_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-bastion-sg"
  description = "Bastion host security group (SSM only, no inbound)"
  vpc_id      = module.vpc.vpc_id

  # 인바운드 0개 — SSM Session Manager는 아웃바운드 443만 있으면 접속 가능하므로
  # SSH 인바운드 자체가 필요 없음. 접속: aws ssm start-session --target <bastion-instance-id>
  ingress_rules = {}

  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}

module "nat_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-nat-sg"
  description = "NAT instance security group"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    vpc_all = {
      ip_protocol = "-1"
      cidr_ipv4   = module.vpc.vpc_cidr_block
      description = "Allow all traffic from inside VPC only"
    }
  }
  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}
