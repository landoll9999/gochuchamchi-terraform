data "aws_caller_identity" "current" {}

locals {
  application_log_group_name = "/aws/containerinsights/${var.cluster_name}/application"

  application_log_group_arn = join("", [
    "arn:aws:logs:",
    var.region,
    ":",
    data.aws_caller_identity.current.account_id,
    ":log-group:",
    local.application_log_group_name,
    ":*"
  ])

  eks_logs_dashboard = jsonencode({
    id       = null
    uid      = "gochuchamchi-application-logs"
    title    = "03 Application Logs"
    timezone = "browser"

    tags = [
      "operations",
      "application",
      "eks",
      "cloudwatch",
      "logs"
    ]

    editable      = true
    schemaVersion = 41
    version       = 1
    refresh       = "30s"

    time = {
      from = "now-1h"
      to   = "now"
    }

    annotations = {
      list = []
    }

    templating = {
      list = []
    }

    panels = [
      # =====================================================
      # 1. 최근 1시간 ERROR 총개수
      # =====================================================
      {
        id    = 1
        title = "최근 1시간 ERROR"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 4
          w = 8
          x = 0
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

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
          graphMode   = "none"
          justifyMode = "center"
          orientation = "auto"
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
              filter @message like /(?i)(error|exception|failed)/
              | stats count(*) as error_count
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # 2. 최근 1시간 WARN 총개수
      # =====================================================
      {
        id    = 2
        title = "최근 1시간 WARN"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 4
          w = 8
          x = 8
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "green"
                  value = null
                },
                {
                  color = "yellow"
                  value = 1
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          colorMode   = "background"
          graphMode   = "none"
          justifyMode = "center"
          orientation = "auto"

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
              filter @message like /(?i)warn/
              | stats count(*) as warn_count
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # 1. 시간대별 ERROR 로그 발생 추이
      # =====================================================
      {
        id    = 6
        title = "ERROR 로그 발생 추이"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 8
          w = 12
          x = 0
          y = 4
        }

        fieldConfig = {
          defaults = {
            unit = "short"

            custom = {
              drawStyle         = "line"
              lineInterpolation = "smooth"
              lineWidth         = 2
              fillOpacity       = 15
              showPoints        = "never"

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
            calcs       = []
          }

          tooltip = {
            mode = "single"
            sort = "none"
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
              filter @message like /(?i)(error|exception|failed)/
              | stats count(*) as error_count by bin(5m)
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # 최근 1시간 전체 로그 개수
      # =====================================================
      {
        id    = 4
        title = "최근 1시간 전체 로그"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 4
          w = 8
          x = 16
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
          }

          overrides = []
        }

        options = {
          colorMode   = "value"
          graphMode   = "area"
          justifyMode = "center"
          orientation = "auto"

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
              stats count(*) as total_log_count
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # 2. 시간대별 WARN 로그 발생 추이
      # =====================================================
      {
        id    = 5
        title = "WARN 로그 발생 추이"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 8
          w = 12
          x = 12
          y = 4
        }

        fieldConfig = {
          defaults = {
            unit = "short"

            custom = {
              drawStyle         = "line"
              lineInterpolation = "smooth"
              lineWidth         = 2
              fillOpacity       = 15
              showPoints        = "never"

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
            calcs       = []
          }

          tooltip = {
            mode = "single"
            sort = "none"
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
              filter @message like /(?i)warn/
              | stats count(*) as warn_count by bin(5m)
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # 3. 최근 ERROR / Exception 로그
      # =====================================================
      {
        id    = 3
        title = "최근 ERROR / Exception 로그"
        type  = "logs"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 12
          w = 24
          x = 0
          y = 12
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
              | filter @message like /(?i)(error|exception|failed)/
              | sort @timestamp desc
              | limit 100
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # 3. 최근 전체 애플리케이션 로그
      # =====================================================
      {
        id    = 7
        title = "최근 애플리케이션 로그"
        type  = "logs"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 16
          w = 24
          x = 0
          y = 24
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
              | sort @timestamp desc
              | limit 200
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # Pod별 로그 발생량 Top 10
      # =====================================================
      {
        id    = 8
        title = "Pod별 로그 발생량 Top 10"
        type  = "table"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 10
          w = 24
          x = 0
          y = 40
        }

        fieldConfig = {
          defaults = {
            custom = {
              align = "auto"
              cellOptions = {
                type = "auto"
              }
            }
          }

          overrides = []
        }

        options = {
          showHeader = true
          cellHeight = "sm"
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
              fields kubernetes.pod_name
              | filter ispresent(kubernetes.pod_name)
              | stats count(*) as log_count by kubernetes.pod_name
              | sort log_count desc
              | limit 10
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
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
      # Pod별 ERROR 발생량 Top 10
      # =====================================================
      {
        id    = 9
        title = "Pod별 ERROR 발생량 Top 10"
        type  = "table"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 10
          w = 24
          x = 0
          y = 50
        }

        fieldConfig = {
          defaults = {
            custom = {
              align = "auto"

              cellOptions = {
                type = "auto"
              }
            }
          }

          overrides = []
        }

        options = {
          showHeader = true
          cellHeight = "sm"
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
              fields kubernetes.pod_name
              | filter ispresent(kubernetes.pod_name)
              | filter @message like /(?i)(error|exception|failed)/
              | stats count(*) as error_count by kubernetes.pod_name
              | sort error_count desc
              | limit 10
            QUERY

            logGroups = [
              {
                name = local.application_log_group_name
                arn  = local.application_log_group_arn
              }
            ]

            logGroupNames   = []
            matchExact      = true
            metricQueryType = 0
            statsGroups     = []
          }
        ]
      }
    ]
  })
}
