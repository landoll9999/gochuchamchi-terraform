# =============================================================================
# 통합 보안 이벤트 뷰 — 5개 로그 테이블을 공통 스키마 하나로 (2026-08-12)
#
# 왜 필요한가 (멘토 조언: "먼저 어떤 필드/항목을 볼지 정의해야 함")
#   지금 테이블 5개는 같은 개념을 전부 다른 이름으로 부른다. "출발지 IP" 하나가
#   cloudtrail=sourceipaddress / flow=srcaddr / waf=httprequest.clientip /
#   alb=client_ip / app=clientip 다. 그래서 "이 IP가 어디어디에 나타났나"를
#   물으려면 쿼리를 4~5개 손으로 써야 하고, 그게 관제를 못 하게 만든다.
#   SIEM 제품이 파는 것의 본질이 이 통일(정규화) 작업이다. 여기서는 그걸
#   Athena 뷰 한 장으로 직접 만든다.
#
# 공통 스키마 8필드 — 조사에서 실제로 피벗하는 축만 남겼다
#   event_time / source_type / source_ip / actor / action / target / outcome / detail
#
# ⚠️ 비용 설계가 이 파일의 핵심이다
#   워크그룹에 쿼리당 1 GiB 스캔 상한이 걸려 있다(athena.tf). 5개 테이블을 그냥
#   UNION ALL 하면 파티션 프루닝이 안 돼서 상한에 즉시 걸린다. 그래서 시간창을
#   **뷰 정의 안에** 넣고, 각 분기가 자기 테이블의 네이티브 파티션 컬럼으로
#   직접 필터하게 했다. 호출자는 날짜 조건을 몰라도 되고, 잊어서 요금이 튀는
#   일도 구조적으로 막힌다.
#
#   프루닝이 되려면 파티션 컬럼에 "단순 비교"가 걸려야 한다. concat(year,month,day)
#   같은 계산식은 프루닝되지 않으므로, y/m/d 테이블은 (year=... AND month=...
#   AND day=...) 트리플을 날짜 수만큼 OR로 나열한다 — application-logs-analytics.tf의
#   application_recent_partition과 같은 관용구이고, 여기서는 창 크기에 맞춰
#   Terraform이 생성한다.
#
# 뷰가 두 장인 이유 (2026-08-12 SIEM 탐지 계층 추가로 분리)
#   조사(사람)와 탐지(스케줄 Lambda)는 요구가 정반대다.
#
#     security_events         조사용 — 7일 / 5개 소스 전부.
#                             사람이 사고를 되짚을 때는 넓어야 한다. 하루에
#                             몇 번 안 도니 스캔량이 커도 된다.
#
#     security_events_recent  탐지용 — 2일 / vpc_flow 제외.
#                             siem-detector Lambda가 한 시간마다 룰 전부를
#                             여기에 던진다. 7일짜리를 시간마다 훑으면 스캔량이
#                             7배가 되고 1 GiB 상한에 걸려 **탐지가 조용히
#                             실패한다** — SIEM에서 제일 나쁜 고장이다.
#
#   탐지용에서 vpc_flow를 뺀 이유는 두 가지다. (1) 원시 용량이 압도적으로
#   커서 시간당 스캔의 대부분을 혼자 차지한다. (2) flow 레코드에는 인증 주체가
#   없고 srcaddr도 대부분 내부 ENI라, "같은 IP가 여러 계층에 나타났나" 같은
#   상관 판단에 기여하는 정보가 거의 없다. 대신 flow가 실제로 필요한 룰
#   (데이터 반출 의심)은 siem-detection-rules.tf에서 **원본 테이블을 직접**
#   조회한다 — bytes 합계는 어차피 정규화된 detail 문자열로는 못 구한다.
#
#   창 길이가 2일인 이유: 파티션 단위가 하루라 프루닝 최소 단위도 하루다.
#   1일로 잡으면 UTC 자정 직후 룰의 lookback(기본 60분)이 어제 파티션을
#   가리키는데 뷰에는 그 파티션이 없어 탐지에 구멍이 생긴다.
#
# 뷰 생성 방법 — Terraform은 Athena 뷰를 직접 만들 수 없다
#   Glue의 VIRTUAL_VIEW로 우겨넣는 방법이 있지만 base64 인코딩된 Presto 메타데이터를
#   손으로 관리해야 해서 엔진 버전이 바뀌면 조용히 깨진다. 그래서 저장 쿼리
#   "00-create-security-events-view"로 두고 콘솔에서 한 번 실행한다.
#   CREATE OR REPLACE 라서 몇 번 돌려도 무해하다.
#   ‼️ 이 파일을 고쳤으면 apply 후 그 쿼리를 다시 실행해야 뷰에 반영된다.
#
#   단, **탐지용 뷰는 손으로 안 돌려도 된다.** siem-detector Lambda가 매 실행
#   앞머리에서 두 뷰의 CREATE OR REPLACE를 먼저 돌린다(DDL이라 스캔 0바이트 =
#   무료). 사람이 잊어서 탐지가 죽는 경로를 없애기 위한 것이고, 결과적으로
#   조사용 뷰도 한 시간 안에 자동으로 최신화된다. 위의 "손으로 한 번"은
#   Lambda 없이 뷰만 먼저 쓰고 싶을 때의 경로로 남긴다.
# =============================================================================

