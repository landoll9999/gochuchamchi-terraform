variable "cluster_name" {
  description = "Grafana를 설치할 EKS 클러스터 이름"
  type        = string
}

variable "region" {
  description = "CloudWatch 데이터를 조회할 AWS 리전"
  type        = string
}

variable "namespace" {
  description = "Grafana를 설치할 Kubernetes Namespace"
  type        = string
  default     = "monitoring"
}

variable "service_account_name" {
  description = "Grafana가 사용할 Kubernetes ServiceAccount 이름"
  type        = string
  default     = "grafana"
}

variable "grafana_hostname" {
  description = "Grafana 접속 도메인"
  type        = string
}

variable "storage_class_name" {
  description = "Grafana PVC에서 사용할 StorageClass"
  type        = string
  default     = "ebs-sc"
}

variable "storage_size" {
  description = "Grafana 데이터 저장용 EBS 크기"
  type        = string
  default     = "5Gi"
}

variable "alb_group_name" {
  description = "기존 애플리케이션 ALB와 공유하기 위한 Ingress Group 이름"
  type        = string
  default     = "gochuchamchi-web"
}

variable "certificate_arn" {
  description = "Grafana HTTPS에 사용할 ACM 인증서 ARN"
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Grafana 관련 AWS 리소스 공통 태그"
  type        = map(string)
  default     = {}
}
variable "rds_identifier" {
  description = "CloudWatch Logs에서 조회할 RDS DB 인스턴스 식별자"
  type        = string
}

variable "athena_reader_role_arn" {
  description = <<-EOT
    Log 계정의 Grafana 조회 전용 역할 ARN.
    log-archive 스택의 output grafana_reader_role_arn 값을 넣는다.
    비워 두면 Athena 데이터소스가 등록되지 않고 CloudWatch만 동작한다 —
    log-archive apply 전에도 이 모듈이 깨지지 않게 하기 위한 기본값이다.
  EOT
  type        = string
  default     = ""
}