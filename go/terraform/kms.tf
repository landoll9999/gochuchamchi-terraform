# =============================================================================
# KMS 키 — 이 계층에는 더 이상 없다 (2026-08-07)
#
#   logs 키  → ../account-baseline/kms-logs.tf  (CloudTrail/Config/Firehose용)
#   data 키  → ../persistent/kms-data.tf        (RDS/EFS/백업용)
#
# data 키를 persistent로 옮긴 이유 — 일일 destroy가 키를 매일 죽이면서(7일
# 대기 예약) ARN이 매일 바뀌었고, DR 백업 복구 지점이 키보다 오래 살아
# "백업은 있는데 복호화 키가 소멸"하는 실패 모드가 있었다. 키는 상시 계층에
# 한 번만 만들고, 여기서는 별칭으로 조회한다 (persistent-data.tf).
# =============================================================================

# 외부 스크립트/문서가 main output을 읽던 호환성 유지용 — 값은 persistent 키
output "kms_data_key_arn" {
  description = "워크로드 데이터 CMK ARN (실체는 ../persistent 관리)"
  value       = data.aws_kms_key.data.arn
}