variable "security_events_window_days" {
  description = <<-EOT
    조사용 통합 뷰(security_events)가 커버하는 시간창(일). 뷰 정의에 박히므로 이
    값이 곧 쿼리당 스캔량 상한을 결정한다. 늘리면 y/m/d 테이블의 OR 절이 그만큼
    길어지고 스캔량도 비례해 는다. 이보다 오래된 로그는 소스별 저장 쿼리로 조회할 것.
  EOT
  type        = number
  default     = 7

  validation {
    condition     = var.security_events_window_days >= 1 && var.security_events_window_days <= 31
    error_message = "security_events_window_days는 1~31 사이여야 합니다(그 이상은 통합 뷰가 아니라 소스별 쿼리로)."
  }
}

variable "security_events_detection_window_days" {
  description = <<-EOT
    탐지용 뷰(security_events_recent)가 커버하는 시간창(일). 스케줄 탐지가 매
    실행마다 이만큼을 스캔하므로 SIEM 운영비를 사실상 이 값이 정한다. 룰의
    lookback(siem_rule_lookback_minutes)보다 넉넉해야 UTC 자정 경계에서 구멍이
    안 생긴다 — 파티션 단위가 하루라 최소 2일이 안전선이다.
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.security_events_detection_window_days >= 2 && var.security_events_detection_window_days <= 7
    error_message = "security_events_detection_window_days는 2~7 사이여야 합니다(1일은 자정 경계에서 탐지 누락, 7일 초과는 시간당 스캔 비용이 조사용 뷰를 넘어섬)."
  }
}


