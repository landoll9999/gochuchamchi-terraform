# =============================================================================
# 워크로드 데이터용 CMK — RDS/EFS/백업 (2026-08-07 main에서 이동)
#
# 왜 여기로 왔나 — 원래 ../terraform(일일 destroy 대상)에 있어서 키가 매일
# 죽고(7일 대기 예약) 태어났다(새 ARN). 두 가지가 문제였다:
#   1. DR 백업 복구 지점이 키보다 오래 산다 — 키가 소멸하면 백업이 있어도
#      복호화 불가("백업은 있는데 복원이 안 되는" DR 최악의 실패 모드)
#   2. ARN이 매일 바뀌어 외부 참조와 어긋날 수 있다 (8/6 503 유형)
#
# 이동 방식 — removed+import가 아니라 "코드 이동 + 재생성". baseline 55건과
# 달리 이 키는 어차피 매일 재생성되던 리소스라, 전체 재구축 시점에 태어나는
# 위치만 바꾸면 된다. 서명 KMS와 같은 계층에 두어 "키는 persistent" 일관성 확보.
#
# 참조 — ../terraform 은 별칭(alias/gochuchamchi-data)으로 조회한다
#        (persistent-data.tf). ARN 하드코딩 없음.
# =============================================================================

resource "aws_kms_key" "data" {
  description             = "gochuchamchi 워크로드 데이터 암호화 (RDS/EFS/백업)"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
    Name      = "gochuchamchi-data-cmk"
  }
}

resource "aws_kms_alias" "data" {
  name          = "alias/gochuchamchi-data"
  target_key_id = aws_kms_key.data.key_id
}

output "kms_data_key_arn" {
  description = "워크로드 데이터(RDS/EFS/백업) CMK ARN"
  value       = aws_kms_key.data.arn
}
