# =============================================================================
# ArgoCD가 private GitOps 저장소에 붙을 때 쓰는 GitHub PAT 컨테이너
#
# 왜 영속 state인가 (2026-08-06)
#   이 시크릿은 recovery_window_in_days = 0이라 destroy 때 값까지 즉시 사라진다.
#   재구축하면 빈 컨테이너만 생기고, 값을 다시 넣기 전까지
#   ESO -> ArgoCD -> 앱 배포가 통째로 멈춰 사이트가 503이 된다.
#   2026-08-05와 2026-08-06 재구축에서 연속으로 이 상태였다.
#
#   값(PAT)은 AWS 리소스 안에만 있고 Terraform state에는 들어가지 않으므로
#   (아래 주석 참고), 컨테이너를 영속화하면 PAT도 재구축을 건너 살아남는다.
#   ../terraform/eso.tf의 자동 주입 로직은 "값이 이미 있으면 건드리지 않는다"라
#   그대로 두어도 충돌하지 않는다.
#
# 값 주입/로테이션 (사람이 1회):
#   aws secretsmanager put-secret-value --secret-id gochuchamchi/argocd/git-pat `
#     --secret-string "<GitHub PAT>" --region ap-northeast-2 --profile admin
#
# Terraform은 값을 절대 읽지 않는다 — aws_secretsmanager_secret_version을 쓰지
# 않으므로 state에 PAT 평문이 남지 않는다(감사 #1이 정한 원칙).
# =============================================================================

resource "aws_secretsmanager_secret" "argocd_git_pat" {
  name        = "gochuchamchi/argocd/git-pat"
  description = "gochuchamchi-gitops GitHub PAT (Contents: Read/write). Value injected manually via CLI, synced to K8s by ESO — never touched by Terraform."

  # 이 state는 destroy 대상이 아니라서 복구 기간이 의미가 없다. 값이 사라지는 사고를
  # 막는 것은 아래 prevent_destroy가 담당한다.
  recovery_window_in_days = 0

  lifecycle {
    prevent_destroy = true
  }
}

# Argo CD의 읽기 권한과 Image Updater의 쓰기 권한을 별도 fine-grained PAT로 분리한다.
# 값은 Terraform state에 넣지 않고, 운영자가 CLI 또는 eso.tf의 환경변수 주입으로만 넣는다.
resource "aws_secretsmanager_secret" "argocd_gitops_read_pat" {
  name                    = "gochuchamchi/argocd/gitops-read-pat"
  description             = "gochuchamchi-gitops GitHub PAT (Contents: Read-only) for Argo CD"
  recovery_window_in_days = 0

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_secretsmanager_secret" "argocd_image_updater_write_pat" {
  name                    = "gochuchamchi/argocd/image-updater-write-pat"
  description             = "gochuchamchi-gitops GitHub PAT (Contents: Read/write) for Argo CD Image Updater"
  recovery_window_in_days = 0

  lifecycle {
    prevent_destroy = true
  }
}
