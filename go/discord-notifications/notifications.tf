# =============================================================================
# ArgoCD Notifications -> Discord Webhook
#   - ../terraform 디렉토리(메인 인프라 state)와 완전히 분리된 별도 root module.
#     argo-helm/argo-cd 차트의 notifications 컨트롤러(기본 활성화 - ../terraform/argocd.tf의
#     helm_release.argocd에서 별도로 끄지 않았으므로 기본값 유지)는 argocd 네임스페이스의
#     표준 이름(ConfigMap: argocd-notifications-cm, Secret: argocd-notifications-secret)을
#     읽어서 동작하기 때문에, 어느 state에서 만들었는지는 상관없다.
#   - 전제조건: ../terraform apply로 EKS 클러스터 + ArgoCD가 이미 떠 있어야 한다
#     (providers.tf의 data.aws_eks_cluster 조회가 실패하면 plan 단계에서 바로 확인됨).
# =============================================================================

# 웹훅 URL 자체는 Secret에만 넣고, ConfigMap에서는 "$discord-webhook-url" 참조로만 사용
resource "kubernetes_secret_v1" "argocd_notifications_secret" {
  metadata {
    name      = "argocd-notifications-secret"
    namespace = "argocd"
  }

  data = {
    discord-webhook-url = var.discord_webhook_url
  }
}

resource "kubernetes_config_map_v1" "argocd_notifications_cm" {
  metadata {
    name      = "argocd-notifications-cm"
    namespace = "argocd"
  }

  data = {
    # notifications-engine에는 "discord"라는 네이티브 서비스 타입이 없음(실제 확인:
    # pkg/services에 discord.go가 없고, 컨트롤러 로그에도 "service type 'discord' is
    # not supported" 에러 발생) -> 범용 webhook 서비스로 Discord Webhook URL에 직접 POST
    "service.webhook.discord" = <<-EOT
      url: $discord-webhook-url
      headers:
      - name: Content-Type
        value: application/json
    EOT

    # 실제 확인해보니 trigger/template은 컨트롤러에 내장된 게 아니라 argocd-notifications-cm
    # 안에 명시적으로 있어야만 동작함 (기존엔 argo-cd 차트가 기본값으로 채워줬던 것 -> 이제
    # 이 CM을 우리가 전담하므로 argoproj/argo-cd의 notifications_catalog/install.yaml에서
    # 그대로 가져옴). template은 discord용 webhook body가 없어서(message 필드만 있음) 같은
    # 이름으로 오버라이드 — webhook 서비스는 기본 GET+메시지원문 요청을 보내는데 Discord
    # webhook은 POST+JSON만 허용하므로 method/body를 명시해야 함.
    "trigger.on-sync-succeeded" = <<-EOT
      - description: Application syncing has succeeded
        oncePer: app.status.operationState?.syncResult?.revision
        send:
        - app-sync-succeeded
        when: app.status.operationState != nil and app.status.operationState.phase in ['Succeeded']
    EOT

    "trigger.on-sync-failed" = <<-EOT
      - description: Application syncing has failed
        oncePer: app.status.operationState?.syncResult?.revision
        send:
        - app-sync-failed
        when: app.status.operationState != nil and app.status.operationState.phase in ['Error', 'Failed']
    EOT

    "trigger.on-health-degraded" = <<-EOT
      - description: Application has degraded
        oncePer: app.status.operationState?.syncResult?.revision
        send:
        - app-health-degraded
        when: app.status.health.status == 'Degraded'
    EOT

    "template.app-sync-succeeded" = <<-EOT
      webhook:
        discord:
          method: POST
          body: |
            {"content": "✅ **{{.app.metadata.name}}** sync succeeded at {{.app.status.operationState.finishedAt}}\n{{.context.argocdUrl}}/applications/{{.app.metadata.name}}"}
    EOT

    "template.app-sync-failed" = <<-EOT
      webhook:
        discord:
          method: POST
          body: |
            {"content": "❌ **{{.app.metadata.name}}** sync failed: {{.app.status.operationState.message}}\n{{.context.argocdUrl}}/applications/{{.app.metadata.name}}"}
    EOT

    "template.app-health-degraded" = <<-EOT
      webhook:
        discord:
          method: POST
          body: |
            {"content": "⚠️ **{{.app.metadata.name}}** health degraded\n{{.context.argocdUrl}}/applications/{{.app.metadata.name}}"}
    EOT

    "subscriptions" = <<-EOT
      - recipients:
        - discord
        triggers:
        - on-sync-succeeded
        - on-sync-failed
        - on-health-degraded
    EOT
  }
}
