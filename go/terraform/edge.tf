# =============================================================================
# L1 경계 방어 — CloudFront + WAF (격차분석 §2.1, 계획 D13)
#
# 기존에는 internet-facing ALB가 필터 없이 직접 노출되어 SQLi/XSS/Rate 공격이
# 애플리케이션까지 그대로 도달했다. 여기서 최상단 밴드를 채운다:
#
#   인터넷 → CloudFront(+WAF: Managed Rules + Rate-based) → ALB → 파드
#
# ⚠️ 2단계 apply 구조 (enable_alb_alarms와 같은 이유):
#   ALB는 Terraform이 아니라 aws-load-balancer-controller가 Ingress를 보고
#   비동기로 만들기 때문에, 최초 apply에서는 data.aws_lb 조회 대상이 없다.
#     1차 apply: enable_edge=false(기본) — 인증서·WAF까지만 생성
#     2차 apply: enable_edge=true — ALB가 뜬 뒤 CloudFront + Route53 전환
#
# ⚠️ CloudFront 뷰어 인증서는 반드시 us-east-1 ACM이어야 한다 (격차분석 §2.1).
#    iam-security.tf의 Region Guard가 글로벌 서비스(acm/cloudfront/waf 등)를
#    NotAction으로 빼두었으므로 발급이 막히지 않는다.
#
# (2026-08-11 보강) ALB 보안그룹을 CloudFront origin-facing 관리형 prefix list로
# 좁히는 것에 더해, 이 배포만 아는 Origin Custom Header를 ALB listener rule에서
# 검증한다. Prefix list만으로는 "CloudFront 서비스에서 왔다"까지만 증명되고
# "우리 배포에서 왔다"는 증명되지 않기 때문이다.
# =============================================================================

provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}


# =============================================================================
# 1. ACM 인증서 (us-east-1) — CloudFront 뷰어 TLS 종료용
#    검증 레코드는 서울 리전 인증서(dns.tf)와 같은 호스팅존을 쓰지만,
#    레코드 이름이 같아도 값이 동일해서 충돌하지 않도록 별도 리소스로 관리.
# =============================================================================

resource "aws_acm_certificate" "cloudfront" {
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cloudfront_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cloudfront.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]

  # dns.tf의 서울 리전 인증서 검증 레코드와 이름/값이 완전히 동일함
  # (같은 도메인의 DNS 검증 레코드는 리전과 무관하게 같은 값) -> 덮어쓰기 허용
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "cloudfront" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cloudfront.arn
  validation_record_fqdns = [for r in aws_route53_record.cloudfront_cert_validation : r.fqdn]
}


# =============================================================================
# 2. WAFv2 Web ACL (CLOUDFRONT scope — us-east-1에서만 생성 가능)
# =============================================================================

locals {
  # AWS 관리형 룰 그룹 — 항목을 추가/제거하면 아래 dynamic "rule"에 그대로 반영됨
  waf_managed_rule_groups = {
    "aws-managed-ip-reputation" = {
      priority        = 5
      name            = "AWSManagedRulesAmazonIpReputationList"
      metric          = "gochuchamchi-ip-reputation"
      override_action = "none"
    }
    "aws-managed-anonymous-ip" = {
      priority        = 6
      name            = "AWSManagedRulesAnonymousIpList"
      metric          = "gochuchamchi-anonymous-ip"
      override_action = "count"
    }
    # OWASP 계열 공통 룰 (XSS, LFI, 프로토콜 위반 등)
    "aws-managed-common" = {
      priority        = 10
      name            = "AWSManagedRulesCommonRuleSet"
      metric          = "gochuchamchi-managed-common"
      override_action = "none"
    }
    # 알려진 악성 입력 (Log4Shell JNDI, 경로 조작 등)
    "aws-managed-known-bad-inputs" = {
      priority        = 20
      name            = "AWSManagedRulesKnownBadInputsRuleSet"
      metric          = "gochuchamchi-known-bad-inputs"
      override_action = "none"
    }
    # SQL Injection 전용 룰 — 앱이 DB(MariaDB) 기반 회원/게시판이라 직접 해당
    "aws-managed-sqli" = {
      priority        = 30
      name            = "AWSManagedRulesSQLiRuleSet"
      metric          = "gochuchamchi-sqli"
      override_action = "none"
    }
  }
}

# ../persistent 가 소유한 자동대응 차단 IP set. 격리 Lambda 가 네트워크 기반
# GuardDuty finding 의 공격자 IP 를 여기에 넣고, 아래 WAF 가 block rule 로 참조해
# 엣지에서 막는다. 상시 계층 소유라 이 일일 WAF 가 매일 재생성돼도 차단 목록은
# 유지된다(한 방향 참조: 일일 → 상시).
data "aws_wafv2_ip_set" "guardduty_blocklist" {
  provider = aws.us_east_1
  name     = "gochuchamchi-guardduty-blocklist"
  scope    = "CLOUDFRONT"
}

