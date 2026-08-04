# ---------------------------------------------------------------------------
# 새 계정에 gochuchamchi.shop 호스팅 영역을 새로 생성.
# Gabia(도메인 등록기관)의 네임서버(NS)를 여기서 나오는 값으로 재지정해야
# 실제로 이 계정이 이 도메인의 DNS를 책임지게 됩니다.
# ---------------------------------------------------------------------------
data "aws_route53_zone" "this" {
  name = var.domain_name
}

output "name_servers" {
  value       = data.aws_route53_zone.this.name_servers
  description = "이미 Gabia에 등록되어 있는 네임서버 (변경 불필요 — 존을 재생성하지 않으므로 고정됨)"
}

# ---------------------------------------------------------------------------
# ACM 인증서 (DNS 검증) - 위 호스팅 영역을 사용해 자동으로 검증 레코드를 생성/확인
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "this" {
  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}", "argocd.${var.domain_name}", "grafana.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.this.domain_validation_options : dvo.domain_name => {
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
}

# 실제 퍼블릭 DNS에 검증 레코드가 조회되어야 완료됨 -> Gabia NS 재지정이 먼저 끝나야 함
resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

output "acm_certificate_arn" {
  value       = aws_acm_certificate.this.arn
  description = "서울 리전 ACM 인증서 ARN (ALB TLS 종단용)"
}
