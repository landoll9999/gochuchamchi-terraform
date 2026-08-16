# =============================================================================
# SIEM 탐지 룰 — 통합 뷰 위에 올리는 결정론적 상관 규칙 (2026-08-12)
#
# 위치: 수집(로그 파이프라인) → 정규화(security-events-view.tf) → **탐지(이 파일)**
#       → 실행(siem-detector.tf) → 알림(siem-alerts.tf)
#
# 룰의 역할은 "정확한 탐지"가 아니라 "후보 생성"이다
#   뒤에 Groq 판정 계층(siem/judge.py)이 붙어 있다. 그래서 이 룰들은 임계값을
#   **재현율 우선으로 낮게** 잡는다. 룰이 혼자 정확해야 했다면 못 잡았을
#   경계선 사례까지 일단 올리고, 소음 제거는 판정이 한다.
#
#     원시 로그 (하루 수십만 건)
#        ↓ 이 룰들 — 볼륨을 여기서 잡는다. 모델 관여 없음
#     후보 (하루 수십 건)
#        ↓ Groq 판정 — 호출량이 후보 수에 비례해 무료 티어로 감당된다
#     알림
#
#   이 순서가 뒤집히면(모델이 먼저 보면) 토큰 비용이 트래픽에 비례해 따라
#   올라가 개인 프로젝트 규모에서 성립하지 않는다. 룰이 앞에 있는 이유가 그것이다.
#
# 판정이 뒤에 붙어도 룰이 SQL인 이유는 그대로다
#   - 재현성: "그때 왜 안 울렸나"에 답할 수 있어야 한다. **재현율은 여전히
#     결정론적이다** — 룰이 안 걸었으면 조건을 읽으면 이유가 나온다.
#     모델이 좌우하는 것은 정밀도(무엇을 알릴지)뿐이다.
#   - 감사: 룰 변경이 git diff로 남는다. 임계값이 언제 왜 바뀌었는지 추적된다.
#   - 비용: 상시 동작하는 층에 종량 API를 걸지 않는다.
#   - 프롬프트 인젝션: 공격자가 값을 정할 수 있는 문자열(User-Agent, 버킷
#     이름, 태그)이 룰에는 그대로 들어오지만, SQL 조건문은 그걸 지시로 읽지 않는다.
#     모델에 넘어가는 것은 룰이 집계한 결과표뿐이고 거기서 방어가 한 겹 더 걸린다.
#
# 룰이 갖춰야 할 계약 3가지 (siem-detector Lambda가 이걸 전제로 동작한다)
#   ① 첫 컬럼은 반드시 `alert_key` — 중복 억제 단위. 같은 alert_key는
#      siem_alert_dedup_hours 동안 다시 알리지 않는다. "무엇을 하나의 사건으로
#      볼 것인가"를 룰이 스스로 정하는 자리다.
#      (이 컬럼은 판정 프롬프트와 Discord 표에서 자동으로 빠진다)
#   ② 조회 대상은 탐지용 뷰(security_events_recent) 또는 원본 테이블.
#      조사용 뷰(security_events)를 쓰면 매 실행 스캔량이 몇 배가 된다.
#   ③ 시간창은 룰 SQL 안에서 스스로 건다. 호출자가 안 걸어도 새지 않아야 한다.
#      뷰 조회는 `event_time >= CAST(current_timestamp AS timestamp) - INTERVAL ...`
#      — current_timestamp는 WITH TIME ZONE이라 CAST 없이 비교하면 타입이 안 맞는다.
#
# 룰을 추가하려면 아래 locals.siem_rules에 항목 하나를 더하면 끝이다.
# Athena 저장 쿼리(콘솔 튜닝용)와 Lambda가 읽는 룰 목록이 같은 정의에서
# 생성되므로, 콘솔에서 손으로 돌려 본 것과 매시간 자동 실행되는 것이 항상
# 같은 SQL임이 보장된다.
# =============================================================================

variable "siem_rule_lookback_minutes" {
  description = <<-EOT
    각 룰이 한 번 실행될 때 들여다보는 시간 범위(분). 스케줄 간격보다 넉넉해야
    로그 배달 지연(CloudTrail 최대 15분, ALB 5분, Firehose 버퍼)으로 늦게 도착한
    이벤트를 놓치지 않는다. 겹치는 구간에서 같은 사건이 다시 잡히는 건
    DynamoDB 중복 억제가 처리한다 — 즉 "겹쳐서 손해 볼 일은 없고, 모자라면
    탐지에 구멍이 난다". 기본값은 rate(1 hour) + 15분 여유.
  EOT
  type        = number
  default     = 75

  validation {
    condition     = var.siem_rule_lookback_minutes >= 15 && var.siem_rule_lookback_minutes <= 1440
    error_message = "siem_rule_lookback_minutes는 15~1440 사이여야 합니다."
  }
}

