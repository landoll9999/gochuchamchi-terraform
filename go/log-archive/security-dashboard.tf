# =============================================================================
# Compact security overview - one dashboard, eight widgets
#
# This dashboard answers "is something happening?". Detailed IP, URI, and user
# investigation stays in Athena so the overview does not become a log wall.
# =============================================================================

locals {
  security_dashboard_name = "gochuchamchi-security-overview"

  security_dashboard_widgets = [
    {
      type   = "text"
      x      = 0
      y      = 0
      width  = 24
      height = 2
      properties = {
        markdown = "# Gochuchamchi Security Overview\nReview WAF blocks, application failures, security events, and log-delivery health in order. Investigate IP, URI, and user details in Athena."
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 2
      width  = 24
      height = 4
      properties = {
        title     = "Current security signals (last hour)"
        view      = "singleValue"
        region    = var.region
        period    = 300
        stat      = "Sum"
        sparkline = true
        metrics = [
          ["AWS/WAFV2", "BlockedRequests", "WebACL", "gochuchamchi-edge-waf", "Rule", "ALL", { accountId = local.workload_account_id, region = "us-east-1", label = "WAF blocks" }],
          ["Gochuchamchi/ApplicationSecurity", "Http4xxCount", { accountId = local.workload_account_id, label = "App 4xx" }],
          ["Gochuchamchi/ApplicationSecurity", "Http5xxCount", { accountId = local.workload_account_id, label = "App 5xx" }],
          ["Gochuchamchi/ApplicationSecurity", "LoginFailureCount", { accountId = local.workload_account_id, label = "Login failures" }],
          ["Gochuchamchi/ApplicationSecurity", "AccessDeniedCount", { accountId = local.workload_account_id, label = "Access denied" }],
          ["Gochuchamchi/ApplicationSecurity", "HighSecurityEventCount", { accountId = local.workload_account_id, label = "High/Critical" }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 6
      width  = 12
      height = 6
      properties = {
        title   = "WAF blocked requests by rule"
        view    = "timeSeries"
        region  = "us-east-1"
        period  = 300
        stat    = "Sum"
        stacked = false
        metrics = [
          ["AWS/WAFV2", "BlockedRequests", "WebACL", "gochuchamchi-edge-waf", "Rule", "ALL", { accountId = local.workload_account_id, label = "All" }],
          ["AWS/WAFV2", "BlockedRequests", "WebACL", "gochuchamchi-edge-waf", "Rule", "gochuchamchi-rate-limit", { accountId = local.workload_account_id, label = "Rate limit" }],
          ["AWS/WAFV2", "BlockedRequests", "WebACL", "gochuchamchi-edge-waf", "Rule", "gochuchamchi-sqli", { accountId = local.workload_account_id, label = "SQLi" }],
          ["AWS/WAFV2", "BlockedRequests", "WebACL", "gochuchamchi-edge-waf", "Rule", "gochuchamchi-known-bad-inputs", { accountId = local.workload_account_id, label = "Known bad inputs" }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 6
      width  = 12
      height = 6
      properties = {
        title   = "Requests that reached the application (4xx/5xx)"
        view    = "timeSeries"
        region  = var.region
        period  = 300
        stacked = false
        metrics = [
          [{ expression = "SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} :aws.AccountId=${local.workload_account_id} MetricName=\"HTTPCode_Target_4XX_Count\"', 'Sum', 300))", id = "alb4xx", label = "ALB target 4xx" }],
          [{ expression = "SUM(SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} :aws.AccountId=${local.workload_account_id} MetricName=\"HTTPCode_Target_5XX_Count\"', 'Sum', 300))", id = "alb5xx", label = "ALB target 5xx" }],
          ["Gochuchamchi/ApplicationSecurity", "Http4xxCount", { accountId = local.workload_account_id, id = "app4xx", stat = "Sum", label = "App 4xx" }],
          ["Gochuchamchi/ApplicationSecurity", "Http5xxCount", { accountId = local.workload_account_id, id = "app5xx", stat = "Sum", label = "App 5xx" }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 12
      width  = 12
      height = 6
      properties = {
        title   = "Application authentication and authorization events"
        view    = "timeSeries"
        region  = var.region
        period  = 300
        stat    = "Sum"
        stacked = false
        metrics = [
          ["Gochuchamchi/ApplicationSecurity", "LoginFailureCount", { accountId = local.workload_account_id, label = "Login failures" }],
          ["Gochuchamchi/ApplicationSecurity", "AccessDeniedCount", { accountId = local.workload_account_id, label = "Access denied" }],
          ["Gochuchamchi/ApplicationSecurity", "HighSecurityEventCount", { accountId = local.workload_account_id, label = "High/Critical" }]
        ]
      }
    },
    {
      type   = "metric"
      x      = 12
      y      = 12
      width  = 12
      height = 6
      properties = {
        title  = "Service availability and latency"
        view   = "timeSeries"
        region = var.region
        period = 300
        metrics = [
          [{ expression = "SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} :aws.AccountId=${local.workload_account_id} MetricName=\"UnHealthyHostCount\"', 'Maximum', 300)", id = "unhealthy", label = "Unhealthy targets" }],
          [{ expression = "SEARCH('{AWS/ApplicationELB,LoadBalancer,TargetGroup} :aws.AccountId=${local.workload_account_id} MetricName=\"TargetResponseTime\"', 'p95', 300)", id = "latency", label = "Target p95 response time", yAxis = "right" }]
        ]
        yAxis = {
          left  = { min = 0, label = "Targets" }
          right = { min = 0, label = "Seconds" }
        }
      }
    },
    {
      type   = "metric"
      x      = 0
      y      = 18
      width  = 24
      height = 6
      properties = {
        title   = "Central log-delivery pipeline health"
        view    = "timeSeries"
        region  = var.region
        period  = 300
        stacked = false
        metrics = concat(
          [
            for source in sort(tolist(local.cloudwatch_log_delivery_sources)) :
            ["AWS/Firehose", "DeliveryToS3.DataFreshness", "DeliveryStreamName", "gochuchamchi-${source}-log-archive", { stat = "Maximum", label = "${source} freshness (seconds)" }]
          ],
          [
            for source in sort(tolist(local.cloudwatch_log_delivery_sources)) :
            ["AWS/Firehose", "ThrottledRecords", "DeliveryStreamName", "gochuchamchi-${source}-log-archive", { stat = "Sum", label = "${source} throttled", yAxis = "right" }]
          ]
        )
        yAxis = {
          left  = { min = 0, label = "Data freshness (seconds)" }
          right = { min = 0, label = "Throttled records" }
        }
        annotations = {
          horizontal = [{ value = 900, label = "Delayed over 15 minutes", color = "#d62728" }]
        }
      }
    },
    {
      type   = "text"
      x      = 0
      y      = 24
      width  = 24
      height = 3
      properties = {
        markdown = "## Detailed investigation\nOpen the [Athena query editor](https://${var.region}.console.aws.amazon.com/athena/home?region=${var.region}#/query-editor) in the Log account and run saved queries `09` through `16`. Start with `12-application-security-failures`, `13-application-high-critical-events`, and `16-waf-allow-application-failure-correlation`."
      }
    }
  ]
}

resource "aws_cloudwatch_dashboard" "security_overview" {
  dashboard_name = local.security_dashboard_name
  dashboard_body = jsonencode({
    start          = "-PT1H"
    periodOverride = "inherit"
    widgets        = local.security_dashboard_widgets
  })

  depends_on = [
    aws_oam_sink_policy.security_monitoring_seoul,
    aws_oam_sink_policy.security_monitoring_us_east_1
  ]
}

output "security_dashboard_name" {
  description = "Name of the compact security CloudWatch dashboard in the Log account"
  value       = aws_cloudwatch_dashboard.security_overview.dashboard_name
}