locals {
  security_events_view_name           = "security_events"
  security_events_detection_view_name = "security_events_recent"

  security_events_database = aws_glue_catalog_database.security_logs.name

  # ---------------------------------------------------------------------------
  # 뷰 목록 — 이름 => { 시간창, 포함할 소스 }
  # 여기에 한 줄 추가하면 뷰가 하나 더 생긴다. SQL은 아래 분기 템플릿을 재사용하므로
  # 두 뷰가 서로 다른 정규화 규칙을 갖는 일(= 조사와 탐지의 판단이 갈리는 사고)이
  # 구조적으로 불가능하다.
  # ---------------------------------------------------------------------------
  security_events_views = {
    (local.security_events_view_name) = {
      days    = var.security_events_window_days
      sources = ["cloudtrail", "vpc_flow", "waf", "alb", "application"]
    }

    (local.security_events_detection_view_name) = {
      days    = var.security_events_detection_window_days
      sources = ["cloudtrail", "waf", "alb", "application"]
    }
  }

  # ---------------------------------------------------------------------------
  # 뷰별 치환 값
  #
  #   date_floor  날짜형 프로젝션(cloudtrail / vpc_flow / alb)용.
  #               projection.type = date, format = yyyy/MM/dd 라 범위 비교가
  #               그대로 프루닝된다. athena.tf의 기존 저장 쿼리와 같은 표현식.
  #
  #   ymd_window  정수형 프로젝션(waf / application)용. year/month/day가 별도
  #               컬럼(제로패딩 문자열)이라 범위 비교로는 프루닝이 안 된다.
  #               창에 포함되는 날짜만큼 등식 트리플을 OR로 나열한다.
  #               current_timestamp는 쿼리 시점에 평가되므로 뷰는 계속
  #               "최근 N일"로 굴러간다.
  #
  # ※ 두 방식의 커버 범위가 하루 어긋난다(date_floor는 >= 라서 N+1일, ymd는 N일).
  #   프루닝 방식이 달라서 생기는 구조적 차이고, 탐지 쪽은 어느 쪽이든 lookback
  #   보다 넉넉하므로 무해하다. 맞추려고 식을 비틀면 프루닝이 깨진다.
  # ---------------------------------------------------------------------------
  security_events_template_vars = {
    for view_name, cfg in local.security_events_views : view_name => {
      db     = local.security_events_database
      region = var.region

      t_cloudtrail  = aws_glue_catalog_table.cloudtrail.name
      t_vpc_flow    = aws_glue_catalog_table.vpc_flow_logs.name
      t_waf         = aws_glue_catalog_table.waf_logs.name
      t_alb         = aws_glue_catalog_table.alb_access_logs.name
      t_application = aws_glue_catalog_table.application_logs.name

      date_floor = "date_format(current_date - INTERVAL '${cfg.days}' DAY, '%Y/%m/%d')"

      ymd_window = join("\n        OR ", [
        for d in range(cfg.days) :
        "(year = date_format(current_timestamp - INTERVAL '${d}' DAY, '%Y') AND month = date_format(current_timestamp - INTERVAL '${d}' DAY, '%m') AND day = date_format(current_timestamp - INTERVAL '${d}' DAY, '%d'))"
      ])
    }
  }

  # ===========================================================================
  # 소스별 SELECT 분기 템플릿
  #
  # ‼️ 여기 안의 $${...} 는 Terraform이 아니라 아래 templatestring()이 치환한다.
  #    (heredoc에서 $$ 는 리터럴 $ 로 남는다.) 뷰마다 시간창이 달라 한 번 더
  #    렌더링하는 구조라서 이렇게 두 단계다. 값이 뷰에 따라 안 변하는 것까지
  #    전부 템플릿 변수로 통일해 뒀다 — 한 heredoc 안에 즉시 치환과 지연 치환이
  #    섞이면 읽는 사람이 반드시 헷갈린다.
  #
  # 타입 통일 규칙 (UNION ALL은 위치 기준이라 어긋나면 바로 실패한다)
  #   - event_time: from_iso8601_timestamp는 timestamp WITH TIME ZONE을 돌려주고
  #     from_unixtime은 WITHOUT을 돌려준다. 전부 CAST(... AS timestamp)로 맞춘다.
  #     (Athena 세션 타임존은 UTC. 파티션 경로도 UTC 기준이라 서로 맞다.)
  #     ※ 이 뷰를 조회하는 쪽도 current_timestamp가 아니라
  #       CAST(current_timestamp AS timestamp)로 비교해야 한다 — 전자는 WITH
  #       TIME ZONE이라 타입이 안 맞는다. 룰 SQL이 전부 그렇게 되어 있다.
  #   - 파싱 실패가 쿼리 전체를 죽이지 않도록 시간 파싱은 전부 try()로 감싼다.
  #     레코드 하나가 깨졌다고 관제 화면이 통째로 안 뜨면 안 된다.
  #   - 해당 소스에 없는 개념은 CAST(NULL AS varchar)로 자리만 맞춘다.
  # ===========================================================================
  security_events_branch_templates = {

    # -- 1) CloudTrail — 누가 어떤 AWS API를 불렀나 -----------------------------
    cloudtrail = <<-SQL
      SELECT
        CAST(try(from_iso8601_timestamp(eventtime)) AS timestamp)                     AS event_time,
        'cloudtrail'                                                                  AS source_type,
        sourceipaddress                                                               AS source_ip,
        COALESCE(useridentity.arn, useridentity.username, useridentity.principalid)   AS actor,
        concat(eventsource, ':', eventname)                                           AS action,
        try(element_at(resources, 1).arn)                                             AS target,
        CASE WHEN errorcode IS NULL OR errorcode = '' THEN 'success' ELSE 'failure' END AS outcome,
        NULLIF(concat(COALESCE(errorcode, ''), ' ', COALESCE(errormessage, '')), ' ') AS detail
      FROM "$${db}"."$${t_cloudtrail}"
      -- region은 injected 프로젝션이라 등식 조건이 없으면 쿼리 자체가 실패한다
      WHERE region = '$${region}'
        AND event_date >= $${date_floor}
    SQL

    # -- 2) VPC Flow Logs — 어떤 ENI가 어디로 통신했나 --------------------------
    #    주체 개념이 없어 actor는 ENI. (탐지용 뷰에서는 제외 — 파일 상단 참고)
    vpc_flow = <<-SQL
      SELECT
        CAST(from_unixtime(f."start") AS timestamp)                                   AS event_time,
        'vpc_flow'                                                                    AS source_type,
        f.srcaddr                                                                     AS source_ip,
        f.interface_id                                                                AS actor,
        concat('flow:proto', CAST(f.protocol AS varchar))                             AS action,
        concat(f.dstaddr, ':', CAST(f.dstport AS varchar))                            AS target,
        CASE f.action WHEN 'ACCEPT' THEN 'success' WHEN 'REJECT' THEN 'blocked' ELSE 'unknown' END AS outcome,
        concat('bytes=', CAST(f.bytes AS varchar), ' packets=', CAST(f.packets AS varchar)) AS detail
      FROM "$${db}"."$${t_vpc_flow}" f
      WHERE f.region = '$${region}'
        AND f.event_date >= $${date_floor}
    SQL

    # -- 3) WAF — 엣지에서 무엇을 허용/차단했나 ---------------------------------
    #    인증 주체가 없어 actor는 NULL.
    waf = <<-SQL
      SELECT
        CAST(from_unixtime(w."timestamp" / 1000.0) AS timestamp)                      AS event_time,
        'waf'                                                                         AS source_type,
        w.httprequest.clientip                                                        AS source_ip,
        CAST(NULL AS varchar)                                                         AS actor,
        concat(COALESCE(w.httprequest.httpmethod, '-'), ' ', COALESCE(w.httprequest.uri, '-')) AS action,
        w.httprequest.host                                                            AS target,
        CASE w.action WHEN 'ALLOW' THEN 'success' WHEN 'BLOCK' THEN 'blocked' ELSE lower(COALESCE(w.action, 'unknown')) END AS outcome,
        concat('rule=', COALESCE(w.terminatingruleid, '-'), ' country=', COALESCE(w.httprequest.country, '-')) AS detail
      FROM "$${db}"."$${t_waf}" w
      WHERE (
          $${ymd_window}
        )
    SQL

    # -- 4) ALB 액세스 로그 — WAF를 통과한 요청이 실제로 어떻게 처리됐나 --------
    alb = <<-SQL
      SELECT
        CAST(try(from_iso8601_timestamp(a."time")) AS timestamp)                      AS event_time,
        'alb'                                                                         AS source_type,
        a.client_ip                                                                   AS source_ip,
        CAST(NULL AS varchar)                                                         AS actor,
        concat(COALESCE(a.request_verb, '-'), ' ', COALESCE(a.request_url, '-'))      AS action,
        a.domain_name                                                                 AS target,
        CASE
          WHEN a.elb_status_code >= 500 THEN 'failure'
          WHEN a.elb_status_code >= 400 THEN 'blocked'
          ELSE 'success'
        END                                                                           AS outcome,
        concat('elb_status=', CAST(a.elb_status_code AS varchar), ' target_status=', COALESCE(a.target_status_code, '-')) AS detail
      FROM "$${db}"."$${t_alb}" a
      WHERE a."day" >= $${date_floor}
    SQL

    # -- 5) 애플리케이션 로그 — 앱이 스스로 남긴 보안 이벤트 --------------------
    #    (로그인 실패, 권한 거부 등) 상위 컬럼과 log_processed 구조체 어느 쪽에
    #    값이 들어올지 파이프라인에 따라 갈려서, 기존
    #    application_normalized_event_select와 같이 COALESCE 한다.
    application = <<-SQL
      SELECT
        CAST(try(from_iso8601_timestamp(COALESCE(p.log_processed.timestamp, p."timestamp"))) AS timestamp) AS event_time,
        'application'                                                                 AS source_type,
        COALESCE(p.log_processed.clientip, p.clientip)                                AS source_ip,
        COALESCE(p.log_processed.principal, p.principal, p.log_processed.actorusername, p.actorusername) AS actor,
        concat(
          COALESCE(p.log_processed.method, p.method, '-'), ' ',
          COALESCE(p.log_processed.uri, p.uri, '-')
        )                                                                             AS action,
        concat(
          COALESCE(p.log_processed.targettype, p.targettype, '-'), ':',
          COALESCE(p.log_processed.targetid, p.targetid, '-')
        )                                                                             AS target,
        COALESCE(
          p.log_processed.outcome,
          p.outcome,
          CASE
            WHEN COALESCE(p.log_processed.statuscode, p.statuscode) >= 500 THEN 'failure'
            WHEN COALESCE(p.log_processed.statuscode, p.statuscode) >= 400 THEN 'blocked'
            ELSE 'success'
          END
        )                                                                             AS outcome,
        concat(
          'type=', COALESCE(p.log_processed.eventtype, p.eventtype, '-'),
          ' reason=', COALESCE(p.log_processed.reasoncode, p.reasoncode, '-'),
          ' exception=', COALESCE(p.log_processed.exceptiontype, p.exceptiontype, '-')
        )                                                                             AS detail
      FROM "$${db}"."$${t_application}" p
      WHERE (
          $${ymd_window}
        )
    SQL
  }

  # ---------------------------------------------------------------------------
  # 최종 뷰 SQL — 뷰별로 선택된 소스 분기만 UNION ALL 한다
  # ---------------------------------------------------------------------------
  security_events_view_sql = {
    for view_name, cfg in local.security_events_views : view_name => join("", [
      "CREATE OR REPLACE VIEW \"${local.security_events_database}\".\"${view_name}\" AS\n\n",
      join("\n\nUNION ALL\n\n", [
        for source in cfg.sources :
        trimspace(templatestring(
          local.security_events_branch_templates[source],
          local.security_events_template_vars[view_name]
        ))
      ]),
      "\n"
    ])
  }
}


