# 기존 ArgoCD Discord Webhook이 저장된 Secret 조회
# 실제 웹훅 URL은 Terraform에서 읽지 않고 ARN만 사용합니다.

data "aws_secretsmanager_secret" "discord_webhook" {
  name = "gochuchamchi/discord/cloudwatch-webhook"
}