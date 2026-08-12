terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    # Redis AUTH 토큰 생성용 (redis.tf) — 추가 후 terraform init 1회 필요
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

# ---------------------------------------------------------------------------
# 1. VPC
#    기존 gochuchamchi RDS/S3/Route53은 그대로 두고, EKS가 들어갈 새 VPC를
#    독립적으로 하나 더 판다고 가정한 구성입니다.
#    (기존 VPC를 재사용하고 싶다면 이 module 블록을 지우고
#     data "aws_vpc" / data "aws_subnets" 로 기존 자원을 참조하면 됩니다.)
# ---------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0" # (v8) 매일 init하는 구조라 버전 미고정 시 major 업그레이드가 무경고 유입

  name = "gochuchamchi-vpc"
  cidr = "172.30.0.0/16"
  azs  = var.azs

  enable_dns_support   = true
  enable_dns_hostnames = true

  # private subnet은 EKS 노드/파드 IP가 여기서 할당되므로 /24(251개)보다 넉넉한
  # /23(507개)으로 확장 -> 파드 수가 늘어나도 IP 고갈 없이 스케일 가능
  private_subnets = ["172.30.40.0/23", "172.30.60.0/23"]
  public_subnets  = ["172.30.10.0/24", "172.30.30.0/24"]

  database_subnets                   = ["172.30.12.0/24", "172.30.32.0/24"]
  create_database_subnet_group       = true
  create_database_subnet_route_table = true # RDS/Redis subnet을 private subnet과 라우팅 테이블 분리 -> NAT 라우트 없는 진짜 isolated subnet으로
  map_public_ip_on_launch            = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

# ---------------------------------------------------------------------------
# 2. EKS 클러스터 + 노드그룹
# ---------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = "1.35"

  # ==========================================
  # CloudWatch - EKS Control Plane Logs
  # cloudwatch-log-archive.tf가 이 Log Group을 Firehose로 구독해서 S3에 장기 보관함
  # (module.eks.cloudwatch_log_group_name 참조) -> false로 바꾸면 아카이브도 같이 깨짐.
  # 아래 두 값은 모듈 기본값과 동일해서 plan에 diff가 생기지 않음. 의존관계를 드러내려고
  # 일부러 명시해 둔 것이니 지우지 말 것.
  #
  # enabled_log_types는 일부러 지정하지 않음 -> 모듈 기본값(api/audit/authenticator) 사용.
  # controllerManager/scheduler를 추가하면 aws_eks_cluster가 변경되고, 그 여파로
  # data.aws_eks_addon_version이 apply 시점 조회로 밀려서 애드온 6개가 전부
  # "known after apply"로 뜸(실제 버전은 동일해서 no-op이지만 plan이 지저분해짐).
  # 두 로그 유형이 필요해지면 그 점을 감안하고 추가할 것.
  # ==========================================
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 90

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs # 목록 관리는 variables.tf 참고 (네트워크 바뀌면 여기 추가)

  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    initial = {
      instance_types = var.node_instance_types
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      # (v8 병합, main 브랜치 보안 작업) IMDSv2만 허용하고, Pod가 노드 IAM 역할
      # 자격 증명을 직접 가져가지 못하도록 metadata 응답의 hop limit을 1로 제한한다.
      # 워크로드의 AWS 권한은 Pod Identity 사용.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
        instance_metadata_tags      = "disabled"
      }

      # (2026-08-04 백로그 B2) key_name 제거 — 노드 접속은 SSM으로만
      # (iam_role_additional_policies의 AmazonSSMManagedInstanceCore).
      # 감사 #2에서 배스천 SSH를 제거한 것과 같은 원칙. launch template 변경이라
      # 적용 시 노드 롤링이 발생함 — 트래픽 적은 시간대에 apply할 것.
      vpc_security_group_ids = [module.add_node_sg.id]
      iam_role_additional_policies = {
        # 디버깅/운영 편의를 위해 Session Manager 접속 권한 부여
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # EKS managed node group에 붙인 태그는 AWS가 내부적으로 만드는 ASG에도 그대로
      # 전파됨 -> Cluster Autoscaler의 auto-discovery(--node-group-auto-discovery)가
      # 이 태그로 스케일 대상 ASG를 찾음
      tags = {
        "k8s.io/cluster-autoscaler/enabled"             = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      }
    }
  }

  addons = {
    coredns                = {}
    eks-pod-identity-agent = { before_compute = true }
    kube-proxy             = {}
    vpc-cni = {
      before_compute = true
      # t3.small의 ENI 기반 max-pods는 노드당 11개뿐이라 시스템 파드만으로도 소진됨.
      # prefix delegation으로 11 -> 110까지 늘림 (private subnet을 /23으로 넓혀둔 것과 결합).
      # enableNetworkPolicy: (2026-08-04 백로그 B5) NetworkPolicy 시행 엔진(eBPF) 활성화.
      #   켜기만 해서는 아무것도 차단 안 됨 — 실제 정책은 k8s-network-policies.tf.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
        env                 = { ENABLE_PREFIX_DELEGATION = "true" }
      })
    }
    aws-efs-csi-driver = {}
    # HPA가 CPU 사용률을 읽으려면 metrics.k8s.io API가 필요함. 없으면 HPA가
    # "cpu: <unknown>/70%" 상태로 멈춰서 스케일링이 아예 동작하지 않음
    # (2026-07-29 실제로 FailedGetResourceMetric 이벤트로 확인).
    metrics-server = {}
  }

  # (2026-08-04 제로트러스트) 배스천 K8s 권한: ClusterAdmin(cluster) -> gochuchamchi
  # 네임스페이스 Edit로 축소. 배스천이 클러스터에 하는 일은 앱 DB Secret 업서트
  # (db-zero-trust.tf)와 runbook §1.4의 cm/secret 조회뿐 — Secrets Manager를 ARN
  # 단위로 조인 것과 같은 논리로, 배스천이 침해돼도 다른 네임스페이스(kube-system/
  # argocd 등)의 Secret까지는 못 읽게 함. 타 네임스페이스 디버깅은 로컬 kubectl
  # 경로(runbook §1.1)를 쓸 것 — 로컬 IP가 허용 CIDR 밖이면 variables.tf의
  # endpoint_public_access_cidrs에 추가하는 것이 배스천 권한을 다시 넓히는 것보다 낫다.
  access_entries = {
    bastion = {
      principal_arn = aws_iam_role.bastion_role.arn
      type          = "STANDARD"
      policy_associations = {
        gochuchamchi_edit = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["gochuchamchi"]
          }
        }
      }
    }
  }

  additional_security_group_ids = [module.add_cluster_sg.id]
}

