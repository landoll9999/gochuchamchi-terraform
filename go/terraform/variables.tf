variable "aws_profile" {
  description = "AWS CLI profile (PowerShell에서 관리 중인 프로파일명)"
  type        = string
  default     = "admin"
}

variable "region" {
  type    = string
  default = "ap-northeast-2"
}

variable "azs" {
  type    = list(string)
  default = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "cluster_name" {
  type    = string
  default = "gochuchamchi-eks"
}

variable "domain_name" {
  description = "Route53에 이미 등록된 gochuchamchi.shop 도메인"
  type        = string
  default     = "gochuchamchi.shop"
}

# (2026-08-04 백로그 B2) key_name 변수 제거 — 노드/NAT/배스천 전부 SSM 접속만 사용,
# SSH 키페어를 붙이는 리소스가 더 이상 없음

variable "bastion_ami" {
  description = "AL2023 AMI (2026-07-27 기준 서울 리전 최신값으로 확인함)"
  type        = string
  default     = "ami-0f93dc65265863858"
}

variable "nat_ami" {
  description = "NAT 인스턴스용 AMI (bastion과 동일 AL2023 이미지 사용)"
  type        = string
  default     = "ami-0f93dc65265863858"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_desired_size" {
  type    = number
  default = 2
}

# ---------------------------------------------------------------------------
# ArgoCD GitOps 저장소
# ---------------------------------------------------------------------------
variable "argocd_github_owner" {
  description = "GitOps 저장소가 위치한 GitHub 계정/조직"
  type        = string
  default     = "landoll9999"
}

variable "argocd_gitops_repo" {
  description = "Argo CD가 감시할 GitOps 저장소 이름 (Deployment/Service/HPA만 담음)"
  type        = string
  default     = "gochuchamchi-gitops"
}

# (2026-08-04 백로그 B3) argocd_git_pat 변수 제거 — PAT는 이제 Terraform을 아예
# 거치지 않는다. Secrets Manager(gochuchamchi/argocd/git-pat)에 CLI로 1회 주입하면
# ESO가 클러스터로 동기화함 (eso.tf 참고). TF_VAR_argocd_git_pat 환경변수도 불필요.

# (2026-08-04 백로그 B4) ArgoCD admin 비밀번호의 "bcrypt 해시" (평문 아님).
# UI 수동 변경은 재구축마다 초기 비밀번호로 회귀했으므로 코드로 고정한다.
# 해시 생성: htpasswd -nbBC 10 "" '<새 비밀번호>' | tr -d ':\n'  (argocd.tf B4 주석 참고)
# 주입: $env:TF_VAR_argocd_admin_password_bcrypt = '<$2y$10$...해시>'
# 기본값 ""이면 기존 동작(argocd-initial-admin-secret) 유지.
variable "argocd_admin_password_bcrypt" {
  description = "ArgoCD admin 비밀번호의 bcrypt 해시. 빈 문자열이면 초기 비밀번호 동작 유지"
  type        = string
  default     = ""

  validation {
    condition     = var.argocd_admin_password_bcrypt == "" || can(regex("^\\$2[aby]\\$", var.argocd_admin_password_bcrypt))
    error_message = "bcrypt 해시($2a$/$2b$/$2y$ 시작)만 허용됩니다. 평문 비밀번호를 넣지 마세요 — htpasswd -nbBC 10 \"\" '<비밀번호>' | tr -d ':\\n' 으로 생성."
  }
}

# EKS 퍼블릭 엔드포인트 접속 허용 IP.
# 이 목록에 없는 네트워크에서 apply하면 kubernetes/helm 프로바이더가 인증 에러가 아니라
# TCP 타임아웃(connectex ... did not properly respond)으로 전부 실패한다. AWS API만 쓰는
# 리소스(EKS/RDS/null_resource+SSM 등)는 정상 진행되므로 apply가 절반만 성공한 상태가 된다.
# 작업 네트워크가 바뀌면 `curl checkip.amazonaws.com`으로 확인해서 여기에 추가할 것.
# 주의: 안 쓰는 항목은 지울 것 — 유동 IP는 나중에 남에게 재할당되므로 stale한 /32가 남으면
#       그 사람에게 엔드포인트 접근을 열어주는 셈이 된다.
variable "endpoint_public_access_cidrs" {
  description = "EKS 퍼블릭 엔드포인트 접속을 허용할 CIDR 목록"
  type        = list(string)
  default = [
    "116.122.154.177/32", # 집
    "112.221.246.164/32", # 현재 작업 네트워크 (2026-07-30 확인)
  ]
}

# ---------------------------------------------------------------------------
# CloudWatch Container Insights
# ---------------------------------------------------------------------------

variable "container_insights_log_retention_days" {
  description = "Container Insights 로그 보존 기간"
  type        = number
  default     = 30
}

variable "cloudwatch_log_archive_retention_days" {
  description = "중앙 S3에 보관할 CloudWatch 로그의 총 보존 기간"
  type        = number
  default     = 365

  validation {
    condition     = var.cloudwatch_log_archive_retention_days > 90
    error_message = "S3 아카이브 보존 기간은 Glacier 전환 시점보다 긴 91일 이상이어야 합니다."
  }
}

# ---------------------------------------------------------------------------
# AWS Config / Security Hub
# ---------------------------------------------------------------------------

variable "aws_config_snapshot_delivery_frequency" {
  description = "AWS Config 전체 스냅샷을 중앙 S3로 전달하는 주기. 짧게 잡을수록 S3 객체 수와 비용이 늘어난다."
  type        = string
  default     = "Six_Hours"

  validation {
    condition = contains([
      "One_Hour",
      "Three_Hours",
      "Six_Hours",
      "Twelve_Hours",
      "TwentyFour_Hours"
    ], var.aws_config_snapshot_delivery_frequency)
    error_message = "aws_config_snapshot_delivery_frequency는 AWS Config가 지원하는 전달 주기여야 합니다."
  }
}

# 우선 FSBP만 켜고, CIS 점검이 필요해지면 true로 바꾼다.
# 표준을 하나 더 켜면 Control 평가 수만큼 Security Hub 비용이 추가된다.
variable "security_hub_enable_cis_benchmark_v3" {
  description = "Security Hub에 CIS AWS Foundations Benchmark v3.0.0을 추가로 활성화할지 여부"
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Athena / CloudTrail
# ---------------------------------------------------------------------------

variable "athena_cloudtrail_projection_start_date" {
  description = "Athena CloudTrail 파티션 프로젝션 시작일 (yyyy/MM/dd)"
  type        = string
  default     = "2026/01/01"

  validation {
    condition     = can(regex("^\\d{4}/(0[1-9]|1[0-2])/(0[1-9]|[12]\\d|3[01])$", var.athena_cloudtrail_projection_start_date))
    error_message = "Athena 파티션 시작일은 yyyy/MM/dd 형식이어야 합니다."
  }
}

# ---------------------------------------------------------------------------
# (2026-08-04 복원) 이하 변수들은 8/3 full-HA 보안 강화 라인(fin)에서 복원됨.
# 저장소 재생성 때 13개 파일과 함께 누락됐던 것을 병합 — 경위는
# docs/2026-08-04-incident-and-review.md §4(복원) 참고.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# L1 경계 방어 — CloudFront + WAF (edge.tf)
# ---------------------------------------------------------------------------

variable "enable_edge" {
  description = <<-EOT
    CloudFront + Route53 전환 활성화 여부.

    ALB는 aws-load-balancer-controller가 비동기로 생성하므로 최초 apply에서는
    data.aws_lb 조회가 실패한다.

    1차 apply: false (기본값) — us-east-1 인증서 + WAF까지만 생성
    2차 apply: true — ALB가 뜬 뒤 CloudFront 생성 + gochuchamchi.shop을 CloudFront로 전환
  EOT
  type        = bool
  default     = false
}

variable "waf_rate_limit_per_5min" {
  description = "WAF rate-based rule: 단일 IP가 5분 동안 보낼 수 있는 최대 요청 수 (초과분 차단)"
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit_per_5min >= 100
    error_message = "WAFv2 rate-based rule의 최소 한도는 100입니다."
  }
}

# ---------------------------------------------------------------------------
# IAM 보안 (iam-security.tf)
# ---------------------------------------------------------------------------

# ⚠️ Terraform을 돌리는 계정(현재 admin 프로파일의 IAM 사용자)을 절대 넣지 말 것.
#    이 그룹에는 MFA 강제 + Region Guard의 explicit Deny가 붙어 있어서,
#    CLI 액세스 키(MFA 없음)로 도는 Terraform이 통째로 AccessDenied가 된다
#    (07/29 '3pro' 그룹 사고와 같은 유형 — docs/architecture.md §4.2).
variable "console_admin_users" {
  description = "MFA 강제 콘솔 관리자 그룹에 넣을 IAM 사용자 이름 목록 (콘솔 전용 사용자만)"
  type        = list(string)
  default     = []
}

variable "allowed_regions" {
  description = "Region Guard가 허용하는 리전 (서울 워크로드 + 도쿄 DR). 글로벌 서비스는 정책의 NotAction으로 별도 제외"
  type        = list(string)
  default     = ["ap-northeast-2", "ap-northeast-1"]
}

# ---------------------------------------------------------------------------
# L8 복원력 — Tokyo DR (dr.tf)
# ---------------------------------------------------------------------------

variable "enable_dr" {
  description = "AWS Backup(RDS/EFS -> 도쿄 크로스리전 복사) + S3 CRR 활성화 여부. 끄면 볼트/플랜/복제가 모두 제거됨"
  type        = bool
  default     = true
}

variable "dr_backup_retention_days" {
  description = "AWS Backup 복구 지점 보존 일수 (서울 원본·도쿄 사본 동일 적용)"
  type        = number
  default     = 7
}

# ---------------------------------------------------------------------------
# GuardDuty 런타임 모니터링 (guardduty.tf)
# ---------------------------------------------------------------------------

variable "enable_guardduty_runtime_monitoring" {
  description = <<-EOT
    GuardDuty 런타임 모니터링(노드 DaemonSet 에이전트) 활성화 여부.
    프로세스/시스콜 수준 탐지가 추가되지만 t3.small 2대에는 메모리 부담이 있어
    기본 OFF. EKS 감사 로그/CloudTrail/FlowLogs 기반 탐지는 이 값과 무관하게 동작.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# 애플리케이션 설정 (k8s-deploy.tf)
# ---------------------------------------------------------------------------

# 앱의 SuperAdminBootstrap이 기동할 때마다 이 아이디를 superadmin으로 승격한다.
# 계정 생성은 하지 않으므로 해당 아이디로 회원가입이 먼저 되어 있어야 한다.
# 비워두면 아무 동작도 하지 않으며, 그 경우 superadmin이 한 명도 없어서
# admin 임명/해임 같은 superadmin 전용 기능을 쓸 수 없다.
variable "superadmin_username" {
  description = "superadmin으로 승격할 계정 아이디 (앱 ConfigMap의 APP_SUPERADMIN_USERNAME)"
  type        = string
  default     = ""
}

# ---------------------------------------------------------------------------
# 컨테이너 보안 — Pod Security Standards (k8s-deploy.tf 네임스페이스 라벨)
# ---------------------------------------------------------------------------

variable "pss_enforce_level" {
  description = "gochuchamchi 네임스페이스의 Pod Security Standards enforce 레벨. gitops Deployment에 securityContext 적용 후 restricted 로 올릴 것 (docs/CONTAINER_SECURITY.md 참고)"
  type        = string
  default     = "baseline"

  validation {
    condition     = contains(["privileged", "baseline", "restricted"], var.pss_enforce_level)
    error_message = "pss_enforce_level 은 privileged / baseline / restricted 중 하나여야 합니다."
  }
}
