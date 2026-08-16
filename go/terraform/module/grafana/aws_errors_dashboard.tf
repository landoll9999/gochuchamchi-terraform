locals {
  rds_error_log_group_name = "/aws/rds/instance/${var.rds_identifier}/error"

  rds_error_log_group_arn = join("", [
    "arn:aws:logs:",
    var.region,
    ":",
    data.aws_caller_identity.current.account_id,
    ":log-group:",
    local.rds_error_log_group_name,
    ":*"
  ])
  aws_errors_dashboard = jsonencode({
    id                   = null
    uid                  = "gochuchamchi-service-dependencies"
    title                = "01 Service & Dependencies"
    tags                 = ["operations", "service", "dependencies", "cloudwatch"]
    timezone             = "browser"
    schemaVersion        = 41
    version              = 1
    refresh              = "30s"
    editable             = true
    graphTooltip         = 1
    fiscalYearStartMonth = 0

    time = {
      from = "now-1h"
      to   = "now"
    }

    templating = {
      list = []
    }

    annotations = {
      list = []
    }

    panels = [
      # =====================================================
      # 1. ALB 자체 5XX 오류
      # =====================================================
      {
        id    = 1
        title = "ALB 자체 5XX 오류"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 6
          x = 0
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["sum"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "HTTPCode_ELB_5XX_Count"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{LoadBalancer}}"
          }
        ]
      },
      # =====================================================
      # 2. Target 애플리케이션 5XX 오류
      # =====================================================
      {
        id    = 2
        title = "Target 애플리케이션 5XX 오류"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 6
          x = 6
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["sum"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "HTTPCode_Target_5XX_Count"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{LoadBalancer}}"
          }
        ]
      },
      # =====================================================
      # 3. ALB Target 연결 실패
      # =====================================================
      {
        id    = 3
        title = "ALB Target 연결 실패"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 6
          x = 12
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["sum"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "TargetConnectionErrorCount"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{LoadBalancer}}"
          }
        ]
      },
      # =====================================================
      # 4. 비정상 Target 수
      # =====================================================
      {
        id    = 4
        title = "최근 1시간 비정상 Target 최대 수"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 6
          x = 18
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["max"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "UnHealthyHostCount"
            statistic  = "Maximum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
              TargetGroup  = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{LoadBalancer}} / {{TargetGroup}}"
          }
        ]
      },
      # =====================================================
      # 5. 최근 1시간 RDS ERROR 개수
      # =====================================================
      {
        id    = 5
        title = "최근 1시간 RDS ERROR"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 6
          x = 0
          y = 5
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["lastNotNull"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            expression = <<-QUERY
              fields @timestamp, @message
              | filter @message like /(?i)(\[error\]|fatal|crash|failed|abort)/
              | stats count(*) as rds_error_count
            QUERY

            logGroups = [
              {
                name = local.rds_error_log_group_name
                arn  = local.rds_error_log_group_arn
              }
            ]

            logGroupNames   = []
            matchExact      = true
            metricQueryType = 0
            statsGroups     = []
          }
        ]
      },
      # =====================================================
      # 6. 최근 RDS ERROR 로그
      # =====================================================
      {
        id    = 6
        title = "최근 RDS ERROR 로그"
        type  = "logs"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 12
          w = 24
          x = 0
          y = 10
        }

        options = {
          showTime           = true
          showLabels         = false
          showCommonLabels   = false
          wrapLogMessage     = true
          prettifyLogMessage = false
          enableLogDetails   = true
          dedupStrategy      = "none"
          sortOrder          = "Descending"
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            expression = <<-QUERY
              fields @timestamp, @message, @logStream
              | filter @message like /(?i)(error|fatal|crash|failed|abort)/
              | sort @timestamp desc
              | limit 100
            QUERY

            logGroups = [
              {
                name = local.rds_error_log_group_name
                arn  = local.rds_error_log_group_arn
              }
            ]

            logGroupNames   = []
            matchExact      = true
            metricQueryType = 0
            statsGroups     = []
          }
        ]
      },
      # =====================================================
      # 7. Redis 인증 실패
      # =====================================================
      {
        id    = 7
        title = "최근 1시간 Redis 인증 실패"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 8
          x = 0
          y = 22
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["sum"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ElastiCache"
            metricName = "AuthenticationFailures"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              CacheClusterId = "*"
              CacheNodeId    = "*"
            }

            label = "{{CacheClusterId}} / {{CacheNodeId}}"
          }
        ]
      },
      # =====================================================
      # 8. Redis 연결 거부
      # =====================================================
      {
        id    = 8
        title = "최근 1시간 Redis 연결 거부"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 8
          x = 8
          y = 22
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["sum"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ElastiCache"
            metricName = "RejectedConnections"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              CacheClusterId = "*"
              CacheNodeId    = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{CacheClusterId}} / {{CacheNodeId}}"
          }
        ]
      },
      # =====================================================
      # 9. Redis 명령 실행 실패
      # =====================================================
      {
        id    = 9
        title = "최근 1시간 Redis 명령 실행 실패"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 5
          w = 8
          x = 16
          y = 22
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            noValue  = "0"

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"
          textMode    = "auto"
          wideLayout  = true

          reduceOptions = {
            calcs  = ["sum"]
            fields = ""
            values = false
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ElastiCache"
            metricName = "ErrorCount"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              CacheClusterId = "*"
              CacheNodeId    = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{CacheClusterId}} / {{CacheNodeId}}"
          }
        ]
      },
      # =====================================================
      # 10. Redis 오류 추이
      # =====================================================
      {
        id    = 10
        title = "Redis 오류 추이"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 9
          w = 24
          x = 0
          y = 27
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 10
              showPoints        = "auto"
              pointSize         = 5
              spanNulls         = false
              stacking = {
                mode  = "none"
                group = "A"
              }
            }
          }

          overrides = []
        }

        options = {
          legend = {
            displayMode = "list"
            placement   = "bottom"
            showLegend  = true
          }

          tooltip = {
            mode = "multi"
            sort = "desc"
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ElastiCache"
            metricName = "AuthenticationFailures"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              CacheClusterId = "*"
              CacheNodeId    = "*"
            }

            matchExact = true
            id         = ""
            label      = "인증 실패 - {{CacheClusterId}} / {{CacheNodeId}}"
          },
          {
            refId = "B"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ElastiCache"
            metricName = "RejectedConnections"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              CacheClusterId = "*"
              CacheNodeId    = "*"
            }

            matchExact = true
            id         = ""
            label      = "연결 거부 - {{CacheClusterId}} / {{CacheNodeId}}"
          },
          {
            refId = "C"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ElastiCache"
            metricName = "ErrorCount"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              CacheClusterId = "*"
              CacheNodeId    = "*"
            }

            matchExact = true
            id         = ""
            label      = "명령 실패 - {{CacheClusterId}} / {{CacheNodeId}}"
          }
        ]
      },
      # =====================================================
      # 11. RDS 오류 발생 추이
      # =====================================================
      {
        id    = 11
        title = "RDS 오류 발생 추이"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 9
          w = 24
          x = 0
          y = 36
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 15
              showPoints        = "auto"
              pointSize         = 5
              spanNulls         = false

              stacking = {
                mode  = "none"
                group = "A"
              }
            }
          }

          overrides = []
        }

        options = {
          legend = {
            displayMode = "list"
            placement   = "bottom"
            showLegend  = true
          }

          tooltip = {
            mode = "multi"
            sort = "desc"
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            expression = <<-QUERY
              fields @timestamp, @message
              | filter @message like /(?i)(error|fatal|crash|failed|abort)/
              | stats count(*) as rds_error_count by bin(5m)
            QUERY

            logGroups = [
              {
                name = local.rds_error_log_group_name
                arn  = local.rds_error_log_group_arn
              }
            ]

            logGroupNames   = []
            matchExact      = true
            metricQueryType = 0
            statsGroups     = []
          }
        ]
      },
      # =====================================================
      # 12. ALB 오류 발생 추이
      # =====================================================
      {
        id    = 12
        title = "ALB 오류 발생 추이"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 9
          w = 24
          x = 0
          y = 45
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 15
              showPoints        = "auto"
              pointSize         = 5
              spanNulls         = false

              stacking = {
                mode  = "none"
                group = "A"
              }
            }
          }

          overrides = []
        }

        options = {
          legend = {
            displayMode = "list"
            placement   = "bottom"
            showLegend  = true
          }

          tooltip = {
            mode = "multi"
            sort = "desc"
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "HTTPCode_ELB_5XX_Count"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
            }

            matchExact = true
            id         = ""
            label      = "ALB 자체 5XX - {{LoadBalancer}}"
          },
          {
            refId = "B"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "HTTPCode_Target_5XX_Count"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
            }

            matchExact = true
            id         = ""
            label      = "애플리케이션 5XX - {{LoadBalancer}}"
          },
          {
            refId = "C"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "TargetConnectionErrorCount"
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
            }

            matchExact = true
            id         = ""
            label      = "Target 연결 오류 - {{LoadBalancer}}"
          }
        ]
      },
      # =====================================================
      # 13. 비정상 Target 수 추이
      # =====================================================
      {
        id    = 13
        title = "비정상 Target 수 추이"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 9
          w = 24
          x = 0
          y = 54
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            min      = 0

            custom = {
              drawStyle         = "line"
              lineInterpolation = "stepAfter"
              lineWidth         = 2
              fillOpacity       = 15
              showPoints        = "auto"
              pointSize         = 5
              spanNulls         = false

              stacking = {
                mode  = "none"
                group = "A"
              }
            }

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "red"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          legend = {
            displayMode = "table"
            placement   = "bottom"
            showLegend  = true

            calcs = [
              "lastNotNull",
              "max"
            ]
          }

          tooltip = {
            mode = "multi"
            sort = "desc"
          }
        }

        targets = [
          {
            refId = "A"

            datasource = {
              type = "cloudwatch"
              uid  = "cloudwatch"
            }

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ApplicationELB"
            metricName = "UnHealthyHostCount"
            statistic  = "Maximum"
            period     = "60"
            region     = var.region

            dimensions = {
              LoadBalancer = "*"
              TargetGroup  = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{TargetGroup}}"
          }
        ]
      }
    ]
  })
}
