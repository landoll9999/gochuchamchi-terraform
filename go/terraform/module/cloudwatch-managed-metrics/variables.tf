variable "name_prefix" {
  description = "CloudWatch Alarm 이름 앞에 붙일 프로젝트 이름"
  type        = string
  default     = "gochuchamchi"
}

# ============================================================
# ALB
# ============================================================

variable "alb_arn_suffix" {
  description = "ALB ARN suffix. 예: app/web-alb/1234567890abcdef"
  type        = string
  default     = null
}

variable "alb_target_group_arn_suffixes" {
  description = "CloudWatch에서 감시할 Target Group ARN suffix 목록"
  type        = set(string)
  default     = []
}

# ============================================================
# RDS
# ============================================================

variable "rds_identifier" {
  description = "RDS DB Instance Identifier"
  type        = string
  default     = null
}

# ============================================================
# ElastiCache Redis
# ============================================================

variable "redis_cluster_id" {
  description = "ElastiCache Cluster ID"
  type        = string
  default     = null
}

variable "redis_cache_node_id" {
  description = "ElastiCache Cache Node ID"
  type        = string
  default     = "0001"
}

# ============================================================
# Alarm 통지 대상
# 나중에 SNS Topic ARN을 넣을 수 있습니다.
# ============================================================

variable "alarm_actions" {
  description = "Alarm 발생 시 실행할 SNS Topic ARN 목록"
  type        = list(string)
  default     = []
}

# ============================================================
# 임계값
# ============================================================

variable "rds_cpu_threshold" {
  description = "RDS CPU 경보 임계값(%)"
  type        = number
  default     = 80
}

variable "rds_free_storage_threshold_bytes" {
  description = "RDS 남은 저장 공간 경보 임계값(byte)"
  type        = number

  # 5 GiB
  default = 5368709120
}

variable "redis_memory_threshold" {
  description = "Redis 메모리 사용률 경보 임계값(%)"
  type        = number
  default     = 80
}

variable "alb_target_4xx_threshold" {
  description = "5분 동안 ALB Target 4xx 응답 알람 임계값"
  type        = number
  default     = 20
}
