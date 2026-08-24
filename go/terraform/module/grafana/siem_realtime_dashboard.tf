# =============================================================================
# 05 실시간 사용자 활동 (2026-08-19)
#
# 이 화면이 답하는 질문: "지금 누가 무엇을 하고 있는가"
#
# 왜 Athena가 아니라 CloudWatch인가
#   Athena는 S3에 적재된 뒤를 본다(5~15분 지연). 앱 로그는 Container Insights를
#   거쳐 CloudWatch Logs에 초 단위로 도착하므로, "지금"에 답하려면 이쪽뿐이다.
#   같은 사건이 나중에 04 화면에도 나타나지만, 그때는 관제가 아니라 조사다.
#
# 3계층을 한 화면에 놓는 이유
#   웹서버 / DB / Redis는 각각 남기는 흔적의 성격이 다르다.
#
#     웹서버  APPLICATION_SECURITY_JSON — 최종 사용자까지 식별된다. 가장 풍부하다
#     DB      MariaDB 감사 CONNECT — 다만 앱이 커넥션 풀을 쓰므로 "누가"는
#             최종 사용자가 아니라 DB 계정이다. 이 한계를 패널 설명에 적어둔다
#     Redis   접속 감사 로그가 애초에 없다(ElastiCache 사양). slow-log와
#             AuthenticationFailures 지표로 우회한다
#
#   세 계층을 세로로 쌓아 두면 "어느 계층까지 사용자를 추적할 수 있는가"가
#   화면 자체로 설명된다.
# =============================================================================

