# =============================================================================
# Grafana
# =============================================================================

module "grafana" {
  source = "./module/grafana"

  cluster_name = module.eks.cluster_name
  region       = var.region

  namespace            = "monitoring"
  service_account_name = "grafana"

  grafana_hostname = "grafana.${var.domain_name}"

  storage_class_name = "ebs-sc"
  storage_size       = "5Gi"

  rds_identifier = module.rds.db_instance_identifier

  # 기존 웹 Ingress와 같은 ALB 사용
  alb_group_name = "gochuchamchi-web"

  # DNS 검증까지 완료된 ACM 인증서
  certificate_arn = aws_acm_certificate_validation.this.certificate_arn

  tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
  }

  depends_on = [
    module.eks,
    aws_eks_addon.cloudwatch_observability,
    aws_acm_certificate_validation.this,
    helm_release.aws_load_balancer_controller,
    helm_release.external_dns
  ]
}


# =============================================================================
# Grafana Outputs
# =============================================================================

output "grafana_url" {
  description = "Grafana 접속 URL. 계정: admin"
  value       = module.grafana.url
}

# 조회: terraform output -raw grafana_admin_password
output "grafana_admin_password" {
  description = "Grafana admin 비밀번호 (차트가 랜덤 생성)"
  value       = module.grafana.admin_password
  sensitive   = true
}

output "grafana_iam_role_arn" {
  description = "Grafana CloudWatch 조회용 IAM Role ARN"
  value       = module.grafana.iam_role_arn
}
