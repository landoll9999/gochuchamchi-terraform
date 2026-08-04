# =============================================================================
# Grafana admin 비밀번호
#   values에 adminPassword를 지정하지 않아 차트가 랜덤 생성한 값을 Secret에 넣는다.
#   Secret 이름은 fullnameOverride와 동일한 "grafana", 키는 "admin-password".
#   (ArgoCD의 argocd-initial-admin-secret과 달리 이 Secret은 차트가 계속 유지하므로
#    data source로 안전하게 조회할 수 있음)
# =============================================================================

data "kubernetes_secret_v1" "grafana_admin" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name
  }

  depends_on = [helm_release.grafana]
}
