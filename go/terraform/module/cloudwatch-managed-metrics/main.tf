locals {
  # Target Group ARN suffix를 key,
  # Target Group 이름을 value로 사용하는 Map 생성
  alb_target_groups = var.alb_arn_suffix == null ? {} : {
    for suffix in var.alb_target_group_arn_suffixes :
    suffix => split("/", suffix)[1]
  }

  enable_rds   = var.rds_identifier != null
  enable_redis = var.redis_cluster_id != null
}
# ============================================================
# ALB CloudWatch Alarm
# ============================================================

# 비정상 Target이 1개 이상인지 확인
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_host" {
  for_each = local.alb_target_groups

  alarm_name        = "${var.name_prefix}-alb-${each.value}-unhealthy-host"
  alarm_description = "ALB Target Group에 비정상 Target이 존재합니다."

  namespace   = "AWS/ApplicationELB"
  metric_name = "UnHealthyHostCount"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.key
  }

  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1

  # 메트릭이 없을 때는 장애로 판단하지 않음
  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
}

# Spring Target이 반환한 5xx 오류 확인
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  for_each = local.alb_target_groups

  alarm_name        = "${var.name_prefix}-alb-${each.value}-target-5xx"
  alarm_description = "ALB Target Group ${each.value}에서 5xx 오류가 발생했습니다."
  namespace         = "AWS/ApplicationELB"
  metric_name       = "HTTPCode_Target_5XX_Count"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = each.key
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 5

  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
}

# ============================================================
# RDS CloudWatch Alarm
# ============================================================

# RDS CPU 사용률 확인
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  count = local.enable_rds ? 1 : 0

  alarm_name        = "${var.name_prefix}-rds-cpu-high"
  alarm_description = "RDS CPU 사용률이 임계값 이상입니다."

  namespace   = "AWS/RDS"
  metric_name = "CPUUtilization"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.rds_cpu_threshold

  treat_missing_data = "missing"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
}

# RDS 남은 저장 공간 확인
resource "aws_cloudwatch_metric_alarm" "rds_free_storage_low" {
  count = local.enable_rds ? 1 : 0

  alarm_name        = "${var.name_prefix}-rds-free-storage-low"
  alarm_description = "RDS의 남은 저장 공간이 부족합니다."

  namespace   = "AWS/RDS"
  metric_name = "FreeStorageSpace"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2

  comparison_operator = "LessThanOrEqualToThreshold"
  threshold           = var.rds_free_storage_threshold_bytes

  treat_missing_data = "missing"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
}

# ============================================================
# ElastiCache Redis CloudWatch Alarm
# ============================================================

# Redis 메모리 사용률 확인
resource "aws_cloudwatch_metric_alarm" "redis_memory_high" {
  count = local.enable_redis ? 1 : 0

  alarm_name        = "${var.name_prefix}-redis-memory-high"
  alarm_description = "Redis 메모리 사용률이 임계값 이상입니다."

  namespace   = "AWS/ElastiCache"
  metric_name = "DatabaseMemoryUsagePercentage"

  dimensions = {
    CacheClusterId = var.redis_cluster_id
    CacheNodeId    = var.redis_cache_node_id
  }

  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = var.redis_memory_threshold

  treat_missing_data = "missing"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
}

# Redis 메모리 부족으로 데이터가 제거되는지 확인
resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  count = local.enable_redis ? 1 : 0

  alarm_name        = "${var.name_prefix}-redis-evictions"
  alarm_description = "Redis 메모리 부족으로 캐시 데이터가 제거되고 있습니다."

  namespace   = "AWS/ElastiCache"
  metric_name = "Evictions"

  dimensions = {
    CacheClusterId = var.redis_cluster_id
    CacheNodeId    = var.redis_cache_node_id
  }

  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1

  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  treat_missing_data = "notBreaching"

  alarm_actions = var.alarm_actions
  ok_actions    = var.alarm_actions
}