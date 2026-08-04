output "alb_alarm_names" {
  description = "생성된 ALB Alarm 이름"

  value = concat(
    [
      for alarm in values(
        aws_cloudwatch_metric_alarm.alb_unhealthy_host
      ) : alarm.alarm_name
    ],
    [
      for alarm in values(
        aws_cloudwatch_metric_alarm.alb_target_5xx
      ) : alarm.alarm_name
    ]
  )
}

output "rds_alarm_names" {
  description = "생성된 RDS Alarm 이름"
  value = concat(
    aws_cloudwatch_metric_alarm.rds_cpu_high[*].alarm_name,
    aws_cloudwatch_metric_alarm.rds_free_storage_low[*].alarm_name
  )
}

output "redis_alarm_names" {
  description = "생성된 Redis Alarm 이름"
  value = concat(
    aws_cloudwatch_metric_alarm.redis_memory_high[*].alarm_name,
    aws_cloudwatch_metric_alarm.redis_evictions[*].alarm_name
  )
}