# ---------------------------------------------------------------------------
# 3. Bastion Host
#    userdata에서 kubectl 설치 + update-kubeconfig 까지 자동 실행
# ---------------------------------------------------------------------------
module "bastion_host" {
  source     = "terraform-aws-modules/ec2-instance/aws"
  version    = "~> 6.0" # (v8) 버전 핀
  depends_on = [module.eks]

  name = "gochuchamchi-bastion"
  ami  = var.bastion_ami

  instance_type = "t3.micro"
  monitoring    = true

  # (2026-08-12) 퍼블릭 서브넷 + 공인 IP → 프라이빗 서브넷으로 이전.
  #
  # 공인 IP 가 하던 일은 하나뿐이었다 — SSM 접속을 위한 아웃바운드 인터넷.
  # SG 인바운드가 0건이라 그 IP 로 붙을 수 있는 것은 애초에 없었고, EKS API
  # 허용 CIDR 에도 배스천 IP 는 들어 있지 않다. 즉 인바운드 표면이 아니라
  # 아웃바운드 경로 문제였고, 프라이빗 서브넷의 NAT 인스턴스 경로로 대체된다.
  #
  #   private-2a subnet → NAT 인스턴스 (0.0.0.0/0)
  #
  # 트레이드오프: 배스천 도달성이 NAT 에 묶인다. 다만 EKS 노드가 이미 같은 NAT 에
  # 의존하므로 NAT 장애 시점에는 클러스터가 이미 정상이 아니다 — 한계 손실이 작다.
  # 이 의존까지 끊으려면 enable_vpc_endpoints 로 SSM 3종(ssm/ssmmessages/ec2messages)
  # 을 켜면 되지만, 현재 코드는 7종 일괄이라 시간당 비용이 붙는다.
  associate_public_ip_address = false

  # IMDSv2 강제는 그대로 둔다 — SSRF 로 인스턴스 크리덴셜을 긁어가는 경로는
  # 서브넷 위치와 무관하게 성립하므로, 공인 IP 를 뗐다고 완화할 이유가 없다.
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  user_data_replace_on_change = true

  root_block_device = {
    size = 20
    type = "gp3"
  }