locals {

  siem_realtime_dashboard = jsonencode({
    id       = null
    uid      = "gochuchamchi-siem-realtime"
    title    = "05 실시간 사용자 활동"
    timezone = "browser"

    tags = ["security", "siem", "realtime", "cloudwatch"]

    editable      = true
    schemaVersion = 41
    version       = 1

    # CloudWatch는 스캔 과금이 없으므로 새로고침을 켠다 (04와 반대)
    refresh = "1m"

    time = {
      from = "now-1h"
      to   = "now"
    }

    annotations = { list = [] }
    templating  = { list = [] }

    panels = [
      # =====================================================
      # 안내
      # =====================================================
      {
        id      = 1
        title   = ""
        type    = "text"
        gridPos = { h = 3, w = 24, x = 0, y = 0 }

        options = {
          mode = "markdown"
          content = join("\n", [
            "### 실시간 관제 — 웹서버 · DB · Redis",
            "",
            "CloudWatch Logs 기반이라 **지연이 초 단위**입니다. 소스 간 상관 분석과 과거 조사는 `04 SIEM 통합 검색`에서 수행하세요.",
            "",
            "추적 가능 범위: 웹서버 = 최종 사용자 / DB = 커넥션 풀 계정(최종 사용자 아님) / Redis = 접속 감사 로그 없음(지표·slow-log로 대체)"
          ])
        }
      },

      # =====================================================
      # 1행 — 즉시 지표 (메트릭 필터 기반, 1분 해상도)
      # =====================================================
      {
        id      = 2
        title   = "보안 신호 (실시간)"
        type    = "timeseries"
        gridPos = { h = 7, w = 16, x = 0, y = 3 }

        description = "CloudWatch 메트릭 필터가 앱 로그 도착 즉시 집계한 값. 알람도 같은 지표를 본다."

        datasource = local.cloudwatch_datasource_ref

        fieldConfig = {
          defaults = {
            custom = {
              drawStyle   = "bars"
              fillOpacity = 60
              stacking    = { mode = "normal", group = "A" }
            }
            min = 0
          }
          overrides = []
        }

        options = {
          legend  = { displayMode = "list", placement = "bottom", showLegend = true }
          tooltip = { mode = "multi", sort = "desc" }
        }

        targets = [
          for idx, metric in [
            "LoginFailureCount",
            "AccessDeniedCount",
            "Http4xxCount",
            "Http5xxCount",
            "HighSecurityEventCount"
            ] : {
            refId      = "M${idx}"
            datasource = local.cloudwatch_datasource_ref

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "Gochuchamchi/ApplicationSecurity"
            metricName = metric
            statistic  = "Sum"
            period     = "60"
            region     = var.region

            dimensions = {}
            matchExact = true
            id         = ""
            expression = ""
            label      = metric
          }
        ]
      },

      {
        id      = 3
        title   = "Redis 접근"
        type    = "timeseries"
        gridPos = { h = 7, w = 8, x = 16, y = 3 }

        description = "AuthenticationFailures는 정상 상태에서 0이어야 한다. 값이 오르면 EKS 노드 안의 무언가가 잘못된 토큰으로 세션 저장소에 붙으려 한 것 — 측면이동 시도의 직접 증거."

        datasource = local.cloudwatch_datasource_ref

        fieldConfig = {
          defaults = { min = 0 }

          overrides = [
            {
              matcher = { id = "byName", options = "AuthenticationFailures" }
              properties = [
                { id = "color", value = { mode = "fixed", fixedColor = "red" } },
                { id = "custom.lineWidth", value = 2 }
              ]
            }
          ]
        }

        options = {
          legend  = { displayMode = "list", placement = "bottom", showLegend = true }
          tooltip = { mode = "multi" }
        }

        targets = [
          for idx, metric in [
            "AuthenticationFailures",
            "CurrConnections",
            "NewConnections"
            ] : {
            refId      = "R${idx}"
            datasource = local.cloudwatch_datasource_ref

            queryMode        = "Metrics"
            metricQueryType  = 0
            metricEditorMode = 0

            namespace  = "AWS/ElastiCache"
            metricName = metric
            statistic  = metric == "CurrConnections" ? "Maximum" : "Sum"
            period     = "60"
            region     = var.region

            dimensions = {
              ReplicationGroupId = var.redis_replication_group_id
            }

            matchExact = true
            id         = ""
            expression = ""
            label      = metric
          }
        ]
      },

      # =====================================================
      # 2행 — 웹서버: 현재 활동 중인 사용자
      # =====================================================
      {
        id      = 4
        title   = "웹서버 — 현재 활동 중인 사용자"
        type    = "table"
        gridPos = { h = 9, w = 12, x = 0, y = 10 }

        description = "선택한 시간 범위 안에서 요청을 보낸 주체. principal은 인증된 사용자명이고, 비어 있으면 비로그인 트래픽이다."

        datasource = local.cloudwatch_datasource_ref

        # stats로 집계한 max(@timestamp)는 시간 타입이 아니라 숫자(epoch ms)로
        # 돌아온다. 그대로 두면 "1787125926000" 같은 값이 표에 찍히므로
        # 필드 단위로 시간 표시를 지정한다.
        fieldConfig = {
          defaults = {}

          overrides = [
            {
              matcher = { id = "byName", options = "last_seen_ms" }
              properties = [
                { id = "unit", value = "dateTimeAsLocal" },
                { id = "displayName", value = "마지막 활동" }
              ]
            }
          ]
        }

        options = { showHeader = true, footer = { show = false } }

        targets = [
          {
            refId      = "A"
            datasource = local.cloudwatch_datasource_ref

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            # Container Insights가 JSON 라인을 log_processed로 파싱해 주는 경우와
            # 최상위에 그대로 두는 경우가 섞인다. application-security-monitoring.tf의
            # 메트릭 필터가 두 형태를 모두 거는 것과 같은 이유로 coalesce를 쓴다.
            expression = <<-QUERY
              fields coalesce(log_processed.principal, principal, log_processed.actorUsername, actorUsername) as actor_name,
                     coalesce(log_processed.clientIp, clientIp) as client_ip,
                     coalesce(log_processed.uri, uri) as req_uri
              | filter coalesce(log_processed.eventCategory, eventCategory) = "HTTP_ACCESS"
              | filter ispresent(actor_name)
              | stats count(*) as requests,
                      count_distinct(req_uri) as paths,
                      max(@timestamp) as last_seen_ms
                      by actor_name, client_ip
              | sort last_seen_ms desc
              | limit 50
            QUERY

            logGroups = [
              {
                name = local.siem_log_groups.application.name
                arn  = local.siem_log_groups.application.arn
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
      # 2행 — 웹서버: 인증·인가 실패
      # =====================================================
      {
        id      = 5
        title   = "웹서버 — 인증·인가 실패"
        type    = "table"
        gridPos = { h = 9, w = 12, x = 12, y = 10 }

        description = "로그인 실패, 접근 거부, 차단. reasonCode에 거부 사유가 들어 있다."

        datasource = local.cloudwatch_datasource_ref

        options = { showHeader = true, footer = { show = false } }

        targets = [
          {
            refId      = "A"
            datasource = local.cloudwatch_datasource_ref

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            expression = <<-QUERY
              fields @timestamp,
                     coalesce(log_processed.eventType, eventType) as event,
                     coalesce(log_processed.actorUsername, actorUsername, log_processed.principal, principal) as user,
                     coalesce(log_processed.clientIp, clientIp) as client_ip,
                     coalesce(log_processed.uri, uri) as uri,
                     coalesce(log_processed.reasonCode, reasonCode) as reason,
                     coalesce(log_processed.severity, severity) as severity
              | filter coalesce(log_processed.eventCategory, eventCategory) = "SECURITY_EVENT"
              | filter coalesce(log_processed.outcome, outcome) = "FAILURE"
                    or event in ["ACCESS_DENIED", "ACCESS_BLOCKED"]
              | sort @timestamp desc
              | limit 100
            QUERY

            logGroups = [
              {
                name = local.siem_log_groups.application.name
                arn  = local.siem_log_groups.application.arn
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
      # 3행 — 권한 변경 (CRITICAL 축)
      # =====================================================
      {
        id      = 6
        title   = "웹서버 — 권한·계정 상태 변경"
        type    = "table"
        gridPos = { h = 8, w = 12, x = 0, y = 19 }

        description = "역할 변경·정지·비밀번호 변경. StructuredApplicationLogService가 CRITICAL/HIGH로 분류하는 이벤트들이며, 계정 탈취 후 가장 먼저 나타나는 흔적이다."

        datasource = local.cloudwatch_datasource_ref

        options = { showHeader = true, footer = { show = false } }

        targets = [
          {
            refId      = "A"
            datasource = local.cloudwatch_datasource_ref

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            expression = <<-QUERY
              fields @timestamp,
                     coalesce(log_processed.eventType, eventType) as event,
                     coalesce(log_processed.actorUsername, actorUsername) as actor,
                     coalesce(log_processed.targetType, targetType) as target_type,
                     coalesce(log_processed.targetId, targetId) as target_id,
                     coalesce(log_processed.outcome, outcome) as outcome,
                     coalesce(log_processed.clientIp, clientIp) as client_ip
              | filter coalesce(log_processed.severity, severity) in ["HIGH", "CRITICAL"]
              | sort @timestamp desc
              | limit 100
            QUERY

            logGroups = [
              {
                name = local.siem_log_groups.application.name
                arn  = local.siem_log_groups.application.arn
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
      # 3행 — DB 접속
      # =====================================================
      {
        id      = 7
        title   = "DB — 접속 이벤트"
        type    = "table"
        gridPos = { h = 8, w = 12, x = 12, y = 19 }

        description = "MariaDB 감사 플러그인의 CONNECT 이벤트. ⚠️ 앱이 커넥션 풀을 사용하므로 dbuser는 최종 사용자가 아니라 DB 계정이다. 최종 사용자 추적은 위 웹서버 패널을 볼 것. srchost가 예상 밖(EKS 파드 대역이 아닌 곳)이면 그것이 신호다."

        datasource = local.cloudwatch_datasource_ref

        options = { showHeader = true, footer = { show = false } }

        targets = [
          {
            refId      = "A"
            datasource = local.cloudwatch_datasource_ref

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            # MariaDB 감사 로그는 CSV 한 줄이다:
            #   timestamp,serverhost,username,host,connectionid,queryid,operation,database,object,retcode
            # 글롭 파싱이 정규식보다 포맷 변화에 관대해서 이쪽을 쓴다.
            # retcode != 0 이 인증 실패다.
            #
            # ⚠️ 출력 필드는 fields가 아니라 display로 투영한다. parse가 이미 정의한
            #    dbuser 등을 fields로 다시 나열하면 CloudWatch가 "Ephemeral field is
            #    already defined: dbuser"로 쿼리를 400 거부한다(2026-08-19 실측 — 이
            #    패널이 계속 빨간 에러였던 원인). display는 재정의 없이 투영만 한다.
            expression = <<-QUERY
              parse @message "*,*,*,*,*,*,*,*,*,*" as ts, serverhost, dbuser, srchost, connid, queryid, operation, dbname, object, retcode
              | filter operation like /CONNECT|DISCONNECT|FAILED_CONNECT/
              | sort @timestamp desc
              | limit 100
              | display @timestamp, dbuser, srchost, operation, dbname, retcode
            QUERY

            logGroups = [
              {
                name = local.siem_log_groups.rds_audit.name
                arn  = local.siem_log_groups.rds_audit.arn
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
      # 4행 — Redis slow-log
      # =====================================================
      {
        id      = 8
        title   = "Redis — 느린 명령 (slow-log)"
        type    = "table"
        gridPos = { h = 8, w = 24, x = 0, y = 27 }

        description = "ElastiCache는 접속 감사 로그를 제공하지 않는다. slow-log는 임계를 넘긴 명령만 남지만, KEYS *·대량 스캔 같은 비정상 사용은 거의 항상 여기 걸린다 — 감사 로그가 없는 환경에서 이상 사용을 잡는 사실상 유일한 로그 축이다. ClientAddress로 어느 파드에서 왔는지 추적한다."

        datasource = local.cloudwatch_datasource_ref

        options = { showHeader = true, footer = { show = false } }

        targets = [
          {
            refId      = "A"
            datasource = local.cloudwatch_datasource_ref

            queryMode     = "Logs"
            queryLanguage = "CWLI"
            region        = var.region

            # log_format = "json"으로 보내고 있어 필드가 그대로 잡힌다(redis.tf 참조).
            # text로 보내면 여기에 parse 구문이 필요해지고 포맷 변경에 취약해진다.
            expression = <<-QUERY
              fields @timestamp, CacheClusterId, ClientAddress, ClientName, Command, Duration
              | sort Duration desc
              | limit 50
            QUERY

            logGroups = [
              {
                name = local.siem_log_groups.redis_slow.name
                arn  = local.siem_log_groups.redis_slow.arn
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