variable "siem_auth_failure_threshold" {
  description = <<-EOT
    인증/인가 실패 폭증 룰의 후보 임계값. lookback 안에서 (출발지 IP × 주체)
    조합의 실패가 이 수를 넘으면 **후보로 올린다**(알림이 확정되는 게 아니다).

    판정 계층이 뒤에 있으므로 재현율 우선으로 낮게 잡았다. 배포 직후의 정상
    권한 오류가 여기 걸리는 건 의도된 것이고, 그걸 걸러내는 게 판정의 일이다.
    반대로 이 값을 높이면 느린 크리덴셜 스터핑을 **구조적으로** 못 잡는다 —
    판정으로도 복구가 안 되는 손실이라 낮게 두는 편이 낫다.
  EOT
  type        = number
  default     = 8

  validation {
    condition     = var.siem_auth_failure_threshold >= 3
    error_message = "siem_auth_failure_threshold는 3 이상이어야 합니다(그 이하는 후보가 너무 많아 판정 호출 상한을 태웁니다)."
  }
}

variable "siem_cross_layer_denied_threshold" {
  description = <<-EOT
    동일 IP 다계층 출현 룰에서, CloudTrail 계층이 끼지 않은 경우에 요구하는
    거부(blocked/failure) 건수.

    이 조건이 왜 필요한가: WAF와 ALB는 **같은 요청을 두 번 기록한다.** 그래서
    "2개 계층에 나타남"만으로는 모든 정상 트래픽이 걸린다. 반면 외부 IP가
    CloudTrail(AWS API)에까지 나타났다면 그건 계층 수만으로 이미 이상하다.
    그래서 CloudTrail이 끼면 무조건 후보, 아니면 거부가 이만큼 쌓여야 후보다.
  EOT
  type        = number
  default     = 5

  validation {
    condition     = var.siem_cross_layer_denied_threshold >= 1
    error_message = "siem_cross_layer_denied_threshold는 1 이상이어야 합니다."
  }
}

variable "siem_egress_bytes_threshold" {
  description = <<-EOT
    데이터 반출 의심 룰의 임계값(바이트). lookback 안에서 (내부 출발지 → 외부
    목적지) 한 쌍의 ACCEPT 트래픽 합이 이 값을 넘으면 알린다.
    이 룰은 오탐이 가장 많다 — ECR 이미지 풀, OS 패키지 업데이트, S3 전송이
    전부 "내부→외부 대량 아웃바운드"다. 그럼에도 기본값을 낮게(256 MiB) 잡은
    것은 판정 계층이 뒤에 있기 때문이다. 정상 목적지가 파악되면 임계값을
    올리지 말고 siem_egress_ignore_dst_regex로 빼는 편이 낫다 — 진짜 반출은
    조용히 조금씩 나가기도 해서, 임계값을 올리면 그쪽을 통째로 못 본다.
  EOT
  type        = number
  default     = 268435456

  validation {
    condition     = var.siem_egress_bytes_threshold >= 1048576
    error_message = "siem_egress_bytes_threshold는 1 MiB 이상이어야 합니다."
  }
}

variable "siem_egress_ignore_dst_regex" {
  description = <<-EOT
    데이터 반출 룰에서 제외할 목적지 IP 정규식. 비우면 제외 없음.
    운영하며 확인된 정상 대상(예: ECR/S3 엔드포인트 대역)을 여기에 넣는다.
    예: "^(52\\.219\\.|3\\.5\\.)"
  EOT
  type        = string
  default     = ""
}

variable "siem_trusted_automation_principals" {
  description = <<-EOT
    권한 상승·감사 무력화 룰에서 제외할 주체(actor ARN) 정규식 목록.
    terraform apply 자체가 KMS 키 정책·버킷 정책·IAM 역할을 계속 건드리므로,
    비워 두면 apply 하는 날마다 알림이 쏟아진다.

    ⚠️ 다만 여기에 넣는 순간 그 주체의 권한 변경은 영원히 안 보인다.
    IaC 파이프라인 역할처럼 "변경 경로가 코드 리뷰로 따로 감사되는" 주체만
    넣을 것. 사람 계정(관리자 IAM 사용자)은 넣지 말 것 — 탈취되면 그게 바로
    이 룰이 잡아야 할 사건이다.

    예: ["arn:aws:iam::\\d+:role/gochuchamchi-github-actions-.*"]
  EOT
  type        = list(string)
  default     = []
}

variable "siem_db_expected_principals" {
  description = <<-EOT
    RDS 감사에서 "정상"으로 보는 DB 접속 주체(정규식 조각) 목록. 이 목록을 벗어난
    유저가 **성공적으로** 접속하면 db-unexpected-principal 룰이 후보로 올린다.

    IAM 토큰 전환의 검증 축이기도 하다 — 구 비밀번호 계정 gochuchamchi_app 은
    여기 없으므로, 그 계정의 접속이 한 건이라도 잡히면 "비밀번호 계정이 아직
    태어나고 있다"는 신호가 된다(= verify-db-iam-only.ps1 이 수동으로 보던 것을
    상시 자동으로 본다). 배스천 운영 계정 admin, 앱 IAM 계정, 엔진 내부 계정만 넣는다.
  EOT
  type        = list(string)
  default     = ["admin", "gochuchamchi_app_iam", "mariadb\\.sys", "mysql\\.sys", "rdsadmin"]
}

variable "siem_app_upload_burst_threshold" {
  description = <<-EOT
    앱 상품 등록(POST /shop/register) 폭증 룰의 임계값. lookback 안에서 한 주체가
    이 수를 넘겨 등록하면 후보로 올린다. 상품 이미지 업로드는 확장자·Content-Type
    검증이 약해(spring S3Service) 신뢰 도메인(CloudFront)에 임의 HTML/SVG를 뿌리는
    통로가 될 수 있어, 그 남용을 빈도로 잡는다. 정상 판매자의 다건 등록은 판정이 거른다.
  EOT
  type        = number
  default     = 10
}


