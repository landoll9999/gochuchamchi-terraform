# GuardDuty·Security Hub 위임 관리자 지정 (Management 계정에서만 가능한 작업).
#
# 지정 후 실제 조직 단위 설정(멤버 자동 등록, 탐지기 기능 구성, finding 트리아지
# 파이프라인)은 전부 위임 대상인 Security/Log 계정에서 수행한다. 이 파일의 책임은
# "누가 조직 전체 보안 서비스를 관리하는가"를 정하는 것까지다.
#
# 주의: GuardDuty와 Security Hub는 리전별 서비스라 아래 지정은 var.region
# (기본 ap-northeast-2) 한 곳에만 적용된다. 다른 리전에서 발생한 finding은
# 중앙에 모이지 않으므로, 리전을 늘릴 때는 provider alias를 추가해야 한다.

# Management 계정 자신의 탐지기.
# 위임 관리자는 멤버 계정을 자동 등록할 수 있지만 Organizations 관리 계정은
# 자동 등록 대상이 아니라서, Management 계정 탐지 사각지대를 없애려면 여기서
# 직접 켜야 한다. 위임 관리자 지정 API의 선행 조건이기도 하다.
resource "aws_guardduty_detector" "management" {
  count = var.enable_security_services_delegation ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_organization_admin_account" "log_archive" {
  count = var.enable_security_services_delegation ? 1 : 0

  admin_account_id = var.log_archive_account_id

  depends_on = [
    aws_organizations_organization.this,
    aws_guardduty_detector.management,
  ]
}

# Security Hub도 동일한 이유로 Management 계정에서 먼저 활성화한다.
resource "aws_securityhub_account" "management" {
  count = var.enable_security_services_delegation ? 1 : 0
}

resource "aws_securityhub_organization_admin_account" "log_archive" {
  count = var.enable_security_services_delegation ? 1 : 0

  admin_account_id = var.log_archive_account_id

  depends_on = [
    aws_organizations_organization.this,
    aws_securityhub_account.management,
  ]
}
