# =============================================================================
# GuardDuty — 위협 "탐지" 계층 (2026-08-04 백로그 B6)
#
# CloudTrail(기록)·AWS Config(구성 감사)·Security Hub(점검)는 있었는데, 이상 행위를
# 능동 탐지하는 계층만 비어 있었다. GuardDuty는 CloudTrail 이벤트·VPC Flow Logs·
# DNS 쿼리를 자체 분석(별도 수집 설정 불필요)해서 크리덴셜 유출 사용, 코인마이닝,
# C2 통신, 비정상 API 호출 등을 Finding으로 올린다. rds.tf의 감사 로그 주석이
# "GuardDuty 연계용"이라 해놓고 본체가 없던 상태를 해소.
#
# 비용 — 계정당 최초 30일 무료. 이후 이 규모(소형 EKS + CloudTrail)면 월 몇 달러 수준.
# 확장 기능(S3 Protection, EKS Audit/Runtime Monitoring, Malware Protection)은
# 각각 과금이 추가되어 기본 탐지만 켠다 — 운영 전환 시 EKS Protection부터 검토.
# Finding 확인: 콘솔 GuardDuty > Findings, 또는
#   aws guardduty list-findings --detector-id $(terraform output -raw guardduty_detector_id) --region ap-northeast-2 --profile admin
# =============================================================================

resource "aws_guardduty_detector" "this" {
  enable = true

  # Finding을 EventBridge로 내보내는 주기 (알림 연동 시 사용). 기본값 6시간
  finding_publishing_frequency = "SIX_HOURS"
}

output "guardduty_detector_id" {
  value       = aws_guardduty_detector.this.id
  description = "GuardDuty detector ID — Finding 조회/확장 기능 활성화에 사용"
}