locals {
  # 룰이 조회할 대상 (탐지용 뷰 / 원본 테이블)
  siem_detection_view = "\"${aws_glue_catalog_database.security_logs.name}\".\"${local.security_events_detection_view_name}\""
  siem_flow_table     = "\"${aws_glue_catalog_database.security_logs.name}\".\"${aws_glue_catalog_table.vpc_flow_logs.name}\""
  # EKS audit 는 탐지용 통합 뷰에 넣지 않는다(양이 커 시간당 스캔 상한 위험 — vpc_flow와
  # 같은 이유). 대신 아래 EKS 룰이 원본 테이블을 직접 조회하고, 파티션은
  # eks_control_plane_recent_partition(오늘+어제)으로 프루닝한다.
  siem_eks_table = "\"${aws_glue_catalog_database.security_logs.name}\".\"${aws_glue_catalog_table.eks_control_plane_logs.name}\""

  # 뷰 조회 공통 시간 조건. 뷰의 event_time은 timestamp WITHOUT TIME ZONE이라
  # current_timestamp(WITH TIME ZONE)와 직접 비교하면 타입 오류가 난다.
  siem_recent_window = "event_time >= CAST(current_timestamp AS timestamp) - INTERVAL '${var.siem_rule_lookback_minutes}' MINUTE"

  # 사설/링크로컬/루프백 대역. 내부 통신이 여러 계층에 찍히는 것은 정상이므로
  # 외부 출발지 룰에서 제외한다.
  siem_private_ip_regex = "^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.|127\\.|169\\.254\\.|::1$|fd|fe80:)"

  # -- 룰 23이 찾는 액션 목록 ------------------------------------------------
  # action 컬럼은 뷰에서 concat(eventsource, ':', eventname)으로 만들어진다.
  # 즉 "iam.amazonaws.com:CreateAccessKey" 형태로 매칭된다.

  # 권한 상승: 자기 또는 남의 권한을 넓히는 IAM 조작
  siem_privilege_escalation_regex = join("", [
    "(?i)^iam\\.amazonaws\\.com:(",
    "CreateUser|CreateAccessKey|CreateLoginProfile|UpdateLoginProfile|",
    "AttachUserPolicy|AttachRolePolicy|AttachGroupPolicy|",
    "PutUserPolicy|PutRolePolicy|PutGroupPolicy|",
    "CreatePolicyVersion|SetDefaultPolicyVersion|UpdateAssumeRolePolicy|",
    "AddUserToGroup|DeleteUserPermissionsBoundary|DeleteRolePermissionsBoundary",
    ")$"
  ])

  # 감사 무력화: 증거를 지우거나 탐지를 끄는 조작.
  # 실패해도(권한 없어 거부돼도) 알린다 — 시도 자체가 신호다.
  siem_audit_tampering_regex = join("", [
    "(?i)^(",
    "cloudtrail\\.amazonaws\\.com:(StopLogging|DeleteTrail|UpdateTrail|PutEventSelectors)|",
    "guardduty\\.amazonaws\\.com:(DeleteDetector|UpdateDetector|CreateFilter|DeleteMembers|DisassociateFromAdministratorAccount|UpdatePublishingDestination)|",
    "config\\.amazonaws\\.com:(StopConfigurationRecorder|DeleteConfigurationRecorder|DeleteDeliveryChannel|PutConfigurationRecorder|PutDeliveryChannel)|",
    "securityhub\\.amazonaws\\.com:(DisableSecurityHub|DisassociateFromAdministratorAccount|BatchDisableStandards)|",
    "kms\\.amazonaws\\.com:(DisableKey|ScheduleKeyDeletion|PutKeyPolicy)|",
    "logs\\.amazonaws\\.com:(DeleteLogGroup|DeleteSubscriptionFilter|DeleteRetentionPolicy)|",
    "s3\\.amazonaws\\.com:(PutBucketPolicy|DeleteBucketPolicy|PutBucketVersioning|PutBucketLifecycleConfiguration|DeleteBucket|PutObjectLockConfiguration|PutBucketLogging)",
    ")$"
  ])

  # 신뢰 주체 제외 절. 목록이 비면 절 자체를 넣지 않는다 (빈 정규식은 전부 매칭).
  siem_trusted_actor_clause = (
    length(var.siem_trusted_automation_principals) == 0
    ? ""
    : "  AND NOT regexp_like(COALESCE(actor, ''), '(?i)^(${join("|", var.siem_trusted_automation_principals)})$')\n"
  )

  siem_egress_ignore_clause = (
    var.siem_egress_ignore_dst_regex == ""
    ? ""
    : "  AND NOT regexp_like(dstaddr, '${var.siem_egress_ignore_dst_regex}')\n"
  )

  # RDS 감사에서 정상으로 보는 DB 접속 주체. 이 정규식을 벗어난 유저의 성공 접속이
  # db-unexpected-principal 룰의 후보다. (목록은 var.siem_db_expected_principals)
  siem_db_expected_principal_regex = "^(${join("|", var.siem_db_expected_principals)})$"


  # ===========================================================================
  # 룰 정의
  #
  #   seq       Athena 저장 쿼리 이름의 정렬 번호 (기존 조사 쿼리가 00~16을
  #             쓰고 있어 룰은 20번대를 쓴다)
  #   severity  CRITICAL / HIGH / MEDIUM — Discord 색과 제목 아이콘을 정한다.
  #             억제/차단 같은 자동 대응은 하지 않는다. 이 파이프라인은
  #             "알리는 것"까지만 한다.
  #   title     알림 제목에 그대로 들어간다
  #   why       이 룰이 울렸을 때 무엇을 의심해야 하는지. 알림 본문과 **판정
  #             프롬프트에 동시에** 실린다. 즉 이 문장이 곧 모델에게 주는
  #             "룰 작성자의 의도"이고, 판정 품질에 직접 영향을 준다.
  #   always_alert
  #             true면 판정이 benign이어도 무조건 통보한다.
  #             benign 판정이 알림을 없애는 구조라 모델 오판이 곧 미탐이 된다.
  #             한 건이 곧 사건인 룰(권한 상승·감사 무력화)에만 켠다 —
  #             전부 켜면 판정 계층이 무의미해지고, 다 끄면 미탐이 조용해진다.
  # ===========================================================================
  siem_rules = {

    # -----------------------------------------------------------------------
    # 룰 1 — 동일 IP 다계층 출현
    #
    # 이 파이프라인의 존재 이유를 그대로 보여주는 룰이다. 단일 로그만 보면
    # "WAF가 차단 몇 건" / "앱이 403 몇 건"으로 흩어져 아무도 안 보지만,
    # 같은 외부 IP가 엣지·앱·AWS API에 동시에 나타났다면 그건 훑어보는 중이다.
    # 정규화 뷰가 없으면 이 질문 자체를 쿼리로 쓸 수 없다.
    # -----------------------------------------------------------------------
    "cross-layer-ip" = {
      seq          = 20
      severity     = "HIGH"
      always_alert = false
      title        = "동일 IP가 여러 계층에 동시 출현"
      why          = "한 외부 IP가 엣지(WAF)·애플리케이션·AWS API 중 둘 이상에서 관측됐습니다. layer_list에 cloudtrail이 있으면 외부 IP가 AWS API까지 닿았다는 뜻이라 그 자체로 이상합니다. 없으면 거부 건수(denied_count)가 쌓인 경우이므로 정찰(recon) 초기 단계일 수 있습니다. WAF와 ALB는 같은 요청을 두 번 기록하므로 그 둘만 있는 경우는 정상 트래픽일 가능성이 높습니다."

      query = <<-SQL
        WITH normalized AS (
          SELECT source_ip, source_type, outcome
          FROM ${local.siem_detection_view}
          WHERE ${local.siem_recent_window}
            AND source_ip IS NOT NULL
            AND source_ip NOT IN ('', '-')
            -- CloudTrail은 AWS 서비스 호출 시 IP 자리에 "ecs.amazonaws.com"
            -- 같은 서비스명을 넣는다. IP 형태가 아닌 값은 상관 대상이 아니다.
            AND regexp_like(source_ip, '^[0-9a-fA-F:.]+$')
            AND NOT regexp_like(source_ip, '${local.siem_private_ip_regex}')
        )
        SELECT
          concat('cross-layer-ip:', source_ip)                              AS alert_key,
          source_ip,
          count(DISTINCT source_type)                                       AS layers,
          array_join(array_sort(array_agg(DISTINCT source_type)), ',')      AS layer_list,
          count(*)                                                          AS event_count,
          count_if(outcome IN ('blocked', 'failure'))                       AS denied_count
        FROM normalized
        GROUP BY source_ip
        HAVING count(DISTINCT source_type) >= 2
           AND (
             -- 외부 IP가 AWS API 계층까지 닿았으면 계층 수만으로 후보다
             count_if(source_type = 'cloudtrail') > 0
             -- 그 외(waf+alb 조합 등)는 같은 요청이 두 번 기록되는 것뿐이라
             -- 거부가 일정 수 이상 쌓여야 신호가 된다
             OR count_if(outcome IN ('blocked', 'failure')) >= ${var.siem_cross_layer_denied_threshold}
           )
        ORDER BY layers DESC, denied_count DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 2 — 인증/인가 실패 폭증
    #
    # WAF·ALB의 4xx는 일부러 뺐다. 스캐너 한 대가 차단 수천 건을 만드는데
    # 그건 이미 WAF가 막은 것이고, 여기에 섞으면 임계값이 무의미해진다.
    # 남긴 것은 "인증 경계를 실제로 두드린 흔적" 둘뿐이다:
    #   - CloudTrail의 권한 거부 계열 (자격증명은 유효한데 권한이 없음 =
    #     탈취된 키로 범위를 재는 중일 수 있음)
    #   - 애플리케이션이 스스로 남긴 로그인 실패/권한 거부
    # -----------------------------------------------------------------------
    "auth-failure-burst" = {
      seq          = 21
      severity     = "HIGH"
      always_alert = false
      title        = "인증·인가 실패 폭증"
      why          = "같은 출발지/주체에서 인증 또는 권한 거부가 임계값(${var.siem_auth_failure_threshold}건)을 넘었습니다. 크리덴셜 스터핑, 탈취된 액세스키의 권한 탐색, 또는 배포 직후 권한 설정 오류 중 하나입니다. actor가 자동화 역할이고 sample_actions가 한 서비스에 몰려 있으면 배포 직후 권한 누락일 가능성이 높고, 사람 계정이거나 여러 서비스에 흩어져 있으면 권한 탐색입니다."

      query = <<-SQL
        SELECT
          concat('auth-burst:', COALESCE(source_ip, '-'), '|', COALESCE(actor, '-')) AS alert_key,
          COALESCE(source_ip, '-')                                          AS source_ip,
          COALESCE(actor, '-')                                              AS actor,
          count(*)                                                          AS failures,
          array_join(array_sort(array_agg(DISTINCT source_type)), ',')      AS layer_list,
          array_join(slice(array_sort(array_agg(DISTINCT action)), 1, 5), ' | ') AS sample_actions,
          min(event_time)                                                   AS first_seen,
          max(event_time)                                                   AS last_seen
        FROM ${local.siem_detection_view}
        WHERE ${local.siem_recent_window}
          AND (
            (
              source_type = 'cloudtrail'
              AND outcome = 'failure'
              AND regexp_like(
                COALESCE(detail, ''),
                '(?i)accessdenied|unauthorized|invalidclienttokenid|signaturedoesnotmatch|notauthorized|expiredtoken'
              )
            )
            OR (
              source_type = 'application'
              AND outcome IN ('blocked', 'failure')
            )
          )
        GROUP BY source_ip, actor
        HAVING count(*) >= ${var.siem_auth_failure_threshold}
        ORDER BY failures DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 3 — 권한 상승 · 감사 무력화
    #
    # 유일하게 집계하지 않고 이벤트 하나하나를 그대로 올리는 룰이다.
    # 건수가 적고, 한 건이 곧 사건이기 때문이다. 실패한 시도도 올린다 —
    # "CloudTrail을 끄려다 SCP에 막혔다"는 성공만큼 중요한 신호다.
    #
    # ⚠️ 튜닝이 필요한 유일한 지점은 IaC다. terraform apply가 KMS 키 정책·버킷
    #    정책을 계속 건드리므로 siem_trusted_automation_principals에 파이프라인
    #    역할을 넣지 않으면 apply 하는 날마다 울린다. 사람 계정은 넣지 말 것.
    # -----------------------------------------------------------------------
    "privilege-audit-tampering" = {
      seq      = 22
      severity = "CRITICAL"
      # 판정이 benign이어도 통보한다. 이 룰이 놓치는 한 건이 곧 사고이고,
      # "계획된 apply였는가"는 로그만 봐서는 모델도 사람도 확정할 수 없다.
      always_alert = true
      title        = "권한 상승 또는 감사 무력화 시도"
      why          = "IAM 권한을 넓히거나(권한 상승) 로그·탐지를 끄는(감사 무력화) API가 호출됐습니다. category 컬럼으로 어느 쪽인지 구분하세요. outcome=failure여도 시도 자체가 신호입니다. terraform apply 중이면 정상일 수 있지만 로그만으로는 계획된 변경인지 확정할 수 없으므로, 정상으로 단정하지 말고 actor에게 직접 확인해야 합니다."

      query = <<-SQL
        SELECT
          concat('privaudit:', COALESCE(actor, '-'), '|', action, '|', COALESCE(target, '-')) AS alert_key,
          event_time,
          COALESCE(actor, '-')                                              AS actor,
          COALESCE(source_ip, '-')                                          AS source_ip,
          action,
          COALESCE(target, '-')                                             AS target,
          outcome,
          CASE
            WHEN regexp_like(action, '${local.siem_audit_tampering_regex}') THEN 'audit-tampering'
            ELSE 'privilege-escalation'
          END                                                               AS category
        FROM ${local.siem_detection_view}
        WHERE ${local.siem_recent_window}
          AND source_type = 'cloudtrail'
          AND (
            regexp_like(action, '${local.siem_privilege_escalation_regex}')
            OR regexp_like(action, '${local.siem_audit_tampering_regex}')
          )
        ${local.siem_trusted_actor_clause}ORDER BY event_time DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 4 — 데이터 반출 의심
    #
    # 이 룰만 통합 뷰가 아니라 원본 vpc_flow_logs를 직접 본다. 두 가지 이유:
    #   - bytes 합계가 필요한데, 정규화 뷰에서 그 값은 detail 문자열
    #     ("bytes=1234 packets=5") 안에 있어 집계할 수 없다.
    #   - flow는 원시 용량이 가장 커서 탐지용 뷰에서 아예 뺐다
    #     (security-events-view.tf 상단 참고). parquet이라 필요한 컬럼만
    #     읽히므로 여기서 직접 읽는 편이 훨씬 싸다.
    # -----------------------------------------------------------------------
    "data-egress" = {
      seq          = 23
      severity     = "MEDIUM"
      always_alert = false
      title        = "외부로의 대량 아웃바운드"
      why          = "내부 IP에서 외부로 임계값(${floor(var.siem_egress_bytes_threshold / 1048576)} MiB) 이상이 나갔습니다. 정상 대상(ECR 이미지 풀, OS 패키지 업데이트, S3 전송)이 대부분이고 그때 dstaddr은 AWS 대역입니다. dst_ports가 443 단일이고 목적지가 AWS 대역이면 정상 쪽, 비표준 포트이거나 모르는 대역이면 srcaddr 인스턴스의 프로세스를 확인해야 합니다."

      query = <<-SQL
        SELECT
          concat('egress:', srcaddr, '->', dstaddr)                         AS alert_key,
          srcaddr,
          dstaddr,
          count(*)                                                          AS flows,
          sum(bytes)                                                        AS total_bytes,
          round(sum(bytes) / 1048576.0, 1)                                  AS total_mib,
          array_join(slice(array_sort(array_agg(DISTINCT CAST(dstport AS varchar))), 1, 10), ',') AS dst_ports,
          from_unixtime(min("start"))                                       AS first_seen,
          from_unixtime(max("end"))                                         AS last_seen
        FROM ${local.siem_flow_table}
        -- region은 injected 프로젝션이라 등식 조건이 필수.
        -- event_date는 파티션 프루닝용(하루 단위), "start"가 실제 lookback 필터다.
        WHERE region = '${var.region}'
          AND event_date >= date_format(current_date - INTERVAL '1' DAY, '%Y/%m/%d')
          AND "start" >= to_unixtime(current_timestamp) - ${var.siem_rule_lookback_minutes * 60}
          AND action = 'ACCEPT'
          AND regexp_like(srcaddr, '^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)')
          AND NOT regexp_like(dstaddr, '${local.siem_private_ip_regex}')
        ${local.siem_egress_ignore_clause}GROUP BY srcaddr, dstaddr
        HAVING sum(bytes) >= ${var.siem_egress_bytes_threshold}
        ORDER BY total_bytes DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 5 — DB 인증 실패 폭증
    #
    # RDS 감사(source_type='rds')의 CONNECT 실패만 본다. 앱 로그인 실패(룰 2)와
    # 다른 계층이다 — 여긴 "DB 엔진이 직접 거부한" 접속이다. IAM 토큰 만료·리전
    # 오설정 같은 정상 사유도 걸리지만, 그 판별은 판정 계층이 한다.
    # -----------------------------------------------------------------------
    "db-auth-failure" = {
      seq          = 24
      severity     = "HIGH"
      always_alert = false
      title        = "DB 인증 실패 폭증"
      why          = "같은 출발지/DB 유저에서 RDS 접속 실패(CONNECT 실패)가 임계값(${var.siem_auth_failure_threshold}건)을 넘었습니다. actor가 gochuchamchi_app_iam이고 앱 배포 직후라면 IAM 토큰 발급 경로(리전/권한/만료) 문제일 가능성이 높고, 낯선 유저명이거나 여러 유저명이 한 IP에서 나오면 유효 계정 탐색입니다. require_secure_transport=1이라 비 TLS 접속도 여기서 실패로 잡힙니다."

      query = <<-SQL
        SELECT
          concat('db-auth-fail:', COALESCE(source_ip, '-'), '|', COALESCE(actor, '-')) AS alert_key,
          COALESCE(source_ip, '-')  AS source_ip,
          COALESCE(actor, '-')      AS actor,
          count(*)                  AS failures,
          min(event_time)           AS first_seen,
          max(event_time)           AS last_seen
        FROM ${local.siem_detection_view}
        WHERE ${local.siem_recent_window}
          AND source_type = 'rds'
          AND action LIKE 'CONNECT%'
          AND outcome = 'failure'
        GROUP BY source_ip, actor
        HAVING count(*) >= ${var.siem_auth_failure_threshold}
        ORDER BY failures DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 6 — 예상 밖 DB 계정 접속
    #
    # 허용 목록(var.siem_db_expected_principals)을 벗어난 유저의 성공 접속을
    # 한 건씩 올린다. 집계하지 않는다 — 한 건이 곧 사건이다. IAM 토큰 전환의
    # 상시 검증이기도 하다: 구 비밀번호 계정 gochuchamchi_app 이 목록에 없으므로,
    # 그 접속이 잡히면 "비밀번호 계정이 아직 만들어지고 있다"는 신호다.
    # -----------------------------------------------------------------------
    "db-unexpected-principal" = {
      seq          = 25
      severity     = "CRITICAL"
      always_alert = true
      title        = "예상 밖 DB 계정 접속"
      why          = "허용 목록에 없는 DB 유저가 RDS에 성공적으로 접속했습니다. 이 프로젝트의 정상 접속 주체는 배스천 운영 계정(admin)·앱 IAM 계정(gochuchamchi_app_iam)·엔진 내부 계정뿐입니다. actor가 구 비밀번호 계정 gochuchamchi_app이면 IAM 토큰 전환이 되돌아가고 있다는 신호이고, 완전히 낯선 유저명이면 계정 신설·탈취를 의심하세요. 배스천에서 사람이 수동 작업 중이었는지 먼저 확인하세요."

      query = <<-SQL
        SELECT
          concat('db-principal:', COALESCE(actor, '-'), '|', COALESCE(source_ip, '-')) AS alert_key,
          event_time,
          COALESCE(actor, '-')     AS actor,
          COALESCE(source_ip, '-') AS source_ip,
          action,
          outcome
        FROM ${local.siem_detection_view}
        WHERE ${local.siem_recent_window}
          AND source_type = 'rds'
          AND action LIKE 'CONNECT%'
          AND outcome = 'success'
          AND NOT regexp_like(COALESCE(actor, ''), '${local.siem_db_expected_principal_regex}')
        ORDER BY event_time DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 7 — 컨테이너 셸 접근 (kubectl exec / attach)
    #
    # EKS audit 원본을 직접 본다(통합 뷰 미포함). verb=create + subresource가
    # exec/attach 인 요청은 사람이 파드 안으로 들어간 것이다. 정상 운영에서는
    # 거의 없어 한 건씩 그대로 올린다(always_alert). 인가 거부(code=403)된
    # 시도도 올린다 — 침해 주체가 권한을 재는 신호다.
    # -----------------------------------------------------------------------
    "eks-pod-exec" = {
      seq          = 26
      severity     = "CRITICAL"
      always_alert = true
      title        = "컨테이너 셸 접근(kubectl exec/attach)"
      why          = "누군가 파드 안으로 exec/attach 했습니다. 이 클러스터는 배포를 GitOps로만 하므로 사람이 파드에 직접 들어갈 일이 정상 운영에는 거의 없습니다. actor가 사람 IAM 주체이고 계획된 디버깅이면 정상일 수 있으나, 서비스어카운트나 낯선 주체면 침해 후 횡이동을 의심하세요. code=403이면 시도가 거부된 것이지만 시도 자체가 신호입니다."

      query = <<-SQL
        SELECT
          concat('eks-exec:',
            COALESCE(json_extract_scalar(message, '$.user.username'), '-'), '|',
            COALESCE(json_extract_scalar(message, '$.objectRef.namespace'), '-'), '/',
            COALESCE(json_extract_scalar(message, '$.objectRef.name'), '-'))          AS alert_key,
          CAST(try(from_iso8601_timestamp(json_extract_scalar(message, '$.requestReceivedTimestamp'))) AS timestamp) AS event_time,
          json_extract_scalar(message, '$.user.username')                            AS actor,
          try(json_extract_scalar(message, '$.sourceIPs[0]'))                        AS source_ip,
          json_extract_scalar(message, '$.objectRef.namespace')                      AS namespace,
          json_extract_scalar(message, '$.objectRef.name')                           AS pod,
          json_extract_scalar(message, '$.objectRef.subresource')                    AS subresource,
          json_extract_scalar(message, '$.responseStatus.code')                      AS code
        FROM ${local.siem_eks_table}
        WHERE ${local.eks_control_plane_recent_partition}
          AND try(json_extract_scalar(message, '$.kind')) = 'Event'
          AND json_extract_scalar(message, '$.verb') = 'create'
          AND json_extract_scalar(message, '$.objectRef.subresource') IN ('exec', 'attach')
          AND CAST(try(from_iso8601_timestamp(json_extract_scalar(message, '$.requestReceivedTimestamp'))) AS timestamp)
              >= CAST(current_timestamp AS timestamp) - INTERVAL '${var.siem_rule_lookback_minutes}' MINUTE
        ORDER BY event_time DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 8 — K8s 인가 거부 폭증 (HTTP 403)
    #
    # 같은 주체/출발지에서 API 거부가 몰리면 권한 탐색이다. WITH 로 audit 이벤트를
    # 먼저 파싱해 GROUP BY 를 단순화한다. resources 로 무엇을 노렸는지 보인다.
    # -----------------------------------------------------------------------
    "eks-forbidden-burst" = {
      seq          = 27
      severity     = "HIGH"
      always_alert = false
      title        = "K8s 인가 거부 폭증"
      why          = "같은 주체/출발지에서 K8s API 인가 거부(403)가 임계값(${var.siem_auth_failure_threshold}건)을 넘었습니다. 탈취된 서비스어카운트 토큰이나 잘못 배포된 워크로드가 권한 밖 리소스를 훑는 중일 수 있습니다. resources에 secrets·rolebindings 같은 민감 리소스가 섞여 있으면 권한 상승 시도, 한 리소스에 몰려 있으면 배포 설정 오류일 가능성이 높습니다."

      query = <<-SQL
        WITH audit AS (
          SELECT
            json_extract_scalar(message, '$.user.username')                          AS actor,
            try(json_extract_scalar(message, '$.sourceIPs[0]'))                      AS source_ip,
            json_extract_scalar(message, '$.objectRef.resource')                     AS resource,
            json_extract_scalar(message, '$.responseStatus.code')                    AS code,
            CAST(try(from_iso8601_timestamp(json_extract_scalar(message, '$.requestReceivedTimestamp'))) AS timestamp) AS event_time
          FROM ${local.siem_eks_table}
          WHERE ${local.eks_control_plane_recent_partition}
            AND try(json_extract_scalar(message, '$.kind')) = 'Event'
        )
        SELECT
          concat('eks-forbidden:', COALESCE(actor, '-'), '|', COALESCE(source_ip, '-')) AS alert_key,
          COALESCE(actor, '-')      AS actor,
          COALESCE(source_ip, '-')  AS source_ip,
          count(*)                  AS forbidden_count,
          array_join(slice(array_sort(array_agg(DISTINCT resource)), 1, 8), ',') AS resources,
          min(event_time)           AS first_seen,
          max(event_time)           AS last_seen
        FROM audit
        WHERE code = '403'
          AND event_time >= CAST(current_timestamp AS timestamp) - INTERVAL '${var.siem_rule_lookback_minutes}' MINUTE
        GROUP BY actor, source_ip
        HAVING count(*) >= ${var.siem_auth_failure_threshold}
        ORDER BY forbidden_count DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 9 — 관리자 경로 무단 접근
    #
    # 앱이 인가 거부한 요청 중 관리자 경로(/admin)만 특정한다. 인증 실패 폭증
    # 룰(룰 2)은 앱 거부를 임계 8로 집계하지만, 관리 경로는 한두 건도 의미가
    # 있어(일반 유저가 관리 API를 직접 호출) 낮은 임계로 따로 본다. SecurityConfig
    # 상 /admin/**는 ADMIN/SUPERADMIN 전용이므로 그 외 주체의 접근은 403이 된다.
    # -----------------------------------------------------------------------
    "app-admin-path-probe" = {
      seq          = 28
      severity     = "HIGH"
      always_alert = false
      title        = "관리자 경로 무단 접근"
      why          = "일반 권한 주체가 관리자 전용 경로(/admin)에 접근해 거부(403)됐습니다. 정상 유저는 이 경로 자체를 볼 일이 없으므로, 브라우저 오조작이 아니라면 권한 상승을 노린 탐색입니다. actor가 로그인 계정이면 그 계정의 세션이 탈취됐거나 내부자가 권한 밖을 시도하는 것이고, 여러 경로를 훑고 있으면(sample_actions) 자동화 스캔입니다."

      query = <<-SQL
        SELECT
          concat('app-admin-probe:', COALESCE(source_ip, '-'), '|', COALESCE(actor, '-')) AS alert_key,
          COALESCE(source_ip, '-')  AS source_ip,
          COALESCE(actor, '-')      AS actor,
          count(*)                  AS denied_admin_hits,
          array_join(slice(array_sort(array_agg(DISTINCT action)), 1, 5), ' | ') AS sample_actions,
          min(event_time)           AS first_seen,
          max(event_time)           AS last_seen
        FROM ${local.siem_detection_view}
        WHERE ${local.siem_recent_window}
          AND source_type = 'application'
          AND outcome = 'blocked'
          AND regexp_like(action, '(?i)/admin(/|$| )')
        GROUP BY source_ip, actor
        HAVING count(*) >= 3
        ORDER BY denied_admin_hits DESC
        LIMIT 50
      SQL
    }

    # -----------------------------------------------------------------------
    # 룰 10 — 상품 등록(이미지 업로드) 폭증
    #
    # 한 주체가 짧은 시간에 상품 등록을 대량으로 하면 업로드 통로 남용이다.
    # S3Service가 업로드 확장자·Content-Type을 검증하지 않아, 이미지 대신 임의
    # HTML/SVG를 신뢰 도메인(CloudFront)에 올리는 데 쓰일 수 있다. 정상 판매자의
    # 다건 등록도 걸리지만 그 판별은 판정 계층이 한다(재현율 우선).
    # -----------------------------------------------------------------------
    "app-upload-burst" = {
      seq          = 29
      severity     = "MEDIUM"
      always_alert = false
      title        = "상품 등록(업로드) 폭증"
      why          = "한 주체가 임계값(${var.siem_app_upload_burst_threshold}건) 넘게 상품을 등록했습니다. 상품 이미지 업로드는 확장자·MIME 검증이 약해, 대량 등록은 신뢰 도메인에 악성 콘텐츠(HTML/SVG 피싱)를 뿌리거나 스토리지를 소진시키는 통로일 수 있습니다. actor가 신규·미검증 판매자면 특히 의심하고, 오래된 정상 판매자의 재고 갱신이면 판정이 걸러 줍니다."

      query = <<-SQL
        SELECT
          concat('app-upload:', COALESCE(actor, '-'))                    AS alert_key,
          COALESCE(actor, '-')      AS actor,
          COALESCE(source_ip, '-')  AS source_ip,
          count(*)                  AS registrations,
          min(event_time)           AS first_seen,
          max(event_time)           AS last_seen
        FROM ${local.siem_detection_view}
        WHERE ${local.siem_recent_window}
          AND source_type = 'application'
          AND outcome = 'success'
          AND regexp_like(action, '(?i)POST\s+\S*/shop/register')
        GROUP BY actor, source_ip
        HAVING count(*) >= ${var.siem_app_upload_burst_threshold}
        ORDER BY registrations DESC
        LIMIT 50
      SQL
    }
  }
}


# =============================================================================
# Athena 저장 쿼리 — 콘솔에서 사람이 직접 돌려 보고 임계값을 튜닝하는 자리
#
# siem-detector Lambda는 여기서 만들어진 named query의 ID를 받아 SQL을 읽어
# 실행한다. 즉 이 리소스가 룰의 유일한 원본이고, 콘솔에서 본 것과 매시간
# 자동 실행되는 것이 절대 어긋나지 않는다.
# =============================================================================

resource "aws_athena_named_query" "siem_rule" {
  for_each = local.siem_rules

  name        = "${each.value.seq}-rule-${each.key}"
  description = "[${each.value.severity}] ${each.value.title} — 최근 ${var.siem_rule_lookback_minutes}분. siem-detector Lambda가 자동 실행하는 룰과 동일한 SQL"
  database    = aws_glue_catalog_database.security_logs.name
  workgroup   = aws_athena_workgroup.security_logs.id

  query = each.value.query
}


output "siem_detection_rules" {
  description = "등록된 SIEM 탐지 룰 목록 (Athena 저장 쿼리 이름 → 심각도)"
  value = {
    for key, rule in local.siem_rules :
    "${rule.seq}-rule-${key}" => rule.severity
  }
}
