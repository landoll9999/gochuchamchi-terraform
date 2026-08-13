# =============================================================================
# GuardDuty 자동대응용 WAF 차단 IP 목록 (2026-08-13)
#
# 격리 Lambda(../cloudwatch-notifications/isolation_function.py)가 네트워크 기반
# GuardDuty finding 의 공격자 원격 IP 를 이 목록에 넣어 엣지(CloudFront WAF)에서
# 차단한다. 왜 여기(persistent)에 두나:
#   - 차단 IP 는 매일 살아남아야 한다. WAF Web ACL 자체는 매일 destroy 되는 일일
#     계층(../terraform/edge.tf)에 있지만, "무엇을 차단 중인가"라는 상태는 사고가
#     끝날 때까지 유지돼야 한다. 상시 계층에 두면 일일 재구축을 건너 살아남는다.
#   - CLOUDFRONT scope IP set 은 us-east-1 전용이라 전용 provider 로 만든다.
#
# 참조 방향은 한 방향이다(일일 → 상시): 일일 edge WAF 가 이 IP set 을 data 소스로
# 조회해 block rule 로 참조한다. Lambda 는 이름으로 조회해 IP 를 넣고, 만료된 IP 는
# audit 경로(매시간)가 뺀다 — WAF IP set 에는 TTL 이 없어서 코드로 해제한다.
# =============================================================================

resource "aws_wafv2_ip_set" "guardduty_blocklist" {
  provider = aws.us_east_1

  name        = "gochuchamchi-guardduty-blocklist"
  description = "Attacker IPs auto-added by the GuardDuty isolation Lambda; expired entries swept hourly"
  scope       = "CLOUDFRONT"

  ip_address_version = "IPV4"
  addresses          = [] # 초기 비어 있음 — Lambda 가 런타임에 채운다.

  # addresses 는 Lambda 가 관리한다. Terraform 이 관여하면 apply 마다 Lambda 가
  # 넣어둔 차단 IP 를 빈 목록으로 되돌려 버린다.
  lifecycle {
    ignore_changes = [addresses]
  }

  tags = {
    Project   = "gochuchamchi"
    Component = "auto-response"
  }
}

output "guardduty_blocklist_ip_set_name" {
  description = "격리 Lambda 가 조회·갱신하는 WAF 차단 IP set 이름 (CLOUDFRONT scope, us-east-1)"
  value       = aws_wafv2_ip_set.guardduty_blocklist.name
}

output "guardduty_blocklist_ip_set_arn" {
  description = "일일 edge WAF 가 block rule 로 참조할 IP set ARN"
  value       = aws_wafv2_ip_set.guardduty_blocklist.arn
}
