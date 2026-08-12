# =============================================================================
# Application security detection
#
# Spring emits one-line JSON security/access events. The CloudWatch
# Observability add-on normally parses that JSON below `log_processed`, while
# a custom collector can deliver the JSON at the root. Keep one metric filter
# for each shape so an add-on configuration change does not silently disable
# detection.
#
# Alarm state changes are picked up by ../cloudwatch-notifications through its
# `gochuchamchi-` EventBridge prefix rule, so alarm_actions are intentionally
# not duplicated here.
# =============================================================================

locals {
  application_security_metric_namespace = "Gochuchamchi/ApplicationSecurity"

  application_security_metric_filters = {
    http-4xx-merged = {
      pattern     = "{ $.log_processed.eventCategory = \"HTTP_ACCESS\" && $.log_processed.statusCode >= 400 && $.log_processed.statusCode < 500 }"
      metric_name = "Http4xxCount"
    }
    http-4xx-root = {
      pattern     = "{ $.eventCategory = \"HTTP_ACCESS\" && $.statusCode >= 400 && $.statusCode < 500 }"
      metric_name = "Http4xxCount"
    }
    http-5xx-merged = {
      pattern     = "{ $.log_processed.eventCategory = \"HTTP_ACCESS\" && $.log_processed.statusCode >= 500 && $.log_processed.statusCode < 600 }"
      metric_name = "Http5xxCount"
    }
    http-5xx-root = {
      pattern     = "{ $.eventCategory = \"HTTP_ACCESS\" && $.statusCode >= 500 && $.statusCode < 600 }"
      metric_name = "Http5xxCount"
    }
    login-failure-merged = {
      pattern     = "{ $.log_processed.eventCategory = \"SECURITY_EVENT\" && $.log_processed.eventType = \"LOGIN\" && $.log_processed.outcome = \"FAILURE\" }"
      metric_name = "LoginFailureCount"
    }
    login-failure-root = {
      pattern     = "{ $.eventCategory = \"SECURITY_EVENT\" && $.eventType = \"LOGIN\" && $.outcome = \"FAILURE\" }"
      metric_name = "LoginFailureCount"
    }
    access-denied-merged = {
      pattern     = "{ $.log_processed.eventCategory = \"SECURITY_EVENT\" && ($.log_processed.eventType = \"ACCESS_DENIED\" || $.log_processed.eventType = \"ACCESS_BLOCKED\") }"
      metric_name = "AccessDeniedCount"
    }
    access-denied-root = {
      pattern     = "{ $.eventCategory = \"SECURITY_EVENT\" && ($.eventType = \"ACCESS_DENIED\" || $.eventType = \"ACCESS_BLOCKED\") }"
      metric_name = "AccessDeniedCount"
    }
    high-security-event-merged = {
      pattern     = "{ $.log_processed.eventCategory = \"SECURITY_EVENT\" && ($.log_processed.severity = \"HIGH\" || $.log_processed.severity = \"CRITICAL\") }"
      metric_name = "HighSecurityEventCount"
    }
    high-security-event-root = {
      pattern     = "{ $.eventCategory = \"SECURITY_EVENT\" && ($.severity = \"HIGH\" || $.severity = \"CRITICAL\") }"
      metric_name = "HighSecurityEventCount"
    }
  }

  application_security_alarms = {
    http-4xx = {
      metric_name = "Http4xxCount"
      threshold   = var.application_http_4xx_alarm_threshold
      description = "5분 동안 애플리케이션 4xx 응답이 급증했습니다. 401/403/404/429, IP, URI와 WAF ALLOW 로그를 함께 확인하세요."
    }
    http-5xx = {
      metric_name = "Http5xxCount"
      threshold   = var.application_http_5xx_alarm_threshold
      description = "5분 동안 애플리케이션 5xx 응답이 급증했습니다. 예외 유형, URI와 동일 시간대 WAF ALLOW 요청을 확인하세요."
    }
    login-failure = {
      metric_name = "LoginFailureCount"
      threshold   = var.application_login_failure_alarm_threshold
      description = "5분 동안 로그인 실패가 반복되었습니다. 계정 탈취 시도 여부와 IP·사용자명을 확인하세요."
    }
    access-denied = {
      metric_name = "AccessDeniedCount"
      threshold   = var.application_access_denied_alarm_threshold
      description = "5분 동안 애플리케이션 권한 거부가 반복되었습니다. 정상 사용자 오동작인지 권한 우회 시도인지 확인하세요."
    }
    high-security-event = {
      metric_name = "HighSecurityEventCount"
      threshold   = 1
      description = "HIGH/CRITICAL 애플리케이션 보안 이벤트가 발생했습니다. 권한 변경·차단·비밀번호 변경 등 이벤트 상세를 즉시 확인하세요."
    }
  }
}

resource "aws_cloudwatch_log_metric_filter" "application_security" {
  for_each = local.application_security_metric_filters

  name           = "gochuchamchi-app-${each.key}"
  log_group_name = aws_cloudwatch_log_group.container_insights_application.name
  pattern        = each.value.pattern

  metric_transformation {
    name      = each.value.metric_name
    namespace = local.application_security_metric_namespace
    value     = "1"
    unit      = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "application_security" {
  for_each = local.application_security_alarms

  alarm_name        = "gochuchamchi-app-${each.key}"
  alarm_description = each.value.description

  namespace   = local.application_security_metric_namespace
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
    Component   = "application-security-monitoring"
  }

  depends_on = [aws_cloudwatch_log_metric_filter.application_security]
}

variable "application_http_4xx_alarm_threshold" {
  description = "5분 동안 애플리케이션 4xx 응답 알람 임계값"
  type        = number
  default     = 20

  validation {
    condition     = var.application_http_4xx_alarm_threshold >= 1
    error_message = "애플리케이션 4xx 알람 임계값은 1 이상이어야 합니다."
  }
}

variable "application_http_5xx_alarm_threshold" {
  description = "5분 동안 애플리케이션 5xx 응답 알람 임계값"
  type        = number
  default     = 5

  validation {
    condition     = var.application_http_5xx_alarm_threshold >= 1
    error_message = "애플리케이션 5xx 알람 임계값은 1 이상이어야 합니다."
  }
}

variable "application_login_failure_alarm_threshold" {
  description = "5분 동안 로그인 실패 알람 임계값"
  type        = number
  default     = 5

  validation {
    condition     = var.application_login_failure_alarm_threshold >= 1
    error_message = "로그인 실패 알람 임계값은 1 이상이어야 합니다."
  }
}

variable "application_access_denied_alarm_threshold" {
  description = "5분 동안 권한 거부 알람 임계값"
  type        = number
  default     = 5

  validation {
    condition     = var.application_access_denied_alarm_threshold >= 1
    error_message = "권한 거부 알람 임계값은 1 이상이어야 합니다."
  }
}