# =============================================================================
# 저장 쿼리 — 콘솔 Athena > Saved queries 에서 실행
#
# siem-detector Lambda도 여기서 만든 named query의 SQL을 그대로 읽어서 실행한다
# (siem-detector.tf 참고). 그래서 "콘솔에서 사람이 보는 것"과 "Lambda가 매시간
# 실행하는 것"이 같은 문자열임이 보장된다 — 튜닝할 때 두 곳을 고칠 일이 없다.
# =============================================================================

resource "aws_athena_named_query" "create_security_events_view" {
  for_each = local.security_events_view_sql

  name = each.key == local.security_events_view_name ? "00-create-security-events-view" : "00a-create-security-events-recent-view"
  description = (
    each.key == local.security_events_view_name
    ? "조사용 통합 보안 이벤트 뷰(${var.security_events_window_days}일·5개 소스) 생성/갱신. CREATE OR REPLACE라 재실행 무해"
    : "탐지용 통합 뷰(${var.security_events_detection_window_days}일·vpc_flow 제외) 생성/갱신. siem-detector Lambda가 매 실행마다 자동으로 돌리므로 손으로 실행할 필요는 없다"
  )
  database  = aws_glue_catalog_database.security_logs.name
  workgroup = aws_athena_workgroup.security_logs.id

  query = each.value
}

