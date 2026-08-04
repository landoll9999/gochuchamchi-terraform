# =============================================================================
# L2 네트워크 — database 서브넷 커스텀 NACL (격차분석 §2.3)
#
# SG(rds_sg/redis_sg)가 이미 워크로드 정체성 기반으로 좁혀져 있지만, NACL은
# 그와 독립적인 "서브넷 경계" 방어선이다. SG 오설정/침해가 나도 DB 서브넷은
#   - 인터넷으로 나가는 경로가 아예 없고 (exfiltration 차단)
#   - VPC 내부에서도 DB 포트 외에는 못 들어온다
# 는 것을 스테이트리스 레이어에서 한 번 더 보장한다.
#
# public/private 서브넷은 기본 NACL(전체 허용)을 유지한다 — EKS 파드 레이어는
# NetworkPolicy(network-policies.tf)가 담당하고, NACL로 노드 트래픽까지 조이면
# prefix delegation·헬스체크 등에서 진단이 어려운 장애가 나기 쉽다.
#
# NACL은 스테이트리스라 "응답" 패킷도 규칙이 필요하다:
#   - 인바운드 ephemeral(1024-65535): DB가 내보낸 요청(DNS 등)의 응답 수신
#   - 아웃바운드 ephemeral: 클라이언트(파드/배스천)로 돌아가는 DB 응답
# 모든 규칙의 CIDR은 VPC 내부로 고정 — 인터넷 방향은 규칙이 없어 전부 차단된다.
# =============================================================================

locals {
  database_nacl_rules = {
    ingress = [
      { rule_no = 100, protocol = "tcp", from = 3306, to = 3306 },  # RDS MariaDB
      { rule_no = 110, protocol = "tcp", from = 6379, to = 6379 },  # ElastiCache Redis
      { rule_no = 120, protocol = "tcp", from = 1024, to = 65535 }, # DB발 요청의 응답
      { rule_no = 130, protocol = "udp", from = 1024, to = 65535 }, # DNS 응답
    ]
    egress = [
      { rule_no = 100, protocol = "tcp", from = 1024, to = 65535 }, # 클라이언트로의 응답
      { rule_no = 110, protocol = "udp", from = 53, to = 53 },      # VPC 리졸버 DNS 질의
      { rule_no = 120, protocol = "tcp", from = 53, to = 53 },
    ]
  }
}

resource "aws_network_acl" "database" {
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.database_subnets

  dynamic "ingress" {
    for_each = local.database_nacl_rules.ingress

    content {
      rule_no    = ingress.value.rule_no
      protocol   = ingress.value.protocol
      action     = "allow"
      cidr_block = module.vpc.vpc_cidr_block
      from_port  = ingress.value.from
      to_port    = ingress.value.to
    }
  }

  dynamic "egress" {
    for_each = local.database_nacl_rules.egress

    content {
      rule_no    = egress.value.rule_no
      protocol   = egress.value.protocol
      action     = "allow"
      cidr_block = module.vpc.vpc_cidr_block
      from_port  = egress.value.from
      to_port    = egress.value.to
    }
  }

  tags = {
    Name      = "gochuchamchi-database-nacl"
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
  }
}
