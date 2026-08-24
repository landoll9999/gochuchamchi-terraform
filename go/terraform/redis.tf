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
#
# 2026-08-19 로그 전달 추가 — "Redis에 남는 흔적이 0"이던 문제
#   ElastiCache Redis는 접속·명령 감사 로그를 제공하지 않는다. 상용 SIEM을
#   붙여도 없는 로그는 못 본다. 그래서 관측 가능한 세 축을 모두 켠다.
#
#     1) engine-log  페일오버·재시작·설정 변경 등 엔진 이벤트
#     2) slow-log    임계 초과 명령. 대량 조회(KEYS *, 세션 덤프 시도)의 흔적이
#                    여기 남는다 — 감사 로그가 없는 환경에서 이상 사용을 잡는
#                    사실상 유일한 로그 축이다
#     3) AuthenticationFailures 메트릭 (아래 알람)
#                    auth_token이 실제로 방어하고 있음을 증명하는 지표.
#                    SG를 통과한 뒤 인증에서 막힌 시도가 여기 잡힌다.
#
#   "누가 접속했는가"를 최종 사용자 단위로 보려면 이 로그가 아니라 앱의 세션
#   이벤트를 봐야 한다(Redis는 세션 스토어이므로). 계층별 역할이 다르다.
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

resource "random_password" "admin_redis_auth" {
  length  = 32
  special = false
}


# =============================================================================
# Redis 로그 그룹 (2026-08-19)
#
# 로그 그룹을 Terraform이 먼저 만드는 이유: ElastiCache가 자동 생성하게 두면
# 보존 기간이 "만료 없음"으로 잡혀 계속 쌓인다. 매일 destroy되는 계층이라
# 실제 비용은 작지만, 보존 정책이 명시되지 않은 로그 그룹이 남는 것 자체가
# 감사에서 지적 대상이다.
#
# 중앙 아카이브로 보내려면 log-archive-subscriptions.tf에 이 두 그룹을 추가하면
# 된다. 지금은 CloudWatch Logs에만 두고 실시간 조회(Grafana)에 쓴다 —
# S3를 경유하지 않으므로 지연이 초 단위다.
# =============================================================================

resource "aws_cloudwatch_log_group" "redis_slow" {
  name              = "/aws/elasticache/gochuchamchi-redis/slow-log"
  retention_in_days = var.redis_log_retention_days

  tags = {
    Project   = "gochuchamchi"
    Component = "redis"
    LogType   = "slow-log"
  }
}

resource "aws_cloudwatch_log_group" "redis_engine" {
  name              = "/aws/elasticache/gochuchamchi-redis/engine-log"
  retention_in_days = var.redis_log_retention_days

  tags = {
    Project   = "gochuchamchi"
    Component = "redis"
    LogType   = "engine-log"
  }
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

  # ---------------------------------------------------------------------------
  # (2026-08-19) 로그 전달 — JSON 형식으로 보낸다.
  #
  # log_format을 text가 아니라 json으로 두는 것이 중요하다. CloudWatch Logs
  # Insights가 필드를 자동 인식해서 `stats count() by CacheNodeId` 같은 집계가
  # 파싱 없이 바로 되고, Grafana 패널에서도 그대로 쓸 수 있다. text로 두면
  # 패널마다 parse 구문을 붙여야 하고 포맷이 바뀌면 조용히 깨진다.
  #
  # 블록은 최대 2개다(slow-log / engine-log). 순서는 무관.
  # ---------------------------------------------------------------------------
  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_slow.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "slow-log"
  }

  log_delivery_configuration {
    destination      = aws_cloudwatch_log_group.redis_engine.name
    destination_type = "cloudwatch-logs"
    log_format       = "json"
    log_type         = "engine-log"
  }

  apply_immediately = true # 실습용: 변경 즉시 반영. 운영에선 유지보수 윈도우 적용 검토

  depends_on = [
    aws_cloudwatch_log_group.redis_slow,
    aws_cloudwatch_log_group.redis_engine
  ]
}

# 관리자 인증 세션은 Web 세션 저장소와 자격증명을 공유하지 않는다. Web Pod에서
# 탈취한 Redis 토큰으로 ADMINSESSION을 읽거나 생성할 수 없도록 별도 단일 노드를 둔다.
# 학습 환경 기준으로 cache.t3.micro 1대 비용이 추가된다.
resource "aws_elasticache_replication_group" "admin" {
  replication_group_id = "gochuchamchi-admin-redis"
  description          = "gochuchamchi admin session store (isolated TLS + AUTH)"

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  port                 = 6379
  parameter_group_name = "default.redis7"

  automatic_failover_enabled = false
  multi_az_enabled           = false
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [module.redis_sg.id]
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true
  auth_token                 = random_password.admin_redis_auth.result
  apply_immediately          = true
}


# =============================================================================
# Redis 보안 알람 (2026-08-19)
#
# AuthenticationFailures가 핵심이다. SG는 EKS 노드만 허용하므로, 여기에 값이
# 찍힌다는 것은 "이미 노드 안에 있는 무언가가 잘못된 토큰으로 붙으려 했다"는
# 뜻이다 — 즉 측면이동 시도의 직접 증거다. auth_token을 건 이유가 이 시나리오이고,
# 이 지표가 그 방어가 실제로 작동하고 있음을 보여준다.
#
# 임계값 1: 정상 동작에서는 0이어야 하는 지표다. 앱이 토큰을 제대로 들고 있으면
# 단 한 번도 오르지 않는다. 그래서 "몇 번 이상"이 아니라 "한 번이라도"가 맞다.
# 오탐이 잦으면 임계값을 올릴 게 아니라 앱의 토큰 주입 경로를 먼저 봐야 한다.
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "redis_auth_failures" {
  alarm_name        = "gochuchamchi-redis-auth-failures"
  alarm_description = "Redis AUTH 실패 발생 — 잘못된 토큰으로 세션 저장소 접근 시도"

  namespace   = "AWS/ElastiCache"
  metric_name = "AuthenticationFailures"
  statistic   = "Sum"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.this.replication_group_id
  }

  period              = 60
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # 지표가 없는 것은 "실패가 없다"는 뜻이므로 정상으로 본다.
  # (siem-detector의 DetectionRunSuccess와는 반대 — 그쪽은 결측이 곧 고장이다)
  treat_missing_data = "notBreaching"

  tags = {
    Project   = "gochuchamchi"
    Component = "redis"
  }
}


# 커넥션 급증 — 세션 스토어에 비정상적으로 많은 연결이 붙는 경우.
# 파드 수 × 커넥션 풀 크기가 상한이므로, 그것을 넘으면 예상 밖의 클라이언트가 있다.
resource "aws_cloudwatch_metric_alarm" "redis_connection_spike" {
  alarm_name        = "gochuchamchi-redis-connection-spike"
  alarm_description = "Redis 동시 연결 수 급증 — 예상 밖 클라이언트 접속 가능성"

  namespace   = "AWS/ElastiCache"
  metric_name = "CurrConnections"
  statistic   = "Maximum"

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.this.replication_group_id
  }

  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = var.redis_connection_alarm_threshold
  comparison_operator = "GreaterThanThreshold"

  treat_missing_data = "notBreaching"

  tags = {
    Project   = "gochuchamchi"
    Component = "redis"
  }
}
