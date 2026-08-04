# =============================================================================
# GuardDuty — 계정 레벨 위협 "탐지" 계층
#   (2026-08-04 백로그 B6로 기본 탐지 도입 + 2026-08-03 full-HA의 기능 확장 복원 병합)
#
# CloudTrail(기록)·AWS Config(구성 감사)·Security Hub(점검)는 있었는데, 이상 행위를
# 능동 탐지하는 계층만 비어 있었다. 활성화하면 Security Hub와 자동 연동되어
# findings가 Security Hub 콘솔로도 흘러 들어간다 (별도 subscription 불필요).
#
# 탐지 소스와 이 프로젝트에서의 의미:
#   - CloudTrail 관리 이벤트: 비정상 API 호출 (예: 탈취된 액세스 키가 다른
#     리전에서 인스턴스를 만들려는 시도 — Region Guard(iam-security.tf)가 막고,
#     GuardDuty가 시도 자체를 탐지하는 이중 구조)
#   - VPC Flow Logs / DNS 로그: 포트 스캔, C2 통신, 코인 채굴 도메인 조회.
#     ※ GuardDuty는 flow-logs.tf와 무관하게 자체 수집분을 본다 — flow-logs.tf의
#     S3 저장분은 "GuardDuty finding이 뜬 뒤 Athena로 원본 추적"하는 용도(연계)
#   - EKS 감사 로그: 익명 접근, 특권 파드 생성, kube-system 침투 시도
#
# 💰 비용: 30일 무료 체험 후 CloudTrail 이벤트/로그량 기반 과금. 이 규모(노드
#    2대, 트래픽 소량)면 월 $1~5 수준. 시연 후 detector만 destroy하면 중단됨.
# Finding 확인: 콘솔 GuardDuty > Findings, 또는
#   aws guardduty list-findings --detector-id $(terraform output -raw guardduty_detector_id) --region ap-northeast-2 --profile admin
# =============================================================================

resource "aws_guardduty_detector" "this" {
  enable = true

  # 15분 간격 — 기본값(6시간)보다 빠르게 EventBridge로 finding 전달
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# --- 기능별 활성화 (프로바이더 v6 방식: datasources 블록 대신 feature 리소스) ---

# EKS 감사 로그 분석 — 클러스터 침투 행위 탐지의 핵심.
# main.tf에서 control plane audit 로그가 켜져 있지만, GuardDuty는 CloudWatch를
# 거치지 않고 EKS에서 직접 스트림을 받아 분석한다 (추가 로그 비용 없음).
resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.this.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

# S3 데이터 이벤트 — 이미지 버킷/로그 버킷에 대한 비정상 접근(대량 다운로드,
# 퍼블릭화 시도) 탐지. CloudTrail 데이터 이벤트를 따로 켤 필요 없이 동작.
resource "aws_guardduty_detector_feature" "s3_data_events" {
  detector_id = aws_guardduty_detector.this.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

# EBS 말웨어 스캔 — 다른 finding이 떴을 때 해당 인스턴스의 EBS 스냅샷을 떠서
# 말웨어를 검사 (상시 과금 아님, 스캔 발생 시 GB당 과금)
resource "aws_guardduty_detector_feature" "ebs_malware" {
  detector_id = aws_guardduty_detector.this.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}

# 런타임 모니터링 — 노드에 GuardDuty 에이전트(DaemonSet)를 깔아 프로세스/네트워크
# 시스콜 수준까지 탐지. t3.small 2대에는 메모리 부담(파드당 ~64Mi+)이 있어 기본 OFF.
# 켜려면 enable_guardduty_runtime_monitoring = true
resource "aws_guardduty_detector_feature" "runtime_monitoring" {
  count = var.enable_guardduty_runtime_monitoring ? 1 : 0

  detector_id = aws_guardduty_detector.this.id
  name        = "RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT" # GuardDuty가 에이전트 애드온을 직접 설치/관리
    status = "ENABLED"
  }
}

output "guardduty_detector_id" {
  description = "GuardDuty detector ID (검증: aws guardduty list-findings --detector-id <이 값>)"
  value       = aws_guardduty_detector.this.id
}
