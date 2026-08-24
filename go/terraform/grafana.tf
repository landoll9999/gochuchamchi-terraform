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

  # (2026-08-19) Log 계정 조회 역할.
  # 계정이 분리되어 있고 한 방향 참조 원칙(terraform/ -> 상시 계층)을 지켜야 하므로
  # remote state 참조가 아니라 변수로 넘긴다.
  athena_reader_role_arn = var.grafana_athena_reader_role_arn

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

# (2026-08-04 보안 리뷰 §3-② 조치) grafana_admin_password output 제거 —
# data source → output 경유로 비밀번호가 tfstate에 평문 저장되던 문제
# (sensitive=true는 CLI 출력만 가림). 필요 시 클러스터에서 직접 조회 (PowerShell —
# `base64`는 PowerShell에 없어서 bash 형태(`| base64 -d`)는 실패한다):
#   [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String((kubectl -n monitoring get secret grafana -o jsonpath='{.data.admin-password}')))

output "grafana_iam_role_arn" {
  description = "Grafana CloudWatch 조회용 IAM Role ARN"
  value       = module.grafana.iam_role_arn
}
