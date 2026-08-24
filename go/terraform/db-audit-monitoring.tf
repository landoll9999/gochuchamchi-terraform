# =============================================================================
# DB 감사 로그 가드레일 — 제로트러스트 위반 탐지 (2026-08-20)
#
# RDS 감사 로그(MariaDB audit 플러그인, CSV)에서 "제로트러스트 선을 넘는" 동작만
# 잡아 알람 → Discord로 올린다. Web/Admin 앱 계정은 파드 대역에서
# DML만 하는 것이 정상이라, 그 밖의 동작은 정상 운영에서 절대 안 나온다 = 뜨면 사건.
#
# 왜 실시간 패널이 아니라 알람인가 — 감사 로그는 rdsadmin 헬스체크·앱 INSERT로
# 노이즈가 크다(24h에 2천여 건). 가드레일 위반만 밀어 "안 봐도 되는" 탐지로 만든다.
#
# 필터 문법 — 앱 로그는 JSON({ $.f = v })이지만 감사 로그는 CSV라 텍스트 매칭이다.
# 공백 구분 텀은 AND, "..."는 정확 매칭 (2026-08-20 test-metric-filter로 검증:
# `"gochuchamchi_web_iam" DROP`은 DROP행만 잡고 정상 INSERT행은 제외).
#
# 알람 이름 접두사 gochuchamchi- 로 ../cloudwatch-notifications의 EventBridge가
# 잡아 SNS→Discord로 넘긴다. alarm_actions는 일부러 안 단다(다른 알람과 동일).
# =============================================================================

variable "db_app_account_usernames" {
  description = "DB 감사 가드레일이 감시하는 Web/Admin IAM DB 계정"
  type        = set(string)
  default     = ["gochuchamchi_web_iam", "gochuchamchi_admin_iam"]
}

variable "db_failed_connect_alarm_threshold" {
  description = "5분 동안 DB FAILED_CONNECT 알람 임계값. IAM 토큰 전환 뒤 정상값은 0에 가까우므로 낮게 둔다."
  type        = number
  default     = 5

  validation {
    condition     = var.db_failed_connect_alarm_threshold >= 1
    error_message = "DB FAILED_CONNECT 알람 임계값은 1 이상이어야 합니다."
  }
}

locals {
  # 로그 그룹은 RDS가 audit export로 자동 생성한다(/aws/rds/instance/<id>/audit).
  db_audit_log_group_name   = "/aws/rds/instance/${data.aws_db_instance.this.db_instance_identifier}/audit"
  db_audit_metric_namespace = "Gochuchamchi/DatabaseAudit"

  # 앱 계정(DML 전용)이 시도하면 안 되는 DDL/DCL 키워드.
  # 각 키워드 × 앱계정 필터가 모두 같은 지표(AppAccountDdlDclAttempt)로 합쳐진다
  # (application-security의 merged/root 다중 필터→단일 지표와 동일 방식).
  # ⚠️ CREATE 등은 INSERT/UPDATE 데이터에 그 단어가 들어가면 오탐 가능(감사는 SELECT
  #    제외 DML만 기록). 앱 데이터가 구조적이라 위험은 낮지만, 오탐이 잦으면 이 목록에서
  #    해당 키워드를 빼면 된다. 알람은 "즉시 조사"라 드문 오탐은 감수한다.
  db_app_account_forbidden_ops = ["DROP", "ALTER", "CREATE", "GRANT", "REVOKE", "TRUNCATE"]

  db_audit_metric_filters = merge(
    {
      # ② DB 인증 실패 — 무차별 대입·IAM 토큰 우회·프로빙
      failed-connect = {
        pattern     = "FAILED_CONNECT"
        metric_name = "DbFailedConnectCount"
      }
    },
    {
      # ① 앱 계정(DML 전용)이 DDL/DCL 시도 — 제로트러스트상 절대 불가
      for pair in setproduct(var.db_app_account_usernames, local.db_app_account_forbidden_ops) :
      "app-${replace(pair[0], "_", "-")}-ddl-${lower(pair[1])}" => {
        pattern     = "\"${pair[0]}\" ${pair[1]}"
        metric_name = "AppAccountDdlDclAttempt"
      }
    }
  )

  # 알람 이름은 gochuchamchi-db-${key} 이므로 key에는 db- 를 다시 붙이지 않는다
  # (안 그러면 gochuchamchi-db-db-... 로 중복). 필터 key와도 접두사 정합.
  db_audit_alarms = {
    failed-connect = {
      metric_name = "DbFailedConnectCount"
      threshold   = var.db_failed_connect_alarm_threshold
      description = "5분 동안 DB 접속 실패(FAILED_CONNECT)가 반복되었습니다. IAM 토큰 문제인지 무차별 대입/무단 접속 시도인지 srchost·dbuser로 확인하세요."
    }
    app-account-ddl-dcl = {
      metric_name = "AppAccountDdlDclAttempt"
      threshold   = 1
      description = "Web/Admin 전용 DB 계정이 DDL/DCL(DROP/ALTER/GRANT 등)을 시도했습니다. 최소권한 경계 우회 시도일 수 있으므로 즉시 확인하세요."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "db_audit" {
  for_each = local.db_audit_metric_filters

  name           = "gochuchamchi-db-${each.key}"
  log_group_name = local.db_audit_log_group_name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.value.metric_name
    namespace = local.db_audit_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "db_audit" {
  for_each = local.db_audit_alarms

  alarm_name        = "gochuchamchi-db-${each.key}"
  alarm_description = each.value.description

  namespace   = local.db_audit_metric_namespace
  metric_name = each.value.metric_name
  statistic   = "Sum"

  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.threshold
  treat_missing_data  = "notBreaching"

  tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "db-audit-monitoring"
  }

  depends_on = [aws_cloudwatch_log_metric_filter.db_audit]
}
