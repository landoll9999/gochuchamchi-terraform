# =============================================================================
# SIEM 대시보드 2종 (2026-08-19)
#
#   04 통합 검색       Athena / security_events 뷰 — 7개 소스를 한 화면에서 조사
#   05 실시간 사용자 활동  CloudWatch — 웹서버·DB·Redis에 지금 무슨 일이 있는가
#
# 왜 두 장으로 나누나 — 지연이 다르기 때문이다
#   조사(04)는 S3에 도착한 로그를 본다. CloudTrail 최대 15분, ALB 5분 간격이라
#   구조적으로 "방금"을 볼 수 없다. 대신 7개 소스를 가로질러 상관을 볼 수 있다.
#
#   관제(05)는 CloudWatch Logs를 본다. 앱 로그는 초 단위로 도착하므로 "지금
#   누가 접속해 있는가"에 답한다. 대신 소스 간 상관은 못 한다.
#
#   이 둘을 한 대시보드에 섞으면 보는 사람이 "왜 여기엔 있고 저기엔 없지"로
#   혼란에 빠진다. 화면을 나누는 것이 곧 지연 차이를 설명하는 것이다.
#
# ⚠️ 04는 자동 새로고침을 켜지 않는다
#   워크그룹에 쿼리당 1 GiB 스캔 상한이 걸려 있다(log-archive/athena.tf).
#   refresh를 켜면 대시보드를 열어둔 것만으로 스캔이 반복된다. 대신 Athena의
#   result reuse(5분)를 켜서 같은 쿼리 재실행은 과금 없이 캐시에서 온다.
#   05는 CloudWatch라 새로고침을 켜도 비용이 사실상 0이다.
# =============================================================================

variable "athena_datasource_uid" {
  description = "Grafana Athena 데이터소스 UID (main.tf의 datasources에서 지정한 값)"
  type        = string
  default     = "athena"
}

variable "athena_database" {
  description = "security_events 뷰가 있는 Glue 데이터베이스 이름"
  type        = string
  default     = "gochuchamchi_security_logs"
}

variable "athena_catalog" {
  description = "Athena 데이터 카탈로그 이름"
  type        = string
  default     = "AwsDataCatalog"
}

variable "redis_replication_group_id" {
  description = "Redis 지표 조회용 ElastiCache 복제 그룹 ID"
  type        = string
  default     = "gochuchamchi-redis"
}

variable "redis_slow_log_group_name" {
  description = "Redis slow-log CloudWatch 로그 그룹 이름"
  type        = string
  default     = "/aws/elasticache/gochuchamchi-redis/slow-log"
}


