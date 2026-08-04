# =============================================================================
# 비용 모니터링 — Budgets + Cost Anomaly Detection (2026-08-03)
#
#   1. AWS Budgets: 월 예산 대비 실사용 80% 도달 / 월말 예측 100% 초과 시 이메일.
#      💰 예산 2개까지 무료 (이 파일은 1개만 사용).
#   2. Cost Anomaly Detection: "평소 패턴 대비 갑자기 튀는 지출"을 ML로 감지.
#      예산은 총액 기준이라 느리게 반응하지만, 이건 특정 서비스가 급증하는 걸
#      바로 잡아낸다 (예: NAT 처리량 폭증, 실수로 켜둔 리소스). 무료.
#
#   확인 방법:
#     콘솔: Billing → Budgets / Cost Explorer → Cost Anomaly Detection
#     CLI:  .\check-cost.ps1  (서비스별 이번 달 비용 내림차순)
#
#   ⚠️ Budgets/Cost Explorer는 글로벌 서비스(us-east-1 엔드포인트)지만 프로바이더가
#      알아서 처리하므로 별도 provider alias 불필요.
# =============================================================================

variable "cost_alert_email" {
  description = "비용 알림을 받을 이메일 주소"
  type        = string
  default     = "where5683@naver.com"
}

variable "monthly_budget_usd" {
  description = "월 예산 상한(USD). 풀 구성 실측 후 조정할 것 — 초과가 아니라 알림 기준"
  type        = string
  default     = "350"
}

# ---------------------------------------------------------------------------
# 1. 월 예산 — 실사용 80% + 월말 예측 100% 두 단계 알림
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "gochuchamchi-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # 실사용이 예산의 80%에 도달하면 (이미 쓴 돈 기준 — 확정 신호)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.cost_alert_email]
  }

  # 월말 예측이 예산 100%를 넘으면 (미리 경고 — 실질적으로 더 유용)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.cost_alert_email]
  }
}

# ---------------------------------------------------------------------------
# 2. 이상 지출 감지 — 서비스 단위로 급증을 감지해서 즉시 이메일
# ---------------------------------------------------------------------------
resource "aws_ce_anomaly_monitor" "services" {
  name              = "gochuchamchi-service-anomalies"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE" # 서비스별로 각각 베이스라인을 학습
}

resource "aws_ce_anomaly_subscription" "email" {
  name      = "gochuchamchi-anomaly-email"
  frequency = "IMMEDIATE" # 감지 즉시 (DAILY/WEEKLY 요약도 가능)

  monitor_arn_list = [aws_ce_anomaly_monitor.services.arn]

  subscriber {
    type    = "EMAIL"
    address = var.cost_alert_email
  }

  # 이상 지출의 "예상 초과 금액"이 $5 이상일 때만 알림 (소액 노이즈 컷)
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["5"]
    }
  }
}

output "budget_name" {
  description = "생성된 월 예산 이름 (Billing 콘솔 → Budgets에서 확인)"
  value       = aws_budgets_budget.monthly.name
}