resource "aws_wafv2_web_acl" "edge" {
  provider = aws.us_east_1

  name = "gochuchamchi-edge-waf"
  # ⚠️ WAF description은 한글 불가 (영숫자/일부 기호만 허용 — 2026-08-03 apply에서 실제 검증됨)
  description = "Edge filter in front of CloudFront - AWS Managed Rules + rate limit"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  # 단일 소스 IP의 5분당 요청 수 제한 — L7 Rate 공격/무차별 대입 완화
  rule {
    name     = "rate-limit-per-ip"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # 로그인은 일반 페이지 요청보다 훨씬 낮은 임계값으로 별도 관찰/차단한다.
  # COUNT로 적용 후 CloudWatch 지표를 확인하고 BLOCK으로 전환한다.
  rule {
    name     = "login-rate-limit-per-ip"
    priority = 2

    dynamic "action" {
      for_each = var.waf_login_rate_limit_action == "BLOCK" ? [1] : []
      content {
        block {}
      }
    }

    dynamic "action" {
      for_each = var.waf_login_rate_limit_action == "COUNT" ? [1] : []
      content {
        count {}
      }
    }

    statement {
      rate_based_statement {
        limit              = var.waf_login_rate_limit_per_5min
        aggregate_key_type = "IP"

        scope_down_statement {
          and_statement {
            statement {
              byte_match_statement {
                field_to_match {
                  uri_path {}
                }
                positional_constraint = "EXACTLY"
                search_string         = "/auth/login"

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }

            statement {
              byte_match_statement {
                field_to_match {
                  method {}
                }
                positional_constraint = "EXACTLY"
                search_string         = "POST"

                text_transformation {
                  priority = 0
                  type     = "NONE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-login-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  # 격리 Lambda 가 자동으로 채우는 공격자 IP 차단 목록(../persistent 소유).
  # rate-limit(1,2) 다음, 관리형 룰(5,6,10,20,30) 앞에 둬서 이미 확인된 악성 IP 를
  # 최우선으로 막는다. IP 추가·만료 해제는 Lambda 가 하고, 이 rule 은 참조만 한다.
  rule {
    name     = "guardduty-auto-blocklist"
    priority = 3

    action {
      block {}
    }

    statement {
      ip_set_reference_statement {
        arn = data.aws_wafv2_ip_set.guardduty_blocklist.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-guardduty-blocklist"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = local.waf_managed_rule_groups

    content {
      name     = rule.key
      priority = rule.value.priority

      override_action {
        dynamic "none" {
          for_each = rule.value.override_action == "none" ? [1] : []
          content {}
        }

        dynamic "count" {
          for_each = rule.value.override_action == "count" ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.metric
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "gochuchamchi-edge-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Project   = "gochuchamchi"
    Component = "edge-security"
  }
}


# =============================================================================
# 3. CloudFront 배포 (enable_edge=true인 2차 apply에서 생성)
# =============================================================================

# aws-load-balancer-controller가 만든 앱 ALB를 태그로 조회
# (cloudwatch-managed-metrics.tf와 같은 방식 — group.name 태그 기준)
data "aws_lb" "ingress_edge" {
  count = var.enable_edge ? 1 : 0

  tags = {
    "elbv2.k8s.aws/cluster" = module.eks.cluster_name
    "ingress.k8s.aws/stack" = "gochuchamchi-web"
  }
}

# 동적 콘텐츠라 캐시는 끄고(CachingDisabled) 헤더/쿠키/쿼리는 전부 오리진으로
# 전달(AllViewer). Host 헤더가 그대로 전달되므로:
#   - ALB의 ACM 인증서(gochuchamchi.shop)와 오리진 TLS 검증이 일치하고
#   - Ingress의 host 라우팅 규칙도 그대로 동작한다
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

# CloudFront 배포마다 고정된 Origin 검증값. 값은 sensitive state에만 저장하고
# output으로 노출하지 않는다. rotation_version을 올리면 CloudFront와 Ingress
# listener 조건이 함께 교체되지만 전파 순서에 따라 짧은 불일치가 생길 수 있으므로
# 회전 apply는 점검 시간에 수행한다.
resource "random_password" "cloudfront_origin_verify" {
  count = var.enable_edge ? 1 : 0

  length  = 48
  special = false

  keepers = {
    rotation_version = tostring(var.cloudfront_origin_header_rotation_version)
  }
}

resource "aws_cloudfront_distribution" "edge" {
  count = var.enable_edge ? 1 : 0

  enabled         = true
  comment         = "gochuchamchi edge - WAF filtered entry point"
  is_ipv6_enabled = true
  # 서울 포함 아시아 엣지까지 커버하는 최소 가격 클래스
  price_class = "PriceClass_200"
  web_acl_id  = aws_wafv2_web_acl.edge.arn

  aliases = [var.domain_name, "www.${var.domain_name}"]

  origin {
    origin_id   = "gochuchamchi-alb"
    domain_name = data.aws_lb.ingress_edge[0].dns_name

    custom_header {
      name  = "X-Gochuchamchi-Origin-Verify"
      value = random_password.cloudfront_origin_verify[0].result
    }

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "gochuchamchi-alb"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id

    compress = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cloudfront.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Project   = "gochuchamchi"
    Component = "edge-security"
  }
}


# =============================================================================
# 4. Route53 전환 — 기존 ExternalDNS 소유의 ALB Alias 레코드를 CloudFront로
#
# ExternalDNS는 policy=upsert-only라 레코드를 지우지는 않지만, ingress의
# spec host를 계속 바라보면 ALB로 되돌리는 upsert가 발생한다. 그래서
# enable_edge=true일 때 k8s-deploy.tf의 ingress에 ingress-hostname-source:
# annotation-only 어노테이션을 함께 넣어 ExternalDNS가 이 호스트를 더 이상
# 관리하지 않게 한다 (기존 레코드는 아래 allow_overwrite로 인수).
# =============================================================================

# apex/www × A/AAAA(is_ipv6_enabled) 4개 레코드를 한 리소스로 관리
resource "aws_route53_record" "edge_alias" {
  for_each = var.enable_edge ? {
    for pair in setproduct([var.domain_name, "www.${var.domain_name}"], ["A", "AAAA"]) :
    "${pair[0]}-${pair[1]}" => { name = pair[0], type = pair[1] }
  } : {}

  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value.name
  type            = each.value.type
  allow_overwrite = true # ExternalDNS가 만들어둔 ALB Alias를 인수

  alias {
    name                   = aws_cloudfront_distribution.edge[0].domain_name
    zone_id                = aws_cloudfront_distribution.edge[0].hosted_zone_id
    evaluate_target_health = false
  }
}


# =============================================================================
# 5. ALB 프론트 SG — CloudFront 우회 직접 접근 차단 (enable_edge=true에서만)
#
#   기본 상태에서는 aws-load-balancer-controller가 ALB SG를 자동 생성하고
#   0.0.0.0/0:80,443 을 연다. 그러면 공격자가 ALB의 *.elb.amazonaws.com DNS를
#   알아내는 순간 CloudFront(=WAF)를 건너뛰고 직접 때릴 수 있다.
#
#   이 SG를 ingress 어노테이션(alb.ingress.kubernetes.io/security-groups)으로
#   ALB에 붙이면 인바운드가 아래 둘로만 좁혀진다:
#     1) CloudFront origin-facing IP (AWS 관리형 prefix list — AWS가 자동 갱신)
#     2) 관리자 IP(var.endpoint_public_access_cidrs) — grafana.gochuchamchi.shop이
#        같은 ALB(IngressGroup gochuchamchi-web)에 있는데 CloudFront 뒤에 있지
#        않으므로(aliases는 apex/www만), 이걸 안 열면 Grafana 접속이 끊긴다.
#
#   ⚠️ 443만 연다: CloudFront 오리진 연결이 https-only이고, prefix list 참조
#      규칙은 목록 엔트리 수(약 55개)만큼 SG 규칙 쿼터(기본 60)를 소비하므로
#      80까지 열면 쿼터 초과로 apply가 실패한다. HTTP→HTTPS 리다이렉트는
#      CloudFront(viewer_protocol_policy)가 대신 수행.
# =============================================================================

data "aws_ec2_managed_prefix_list" "cloudfront_origin_facing" {
  count = var.enable_edge ? 1 : 0
  name  = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb_edge" {
  count = var.enable_edge ? 1 : 0

  name        = "gochuchamchi-alb-edge-sg"
  description = "ALB ingress restricted to CloudFront origin-facing + admin CIDRs"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "HTTPS from CloudFront edge only"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront_origin_facing[0].id]
  }

  ingress {
    description = "HTTPS from admin CIDRs (grafana subdomain is on this ALB, not behind CloudFront)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = distinct(concat(var.endpoint_public_access_cidrs, var.admin_allowed_cidrs))
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Project   = "gochuchamchi"
    Component = "edge-security"
  }
}

# =============================================================================
# Outputs
# =============================================================================

output "waf_web_acl_arn" {
  description = "CloudFront에 연결된 WAFv2 Web ACL ARN"
  value       = aws_wafv2_web_acl.edge.arn
}

output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 (enable_edge=true일 때만)"
  value       = var.enable_edge ? aws_cloudfront_distribution.edge[0].domain_name : null
}
