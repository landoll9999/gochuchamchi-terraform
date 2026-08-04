# =============================================================================
# VPC 인터페이스 엔드포인트 풀 세트 (2026-08-03)
#
#   S3 Gateway 엔드포인트(main.tf, 무료)만 있던 상태에서 인터페이스형 7종을 추가.
#   프라이빗 서브넷의 노드/파드가 ECR·SSM·Secrets Manager·CloudWatch Logs를
#   NAT를 거치지 않고 VPC 내부 ENI로 직접 호출하게 된다.
#
#   왜 넣는가 (트레이드오프):
#     - 보안: AWS API 트래픽이 인터넷 구간을 아예 타지 않음 + 엔드포인트 정책으로
#       "이 VPC에서 접근 가능한 AWS 리소스"를 추가로 좁힐 수 있는 지점이 생김
#     - 가용성: NAT가 전부 죽어도 이미지 pull(ECR/S3)·비밀 조회(SecretsManager)·
#       SSM 접속은 계속 동작 — NAT GW 이중화와 별개의 독립 경로
#     - 비용: 인터페이스형 1개 = AZ당 시간당 $0.0125. 2AZ × 7종 ≈ 월 $126...가
#       아니라, 여기서는 **비용 절충으로 AZ 1곳에만** 배치하면 월 $63이지만
#       그러면 그 AZ 장애 시 엔드포인트도 같이 죽는다. 풀 이중화 취지에 맞춰
#       2AZ 전부에 배치한다 (subnet_ids = 프라이빗 서브넷 전체). 대신 NAT 처리
#       비용(GB당 $0.059)이 그만큼 줄어 실효 증가분은 더 작다.
#       ⚠️ 시연 없는 기간에는 이 파일만 통째로 주석 처리(또는 삭제 후 apply)하면
#       바로 비용이 멈춘다 — 다른 리소스와 의존관계 없음.
#
#   면접 포인트: "ECR pull이 NAT 경유였을 때는 이미지 레이어가 인터넷 구간을
#   타고 NAT 비용도 발생했다. Gateway(S3)+Interface(ECR api/dkr) 조합으로
#   pull 경로를 VPC 안으로 완전히 넣었고, private_dns_enabled로 앱 코드 수정
#   없이(같은 도메인 이름 그대로) 전환했다"
# =============================================================================

locals {
  # ECR pull 경로: ecr.api(인증/매니페스트) + ecr.dkr(레이어 다운로드 시작)
  #   → 실제 레이어 바이트는 S3에서 오므로 main.tf의 S3 Gateway가 마무리
  # SSM 3종: Session Manager(배스천/노드 접속) = ssm + ssmmessages + ec2messages
  # secretsmanager: 앱 파드의 DB 비밀번호 조회(eks-pod-identity.tf 앱 정책)
  # logs: Fluent Bit/Container Insights(cloudwatch-observability.tf)의 로그 전송
  vpc_interface_endpoints = [
    "ecr.api",
    "ecr.dkr",
    "ssm",
    "ssmmessages",
    "ec2messages",
    "secretsmanager",
    "logs",
  ]
}

# 엔드포인트 ENI용 SG — VPC 내부에서 오는 443만 허용 (엔드포인트는 인바운드 전용)
module "vpc_endpoints_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-vpce-sg"
  description = "Interface VPC endpoints - HTTPS from inside VPC only"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    https_from_vpc = {
      from_port   = 443
      to_port     = 443
      ip_protocol = "tcp"
      cidr_ipv4   = module.vpc.vpc_cidr_block
      description = "Allow HTTPS from inside VPC (nodes/pods/bastion)"
    }
  }
  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.vpc_interface_endpoints)

  vpc_id             = module.vpc.vpc_id
  service_name       = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type  = "Interface"
  subnet_ids         = module.vpc.private_subnets # 2AZ 전부 = AZ 장애 내성
  security_group_ids = [module.vpc_endpoints_sg.id]

  # 핵심: 켜면 ecr.ap-northeast-2.amazonaws.com 같은 기존 퍼블릭 DNS 이름이
  # VPC 안에서는 엔드포인트 ENI의 프라이빗 IP로 풀린다 → 노드/파드/애드온의
  # 설정 변경이 전혀 필요 없음 (kubelet, aws-cli, SDK 전부 그대로 동작).
  private_dns_enabled = true

  tags = { Name = "gochuchamchi-vpce-${each.value}" }
}

output "vpc_endpoint_ids" {
  description = "생성된 인터페이스 엔드포인트 ID 목록 (검증: aws ec2 describe-vpc-endpoints)"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}
