output "namespace" {
  description = "Grafana가 설치된 Kubernetes Namespace"
  value       = kubernetes_namespace_v1.monitoring.metadata[0].name
}

output "service_account_name" {
  description = "Grafana가 사용하는 Kubernetes ServiceAccount"
  value       = kubernetes_service_account_v1.grafana.metadata[0].name
}

output "iam_role_arn" {
  description = "Grafana CloudWatch 조회용 Pod Identity IAM Role ARN"
  value       = aws_iam_role.grafana.arn
}

output "hostname" {
  description = "Grafana 접속 도메인"
  value       = var.grafana_hostname
}

output "url" {
  description = "Grafana 접속 URL"
  value       = local.grafana_root_url
}

output "helm_release_name" {
  description = "Grafana Helm Release 이름"
  value       = helm_release.grafana.name
}

output "admin_password" {
  description = "Grafana admin 비밀번호 (차트가 랜덤 생성)"
  value       = data.kubernetes_secret_v1.grafana_admin.data["admin-password"]
  sensitive   = true
}