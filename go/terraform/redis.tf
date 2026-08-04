# 여러 Pod가 세션을 공유하도록 Redis를 세션 스토어로 사용합니다.
# (ALB가 요청을 다른 Pod로 분산시켜도 로그인 상태가 유지되게 하기 위함)
#
# =============================================================================
# 2026-08-04 제로트러스트 전환 — SECURITY_AUDIT_REPORT #14 잔여과제 이행
#   aws_elasticache_cluster는 전송 암호화/AUTH를 API 레벨에서 지원하지 않아
#   aws_elasticache_replication_group(단일 노드, cluster mode disabled)으로 교체.
#   - transit_encryption: 세션 데이터(로그인 상태)가 VPC 안이라도 평문으로 안 다님
#   - auth_token: SG가 뚫린 뒤의 측면이동(lateral movement)을 가정 — 네트워크에
#     도달했다는 것만으로는 세션 저장소를 못 읽게 인증을 요구 (제로트러스트:
#     "네트워크 위치는 신뢰의 근거가 아니다")
#   * 교체 시 캐시가 재생성되어 기존 로그인 세션은 초기화됨(사용자 재로그인).
#     세션 스토어라 데이터 유실의 실질 피해는 재로그인이 전부.
# =============================================================================

module "redis_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-redis-sg"
  description = "Redis accessible only from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    redis_from_nodes = {
      from_port                    = 6379
      to_port                      = 6379
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.eks.node_security_group_id
      description                  = "Redis from EKS nodes only"
    }
  }
  # (2026-08-04 제로트러스트) egress 전면 제거 — 캐시는 아웃바운드를 시작할 일이 없고,
  # 응답 트래픽은 SG stateful 특성으로 자동 허용됨 (rds.tf의 rds_sg와 동일한 논리)
}

resource "aws_elasticache_subnet_group" "this" {
  name       = "gochuchamchi-redis-subnet-group"
  subnet_ids = module.vpc.database_subnets
}

# AUTH 토큰. ElastiCache 제약: 16~128자, '/', '"', '@', 공백 사용 불가 -> 영숫자만 생성.
# 트레이드오프: auth_token은 리소스 인자로만 설정 가능해서 Terraform(state) 경유가
# 불가피함 — SECURITY_AUDIT_REPORT #1이 정의한 ESO 트리거에 해당하는 값. state가
# S3 암호화+잠금 뒤에 있어 등급은 낮지만, ESO(External Secrets Operator) 도입 시
# 이 값부터 이관할 것. (DB 앱 비밀번호는 배스천 생성이라 state에 안 남음 — db-zero-trust.tf)
resource "random_password" "redis_auth" {
  length  = 32
  special = false
}

# 학습/포트폴리오 단계라 단일 노드(cache.t3.micro) 유지 — replication_group이라는
# 이름이지만 num_cache_clusters=1이면 복제본 없는 1노드라 비용은 기존과 동일.
# 운영 전환 시 num_cache_clusters=2 + automatic_failover_enabled=true로 Multi-AZ 페일오버.
resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "gochuchamchi-redis"
  description          = "gochuchamchi session store (TLS + AUTH)"

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  port                 = 6379
  parameter_group_name = "default.redis7"

  automatic_failover_enabled = false # 1노드에선 불가. 운영 전환 시 노드 2개와 세트로 true
  multi_az_enabled           = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [module.redis_sg.id]

  transit_encryption_enabled = true # 앱은 rediss(TLS)로 접속 — SPRING_DATA_REDIS_SSL_ENABLED (k8s-deploy.tf)
  at_rest_encryption_enabled = true # 저장 암호화는 성능 영향·추가 비용 없음 -> 켜지 않을 이유가 없음
  auth_token                 = random_password.redis_auth.result

  apply_immediately = true # 실습용: 변경 즉시 반영. 운영에선 유지보수 윈도우 적용 검토
}