resource "aws_athena_named_query" "verify_security_events_view" {
  name        = "00b-verify-security-events-view"
  description = "뷰가 살아 있는지 + 어떤 소스가 실제로 데이터를 내고 있는지 확인 (뷰 생성 직후 실행)"
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id

  # 5개 소스가 다 나와야 정상. 특정 source_type이 0건이면 그 로그 파이프라인이
  # 안 돌고 있다는 뜻이므로, 뷰 문제로 오해하지 말고 해당 소스를 먼저 볼 것.
  # (매일 destroy/apply 하는 환경이라 ALB/앱 로그는 그날 트래픽이 없으면 0일 수 있다)
  query = <<-SQL
    SELECT
      source_type,
      COUNT(*)                  AS events,
      COUNT(DISTINCT source_ip) AS distinct_ips,
      MIN(event_time)           AS oldest,
      MAX(event_time)           AS newest
    FROM "${aws_glue_catalog_database.security_logs.name}"."${local.security_events_view_name}"
    GROUP BY source_type
    ORDER BY events DESC;
  SQL
}


# =============================================================================
# Outputs
# =============================================================================

output "security_events_view_name" {
  description = "조사용 통합 보안 이벤트 뷰 (사용 전 저장 쿼리 00-create-security-events-view를 한 번 실행할 것)"
  value       = "${aws_glue_catalog_database.security_logs.name}.${local.security_events_view_name}"
}

output "security_events_view_window_days" {
  description = "조사용 통합 뷰가 커버하는 시간창(일). 이보다 오래된 로그는 소스별 저장 쿼리로 조회"
  value       = var.security_events_window_days
}

output "security_events_detection_view_name" {
  description = "SIEM 탐지 룰이 조회하는 뷰. siem-detector Lambda가 매 실행마다 재생성한다"
  value       = "${aws_glue_catalog_database.security_logs.name}.${local.security_events_detection_view_name}"
}
