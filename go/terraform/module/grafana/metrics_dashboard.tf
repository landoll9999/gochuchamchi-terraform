locals {
  eks_health_dashboard = jsonencode({
    id                   = null
    uid                  = "gochuchamchi-platform-health"
    title                = "02 Platform Health"
    tags                 = ["operations", "platform", "eks", "cloudwatch"]
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
      # 1. 실행 중인 Pod 수
      # =====================================================
      {
        id    = 1
        title = "실행 중인 Pod"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 4
          w = 6
          x = 0
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "red"
                  value = null
                },
                {
                  color = "green"
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

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "ContainerInsights"
            metricName = "namespace_number_of_running_pods"
            statistic  = "Average"
            period     = "60"
            region     = var.region

            dimensions = {
              ClusterName = var.cluster_name
            }

            matchExact = true
            id         = ""
            label      = "Running Pods"
          }
        ]
      },
      # =====================================================
      # 2. 비정상 Node 수
      # =====================================================
      {
        id    = 2
        title = "비정상 Node"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 4
          w = 6
          x = 6
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

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
          graphMode   = "none"
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

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "ContainerInsights"
            metricName = "cluster_failed_node_count"
            statistic  = "Maximum"
            period     = "60"
            region     = var.region

            dimensions = {
              ClusterName = var.cluster_name
            }

            matchExact = true
            id         = ""
            label      = "Failed Nodes"
          }
        ]
      },
      # =====================================================
      # 3. 전체 Worker Node 수
      # =====================================================
      {
        id    = 3
        title = "전체 Worker Node"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 4
          w = 6
          x = 12
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

            color = {
              mode = "thresholds"
            }

            mappings = []

            thresholds = {
              mode = "absolute"

              steps = [
                {
                  color = "red"
                  value = null
                },
                {
                  color = "green"
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

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "ContainerInsights"
            metricName = "cluster_node_count"
            statistic  = "Maximum"
            period     = "60"
            region     = var.region

            dimensions = {
              ClusterName = var.cluster_name
            }

            matchExact = true
            id         = ""
            label      = "Worker Nodes"
          }
        ]
      },
      # =====================================================
      # 4. Pending Pod 수
      # =====================================================
      {
        id    = 4
        title = "Pending Pod"
        type  = "stat"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 4
          w = 6
          x = 18
          y = 0
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0

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
          graphMode   = "none"
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

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "ContainerInsights"
            metricName = "pod_status_pending"
            statistic  = "Maximum"
            period     = "60"
            region     = var.region

            dimensions = {
              ClusterName = var.cluster_name
            }

            matchExact = true
            id         = ""
            label      = "Pending Pods"
          }
        ]
      },
      # =====================================================
      # 5. Node CPU 사용률
      # =====================================================
      {
        id    = 5
        title = "Node CPU 사용률"
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
            unit = "percent"
            min  = 0
            max  = 100

            color = {
              mode = "palette-classic"
            }

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 10
              gradientMode      = "none"
              showPoints        = "never"
              spanNulls         = false
              axisPlacement     = "auto"
              axisLabel         = ""
              axisColorMode     = "text"

              scaleDistribution = {
                type = "linear"
              }

              stacking = {
                mode  = "none"
                group = "A"
              }

              thresholdsStyle = {
                mode = "off"
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
                  color = "yellow"
                  value = 70
                },
                {
                  color = "red"
                  value = 90
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          legend = {
            displayMode = "list"
            placement   = "bottom"
            calcs       = ["mean", "max"]
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

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "ContainerInsights"
            metricName = "node_cpu_utilization"
            statistic  = "Average"
            period     = "60"
            region     = var.region

            dimensions = {
              ClusterName = var.cluster_name
            }

            matchExact = true
            id         = ""
            label      = "Node CPU"
          }
        ]
      },
      # =====================================================
      # 6. Node 메모리 사용률
      # =====================================================
      {
        id    = 6
        title = "Node 메모리 사용률"
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
            unit = "percent"
            min  = 0
            max  = 100

            color = {
              mode = "palette-classic"
            }

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 10
              gradientMode      = "none"
              showPoints        = "never"
              spanNulls         = false
              axisPlacement     = "auto"
              axisLabel         = ""
              axisColorMode     = "text"

              scaleDistribution = {
                type = "linear"
              }

              stacking = {
                mode  = "none"
                group = "A"
              }

              thresholdsStyle = {
                mode = "off"
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
                  color = "yellow"
                  value = 70
                },
                {
                  color = "red"
                  value = 90
                }
              ]
            }
          }

          overrides = []
        }

        options = {
          legend = {
            displayMode = "list"
            placement   = "bottom"
            calcs       = ["mean", "max"]
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

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "ContainerInsights"
            metricName = "node_memory_utilization"
            statistic  = "Average"
            period     = "60"
            region     = var.region

            dimensions = {
              ClusterName = var.cluster_name
            }

            matchExact = true
            id         = ""
            label      = "Node Memory"
          }
        ]
      },
      # =====================================================
      # 7. Pod 컨테이너 재시작 누적 횟수
      # =====================================================
      {
        id    = 7
        title = "Pod 컨테이너 재시작 누적 횟수"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 8
          w = 24
          x = 0
          y = 12
        }

        fieldConfig = {
          defaults = {
            unit     = "short"
            decimals = 0
            min      = 0

            color = {
              mode = "palette-classic"
            }

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 10
              gradientMode      = "none"
              showPoints        = "auto"
              spanNulls         = false
              axisPlacement     = "auto"
              axisLabel         = ""
              axisColorMode     = "text"

              scaleDistribution = {
                type = "linear"
              }

              stacking = {
                mode  = "none"
                group = "A"
              }

              thresholdsStyle = {
                mode = "off"
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
            calcs       = ["lastNotNull", "max"]
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

            namespace  = "ContainerInsights"
            metricName = "pod_number_of_container_restarts"
            statistic  = "Maximum"
            period     = "60"
            region     = var.region

            dimensions = {
              ClusterName = var.cluster_name
              Namespace   = "*"
              PodName     = "*"
            }

            matchExact = true
            id         = ""
            label      = "{{Namespace}} / {{PodName}}"
          }
        ]
      },
      # =====================================================
      # 8. Pod CPU 사용률 Top 10
      # =====================================================
      {
        id    = 8
        title = "Pod CPU 사용률 Top 10"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 8
          w = 12
          x = 0
          y = 20
        }

        fieldConfig = {
          defaults = {
            unit = "percent"
            min  = 0
            max  = 100

            color = {
              mode = "palette-classic"
            }

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 10
              gradientMode      = "none"
              showPoints        = "never"
              spanNulls         = false
              axisPlacement     = "auto"
              axisLabel         = ""
              axisColorMode     = "text"

              scaleDistribution = {
                type = "linear"
              }

              stacking = {
                mode  = "none"
                group = "A"
              }

              thresholdsStyle = {
                mode = "off"
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
                  color = "yellow"
                  value = 70
                },
                {
                  color = "red"
                  value = 90
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
            calcs       = ["mean", "max"]
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
            metricQueryType  = 1
            metricEditorMode = 1

            region     = var.region
            namespace  = "ContainerInsights"
            metricName = "pod_cpu_utilization"
            period     = "60"

            id    = "podcpu"
            label = ""

            sqlExpression = <<-SQL
              SELECT AVG(pod_cpu_utilization)
              FROM SCHEMA("ContainerInsights", ClusterName, Namespace, PodName)
              WHERE ClusterName = '${var.cluster_name}'
              GROUP BY Namespace, PodName
              ORDER BY AVG() DESC
              LIMIT 10
            SQL
          }
        ]
      },
      # =====================================================
      # 9. Pod 메모리 사용률 Top 10
      # =====================================================
      {
        id    = 9
        title = "Pod 메모리 사용률 Top 10"
        type  = "timeseries"

        datasource = {
          type = "cloudwatch"
          uid  = "cloudwatch"
        }

        gridPos = {
          h = 8
          w = 12
          x = 12
          y = 20
        }

        fieldConfig = {
          defaults = {
            unit = "percent"
            min  = 0
            max  = 100

            color = {
              mode = "palette-classic"
            }

            custom = {
              drawStyle         = "line"
              lineInterpolation = "linear"
              lineWidth         = 2
              fillOpacity       = 10
              gradientMode      = "none"
              showPoints        = "never"
              spanNulls         = false
              axisPlacement     = "auto"
              axisLabel         = ""
              axisColorMode     = "text"

              scaleDistribution = {
                type = "linear"
              }

              stacking = {
                mode  = "none"
                group = "A"
              }

              thresholdsStyle = {
                mode = "off"
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
                  color = "yellow"
                  value = 70
                },
                {
                  color = "red"
                  value = 90
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
            calcs       = ["mean", "max"]
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
            metricQueryType  = 1
            metricEditorMode = 1

            region     = var.region
            namespace  = "ContainerInsights"
            metricName = "pod_memory_utilization"
            period     = "60"

            id    = "podmemory"
            label = ""

            sqlExpression = <<-SQL
              SELECT AVG(pod_memory_utilization)
              FROM SCHEMA("ContainerInsights", ClusterName, Namespace, PodName)
              WHERE ClusterName = '${var.cluster_name}'
              GROUP BY Namespace, PodName
              ORDER BY AVG() DESC
              LIMIT 10
            SQL
          }
        ]
      }
    ]
  })
}