locals {
  # ---------------------------------------------------------------------------
  # 로그 그룹 ARN — CloudWatch Logs Insights 패널은 name과 arn을 함께 요구한다.
  # (dashboard.tf의 application_log_group_arn과 같은 조립 방식)
  # ---------------------------------------------------------------------------
  siem_log_group_arn_prefix = join("", [
    "arn:aws:logs:",
    var.region,
    ":",
    data.aws_caller_identity.current.account_id,
    ":log-group:"
  ])

  rds_audit_log_group_name = "/aws/rds/instance/${var.rds_identifier}/audit"

  siem_log_groups = {
    application = {
      name = local.application_log_group_name
      arn  = "${local.siem_log_group_arn_prefix}${local.application_log_group_name}:*"
    }

    rds_audit = {
      name = local.rds_audit_log_group_name
      arn  = "${local.siem_log_group_arn_prefix}${local.rds_audit_log_group_name}:*"
    }

    redis_slow = {
      name = var.redis_slow_log_group_name
      arn  = "${local.siem_log_group_arn_prefix}${var.redis_slow_log_group_name}:*"
    }
  }

  # ---------------------------------------------------------------------------
  # Athena 쿼리 공통 인자
  #
  # resultReuseEnabled — 같은 SQL을 5분 안에 다시 던지면 Athena가 이전 결과를
  # 그대로 돌려주고 과금하지 않는다. 대시보드는 같은 쿼리를 반복해서 던지는
  # 패턴이라 이 옵션의 효과가 크다. 5분으로 둔 이유는 그보다 길게 잡으면
  # "새로고침했는데 값이 안 변한다"는 혼란이 생기기 때문.
  # ---------------------------------------------------------------------------
  athena_connection_args = {
    catalog                    = var.athena_catalog
    database                   = var.athena_database
    region                     = "__default"
    resultReuseEnabled         = true
    resultReuseMaxAgeInMinutes = 5
  }

  athena_datasource_ref = {
    type = "grafana-athena-datasource"
    uid  = var.athena_datasource_uid
  }

  cloudwatch_datasource_ref = {
    type = "cloudwatch"
    uid  = "cloudwatch"
  }

  # ---------------------------------------------------------------------------
  # 검색 조건 WHERE 절 — 04 대시보드의 여러 패널이 같은 필터를 공유한다.
  #
  # $${...}는 Terraform 이스케이프다. 렌더링 결과가 Grafana 변수 ${...}가 된다.
  # 빈 문자열 비교로 "입력 안 하면 조건 무시"를 만든다 — Grafana에는 조건부
  # SQL 조립 기능이 없어서 이 방식이 표준 관용구다.
  #
  # ⚠️ 포맷은 반드시 :sqlstring 이다. :singlequote 는 작은따옴표를 \' 로 이스케이프하는데
  #    Trino(Athena)는 '' 를 쓴다. 즉 singlequote 로 두면 검색어에 아포스트로피가
  #    하나만 들어가도(O'Brien, can't 등) 쿼리가 통째로 실패한다.
  #    sqlstring 은 따옴표까지 붙여주므로 템플릿 쪽에 '' 를 따로 감싸지 않는다.
  # ---------------------------------------------------------------------------
  siem_search_where = <<-SQL
    WHERE event_time >= current_timestamp - INTERVAL '$${hours}' HOUR
      AND source_type IN ($${source_type:sqlstring})
      AND outcome IN ($${outcome:sqlstring})
      AND ($${src_ip:sqlstring} = '' OR source_ip = $${src_ip:sqlstring})
      AND ($${actor:sqlstring} = '' OR lower(COALESCE(actor, '')) LIKE lower(concat('%', $${actor:sqlstring}, '%')))
      AND ($${q:sqlstring} = '' OR (
            lower(COALESCE(action, ''))    LIKE lower(concat('%', $${q:sqlstring}, '%'))
         OR lower(COALESCE(target, ''))    LIKE lower(concat('%', $${q:sqlstring}, '%'))
         OR lower(COALESCE(detail, ''))    LIKE lower(concat('%', $${q:sqlstring}, '%'))
         OR lower(COALESCE(actor, ''))     LIKE lower(concat('%', $${q:sqlstring}, '%'))
         OR lower(COALESCE(source_ip, '')) LIKE lower(concat('%', $${q:sqlstring}, '%'))
      ))
  SQL


  # ===========================================================================
  # 04 — SIEM 통합 검색 (Athena)
  # ===========================================================================
  siem_search_dashboard = jsonencode({
    id       = null
    uid      = "gochuchamchi-siem-search"
    title    = "04 SIEM 통합 검색"
    timezone = "browser"

    tags = ["security", "siem", "athena", "search"]

    editable      = true
    schemaVersion = 41
    version       = 1

    # 자동 새로고침 없음 — 위 주석의 스캔 상한 참고
    refresh = ""

    time = {
      from = "now-24h"
      to   = "now"
    }

    annotations = { list = [] }

    # -------------------------------------------------------------------------
    # 변수 — 현업이 LogQL/SQL을 모르고도 조사할 수 있게 하는 층.
    # 이 화면의 목적 자체가 "쿼리를 감추는 것"이다.
    # -------------------------------------------------------------------------
    templating = {
      list = [
        {
          name    = "hours"
          label   = "조회 기간"
          type    = "custom"
          query   = "1,6,24,72,168"
          current = { text = "24", value = "24" }
          options = [
            { text = "1시간", value = "1", selected = false },
            { text = "6시간", value = "6", selected = false },
            { text = "24시간", value = "24", selected = true },
            { text = "3일", value = "72", selected = false },
            { text = "7일", value = "168", selected = false }
          ]
          includeAll = false
          multi      = false
        },
        {
          name  = "source_type"
          label = "로그 소스"
          type  = "custom"
          query = "cloudtrail,vpc_flow,waf,alb,application,rds,eks"
          # 기본값을 전체로 두는 것이 중요하다. 통합 검색의 요점이
          # "어느 소스에 있는지 모를 때 찾는 것"이기 때문.
          current = {
            text  = ["All"]
            value = ["$__all"]
          }
          options    = []
          includeAll = true

          # allValue를 지정하지 않는다. Grafana는 커스텀 allValue에는 포맷 지정자
          # (:singlequote)를 적용하지 않아서, IN 절의 따옴표가 깨진다.
          # 비워 두면 All 선택 시 전체 옵션이 포맷과 함께 전개된다.
          multi = true
        },
        {
          name       = "outcome"
          label      = "결과"
          type       = "custom"
          query      = "success,failure,blocked,unknown"
          current    = { text = ["All"], value = ["$__all"] }
          options    = []
          includeAll = true
          multi      = true
        },
        {
          name    = "q"
          label   = "키워드"
          type    = "textbox"
          query   = ""
          current = { text = "", value = "" }
          options = []
        },
        {
          name    = "src_ip"
          label   = "출발지 IP (정확히 일치)"
          type    = "textbox"
          query   = ""
          current = { text = "", value = "" }
          options = []
        },
        {
          name    = "actor"
          label   = "주체 (부분 일치)"
          type    = "textbox"
          query   = ""
          current = { text = "", value = "" }
          options = []
        }
      ]
    }

    panels = [
      # =====================================================
      # 0. 사용 안내
      # =====================================================
      {
        id      = 1
        title   = ""
        type    = "text"
        gridPos = { h = 3, w = 24, x = 0, y = 0 }

        options = {
          mode = "markdown"
          content = join("\n", [
            "### 통합 로그 검색 — CloudTrail · VPC Flow · WAF · ALB · Application · RDS · EKS",
            "",
            "7개 로그 소스가 **하나의 공통 스키마**로 정규화되어 있어, 소스마다 다른 필드 이름(`sourceipaddress` / `srcaddr` / `clientip` …)을 몰라도 한 번에 검색됩니다.",
            "",
            "**지연 안내** — 이 화면은 S3에 적재된 로그를 조회합니다(5~15분 지연). *지금 이 순간*을 보려면 `05 실시간 사용자 활동`으로 이동하세요."
          ])
        }
      },

      # =====================================================
      # 1. 소스별 이벤트 수
      # =====================================================
      {
        id      = 2
        title   = "소스별 이벤트 수"
        type    = "barchart"
        gridPos = { h = 7, w = 8, x = 0, y = 3 }

        datasource = local.athena_datasource_ref

        fieldConfig = {
          defaults = {
            custom = { axisPlacement = "auto", fillOpacity = 80 }
          }
          overrides = []
        }

        options = {
          orientation        = "horizontal"
          xTickLabelRotation = 0
          legend             = { showLegend = false }
        }

        targets = [
          {
            refId          = "A"
            datasource     = local.athena_datasource_ref
            format         = 1
            connectionArgs = local.athena_connection_args

            rawSQL = <<-SQL
              SELECT
                source_type,
                COUNT(*) AS events
              FROM "${var.athena_database}"."security_events"
              ${local.siem_search_where}
              GROUP BY source_type
              ORDER BY events DESC
            SQL
          }
        ]
      },

      # =====================================================
      # 2. 상위 출발지 IP
      # =====================================================
      {
        id      = 3
        title   = "상위 출발지 IP"
        type    = "table"
        gridPos = { h = 7, w = 8, x = 8, y = 3 }

        datasource = local.athena_datasource_ref

        options = {
          showHeader = true
          footer     = { show = false }
        }

        targets = [
          {
            refId          = "A"
            datasource     = local.athena_datasource_ref
            format         = 1
            connectionArgs = local.athena_connection_args

            # 여러 계층에 동시에 나타나는 IP가 위로 오게 정렬한다.
            # siem-detection-rules.tf의 교차계층 룰과 같은 관점을 수동 조사에서도
            # 쓸 수 있게 한 것.
            rawSQL = <<-SQL
              SELECT
                source_ip,
                COUNT(*)                            AS events,
                COUNT(DISTINCT source_type)         AS layers,
                SUM(CASE WHEN outcome IN ('failure', 'blocked') THEN 1 ELSE 0 END) AS denied
              FROM "${var.athena_database}"."security_events"
              ${local.siem_search_where}
                AND source_ip IS NOT NULL
              GROUP BY source_ip
              ORDER BY layers DESC, denied DESC, events DESC
              LIMIT 20
            SQL
          }
        ]
      },

      # =====================================================
      # 3. 상위 주체
      # =====================================================
      {
        id      = 4
        title   = "상위 주체 (계정 · 역할)"
        type    = "table"
        gridPos = { h = 7, w = 8, x = 16, y = 3 }

        datasource = local.athena_datasource_ref

        options = {
          showHeader = true
          footer     = { show = false }
        }

        targets = [
          {
            refId          = "A"
            datasource     = local.athena_datasource_ref
            format         = 1
            connectionArgs = local.athena_connection_args

            rawSQL = <<-SQL
              SELECT
                actor,
                COUNT(*)                            AS events,
                SUM(CASE WHEN outcome IN ('failure', 'blocked') THEN 1 ELSE 0 END) AS denied,
                MAX(event_time)                     AS last_seen
              FROM "${var.athena_database}"."security_events"
              ${local.siem_search_where}
                AND actor IS NOT NULL
              GROUP BY actor
              ORDER BY denied DESC, events DESC
              LIMIT 20
            SQL
          }
        ]
      },

      # =====================================================
      # 4. 검색 결과 — 이 대시보드의 본체
      # =====================================================
      {
        id      = 5
        title   = "검색 결과 (최근순 500건)"
        type    = "table"
        gridPos = { h = 16, w = 24, x = 0, y = 10 }

        description = "행을 CSV로 내보내려면 패널 메뉴 > Inspect > Data > Download CSV"

        datasource = local.athena_datasource_ref

        fieldConfig = {
          defaults = {
            custom = {
              align       = "auto"
              cellOptions = { type = "auto", wrapText = false }
              filterable  = true
            }
          }

          overrides = [
            {
              matcher = { id = "byName", options = "outcome" }
              properties = [
                {
                  id    = "custom.cellOptions"
                  value = { type = "color-background", mode = "basic" }
                },
                {
                  id = "mappings"
                  value = [
                    {
                      type = "value"
                      options = {
                        success = { color = "green", index = 0, text = "success" }
                        failure = { color = "red", index = 1, text = "failure" }
                        blocked = { color = "orange", index = 2, text = "blocked" }
                        unknown = { color = "text", index = 3, text = "unknown" }
                      }
                    }
                  ]
                }
              ]
            }
          ]
        }

        options = {
          showHeader = true
          footer     = { show = false }
          sortBy     = []
        }

        targets = [
          {
            refId          = "A"
            datasource     = local.athena_datasource_ref
            format         = 1
            connectionArgs = local.athena_connection_args

            rawSQL = <<-SQL
              SELECT
                event_time,
                source_type,
                source_ip,
                actor,
                action,
                target,
                outcome,
                detail
              FROM "${var.athena_database}"."security_events"
              ${local.siem_search_where}
              ORDER BY event_time DESC
              LIMIT 500
            SQL
          }
        ]
      }
    ]
  })
}