  vpc_security_group_ids = [module.bastion_host_sg.id]
  subnet_id              = module.vpc.private_subnets[0]

  iam_instance_profile = aws_iam_instance_profile.bastion_instance_profile.name

  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    cluster_name = var.cluster_name
    region       = var.region
  })
}

# ---------------------------------------------------------------------------
# 4. NAT 인스턴스 — AZ별 2대 (2026-08-03 full-HA에서 복원: 1대 SPOF → AZ별 이중화)
#
#    기존 1대 구성은 그 인스턴스가 죽으면 프라이빗 서브넷 "전체"가 아웃바운드
#    불능이었다. AZ마다 1대씩 두고, 각 AZ의 프라이빗 라우트 테이블을 "같은 AZ의
#    NAT"로 연결하면:
#      - NAT 1대 장애 → 해당 AZ만 영향 (장애 반경이 AZ 단위로 격리됨)
#      - AZ 자체 장애 → 어차피 그 AZ 노드도 같이 죽으므로 반대쪽 AZ는 무영향
#
#    한계: NAT Gateway와 달리 인스턴스 방식은 "AZ 간 자동 페일오버"는 없다 —
#    대신 비용이 1/5이고, VPC 엔드포인트(vpc-endpoints.tf)가 ECR/S3/Secrets/SSM
#    경로를 NAT와 무관하게 보장하므로 이중 안전망이 있다.
#    프로덕션 기준이면 NAT Gateway 2대가 정답.
#
#    라우팅 전제: vpc 모듈은 single_nat_gateway가 아니면 AZ별로 프라이빗 라우트
#    테이블을 1개씩 만든다(azs 순서 = private_route_table_ids 순서 = public_subnets
#    순서). 그래서 count.index로 같은 AZ끼리 1:1 매칭이 된다.
# ---------------------------------------------------------------------------
module "nat_instance" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 6.0" # (v8) 버전 핀
  count   = length(var.azs)

  name          = "gochuchamchi-nat-${count.index}"
  ami           = var.nat_ami
  instance_type = "t3.micro"
  # (2026-08-04 백로그 B2) key_name 제거 — NAT 접속은 SSM으로만 (nat_role에 SSM 정책 부착)

  subnet_id              = module.vpc.public_subnets[count.index] # AZ별 배치
  source_dest_check      = false
  create_security_group  = false
  vpc_security_group_ids = [module.nat_sg.id]

  # (v8 병합) 세션 토큰이 필요한 IMDSv2 요청만 허용한다.
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  user_data                   = templatefile("${path.module}/nat_install.tpl", {})
  user_data_replace_on_change = true

  iam_instance_profile = aws_iam_instance_profile.nat_instance_profile.name

  # 시스템 상태 검사 실패 시 자동 복구 (인스턴스 NAT의 최소한의 자가 치유)
  maintenance_options = {
    auto_recovery = "default"
  }

  tags = {
    Name = "gochuchamchi-nat-${count.index}"
  }
}

# 기존 단일 NAT(public_subnets[1]에 있었음)를 count 방식의 [1]번으로 인수 —
# 서브넷이 같아서 재생성 없이 상태 주소만 이동하고, [0]번(AZ-a)만 새로 뜬다.
moved {
  from = module.nat_instance
  to   = module.nat_instance[1]
}

# 각 AZ의 프라이빗 라우트 테이블 → 같은 AZ의 NAT 인스턴스 ENI
resource "aws_route" "private_subnet" {
  count                  = length(module.vpc.private_route_table_ids)
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat_instance[count.index].primary_network_interface_id
}

# ECR 이미지 레이어가 실제로 S3에서 전송되므로, Gateway Endpoint로 그 트래픽을
# NAT에서 우회시켜 t3.micro NAT의 부하/SPOF 영향을 줄인다 (무료).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = { Name = "gochuchamchi-s3-endpoint" }
}

# (2026-08-12) 공인 IP 제거로 프라이빗 IP 를 노출한다. public_ip 를 그대로 두면
# null 이 나와서 "값이 왜 안 나오나"를 디버깅하게 된다. 접속은 어차피 SSM 경유라
# 이 값으로 붙을 일은 없고, 세션 로그·flow log 대조용 식별자로 쓴다.
output "bastion_private_ip" {
  value       = module.bastion_host.private_ip
  description = "Bastion host private IP (SSM 경유 접속 — 이 IP 로 직접 붙지 않는다)"
}

output "bastion_id" {
  value       = module.bastion_host.id
  description = "Bastion host id"
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
