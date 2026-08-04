# ============================================================
# Kubernetes Ingress가 생성한 ALB / Target Group 자동 조회
# ============================================================

# Web과 Grafana Ingress는 명시적 IngressGroup을 사용하므로
# ingress.k8s.aws/stack 태그 값은 group.name과 동일
locals {
  gochuchamchi_ingress_stack = "gochuchamchi-web"
}

# ============================================================
# Ingress가 생성한 ALB 조회
# ============================================================

# ALB는 Ingress apply 이후 aws-load-balancer-controller가 비동기로 만들기 때문에,
# 최초 apply의 plan 시점에는 아직 존재하지 않는다.
# data "aws_lb"는 결과가 0개면 에러를 내므로 대신 태그 API로 조회한다.
# (태그 API는 결과가 없으면 빈 리스트를 돌려주고 에러를 내지 않음)
# -> ALB가 없는 첫 apply에서는 ALB 알람만 건너뛰고, 다음 apply에서 자동으로 붙는다.
data "aws_resourcegroupstaggingapi_resources" "gochuchamchi_alb" {
  resource_type_filters = [
    "elasticloadbalancing:loadbalancer"
  ]

  tag_filter {
    key    = "elbv2.k8s.aws/cluster"
    values = [module.eks.cluster_name]
  }

  tag_filter {
    key    = "ingress.k8s.aws/stack"
    values = [local.gochuchamchi_ingress_stack]
  }
}

locals {
  # 태그 API는 NLB/GWLB도 같이 돌려줄 수 있으므로 ALB(app/)만 남긴다
  gochuchamchi_alb_arns = [
    for item in data.aws_resourcegroupstaggingapi_resources.gochuchamchi_alb.resource_tag_mapping_list :
    item.resource_arn
    if length(regexall("loadbalancer/app/", item.resource_arn)) > 0
  ]

  gochuchamchi_alb_arn = try(local.gochuchamchi_alb_arns[0], null)

  # arn:aws:elasticloadbalancing:<region>:<account>:loadbalancer/app/<name>/<id>
  # -> CloudWatch LoadBalancer 디멘션 값인 app/<name>/<id>
  gochuchamchi_alb_arn_suffix = (
    local.gochuchamchi_alb_arn == null
    ? null
    : regex("loadbalancer/(app/.+)$", local.gochuchamchi_alb_arn)[0]
  )
}


# ============================================================
# 같은 Ingress 태그의 Target Group 후보 조회
# ============================================================

data "aws_resourcegroupstaggingapi_resources" "gochuchamchi_target_groups" {
  resource_type_filters = [
    "elasticloadbalancing:targetgroup"
  ]

  tag_filter {
    key    = "elbv2.k8s.aws/cluster"
    values = [module.eks.cluster_name]
  }

  tag_filter {
    key    = "ingress.k8s.aws/stack"
    values = [local.gochuchamchi_ingress_stack]
  }

}


# ============================================================
# Target Group 후보 상세 조회
# ============================================================

data "aws_lb_target_group" "gochuchamchi_candidates" {
  for_each = toset([
    for item in data.aws_resourcegroupstaggingapi_resources.gochuchamchi_target_groups.resource_tag_mapping_list :
    item.resource_arn
  ])

  arn = each.value
}


# ============================================================
# 현재 ALB에 실제 연결된 Target Group만 선택
# ============================================================

locals {
  gochuchamchi_target_group_arn_suffixes = (
    local.gochuchamchi_alb_arn == null
    ? toset([])
    : toset([
      for target_group in values(data.aws_lb_target_group.gochuchamchi_candidates) :
      regex("targetgroup/.+$", target_group.arn)

      if contains(
        target_group.load_balancer_arns,
        local.gochuchamchi_alb_arn
      )
    ])
  )
}

# ============================================================
# ALB / RDS / Redis CloudWatch Alarm 모듈
# ============================================================

module "cloudwatch_managed_metrics" {
  source = "./module/cloudwatch-managed-metrics"

  name_prefix = "gochuchamchi"

  # ----------------------------------------------------------
  # RDS
  # ----------------------------------------------------------
  rds_identifier = module.rds.db_instance_identifier

  # ----------------------------------------------------------
  # ElastiCache Redis
  # ----------------------------------------------------------
  # (2026-08-04) replication_group 전환(redis.tf)에 맞춰 참조 변경.
  # RG의 멤버 캐시 클러스터는 "<rg-id>-001" 이름으로 생성되므로 그 ID로 알람 디멘션을 잡음
  redis_cluster_id    = "${aws_elasticache_replication_group.this.id}-001"
  redis_cache_node_id = "0001"

  # ALB와 모든 Target Group 자동 연결
  # ALB가 아직 없으면 null -> 모듈이 ALB 알람을 만들지 않음
  alb_arn_suffix = local.gochuchamchi_alb_arn_suffix

  alb_target_group_arn_suffixes = (
    local.gochuchamchi_target_group_arn_suffixes
  )
  # 아직 SNS/Discord 통지 연결 안 함
  alarm_actions = []
}
