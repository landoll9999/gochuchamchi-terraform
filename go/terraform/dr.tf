# =============================================================================
# L8 복원력 — Tokyo(ap-northeast-1) DR (격차분석 §2.8, 계획 D20)
#
# 구성 (백업 기반 DR — pilot light 이전 단계):
#   1. AWS Backup 중앙 플랜: RDS + EFS 일일 스냅샷 → 도쿄 볼트로 크로스리전 복사
#   2. S3 CRR: 상품 이미지 버킷 → 도쿄 복제 버킷 (실시간 복제)
#
# 의도적으로 뺀 것 (사유):
#   - Route 53 페일오버 레코드: 도쿄에 상시 기동 standby 엔드포인트가 없으면
#     health check 대상이 없어 의미가 없다. 현재 전략은 "재해 시 도쿄에서
#     terraform apply로 재구축 + 백업 복원"이므로 DNS는 복구 시점에 전환한다.
#   - RDS Multi-AZ: 리전 내 가용성 항목이라 DR(리전 장애)와 별개. 비용 문제로
#     기존 결정(multi_az=false, rds.tf) 유지.
#
# RTO 목표 <4h의 산정 근거(측정 절차는 docs/2026-07-31-gap-closure.md):
#   재구축 apply ~40분 + RDS 스냅샷 복원(20GB) ~20분 + DNS 전파/검증 ≤ 1h
#   → 2h 이내 실측을 목표로 하고, 여유를 두어 4h를 공표값으로 유지.
#
# 💰 비용: 스냅샷 스토리지(GB·월) + 리전 간 전송. RDS 20GB + EFS 소량 기준
#    월 수 달러 수준. enable_dr=false로 끄면 볼트/플랜/CRR이 모두 제거된다.
# =============================================================================

provider "aws" {
  alias   = "tokyo"
  region  = "ap-northeast-1"
  profile = var.aws_profile
}

locals {
  # enable_dr 스위치를 파일 전체 리소스에 일괄 적용
  dr_count = var.enable_dr ? 1 : 0

  dr_tags = {
    Project   = "gochuchamchi"
    Component = "dr"
  }
}


# =============================================================================
# 1. AWS Backup — 서울 볼트(원본) + 도쿄 볼트(사본)
# =============================================================================

# 도쿄 볼트 암호화용 CMK. 크로스리전 복사본은 대상 리전 키로 재암호화되므로
# 대상 리전에도 CMK가 있어야 "전 구간 CMK" 원칙(kms.tf)이 유지된다.
resource "aws_kms_key" "dr" {
  count    = local.dr_count
  provider = aws.tokyo

  description             = "gochuchamchi DR 백업 볼트 암호화 (Tokyo)"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
    Name      = "gochuchamchi-dr-cmk"
  }
}

resource "aws_backup_vault" "seoul" {
  count = local.dr_count

  name        = "gochuchamchi-backup-vault"
  kms_key_arn = data.aws_kms_key.data.arn

  # 볼트 안에 복구 지점이 남아 있으면 destroy가 막힌다. 실습 환경이라 자동 정리.
  force_destroy = true

  tags = local.dr_tags
}

resource "aws_backup_vault" "tokyo" {
  count    = local.dr_count
  provider = aws.tokyo

  name          = "gochuchamchi-dr-vault"
  kms_key_arn   = aws_kms_key.dr[0].arn
  force_destroy = true

  tags = local.dr_tags
}

# Backup 서비스가 RDS 스냅샷/EFS 백업을 만들 IAM 역할 (AWS 관리형 정책 사용)
resource "aws_iam_role" "backup" {
  count = local.dr_count

  name = "gochuchamchi-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = var.enable_dr ? toset([
    "AWSBackupServiceRolePolicyForBackup",
    "AWSBackupServiceRolePolicyForRestores",
  ]) : toset([])

  role       = aws_iam_role.backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/${each.value}"
}

resource "aws_backup_plan" "daily" {
  count = local.dr_count

  name = "gochuchamchi-daily-dr"

  rule {
    rule_name         = "daily-with-tokyo-copy"
    target_vault_name = aws_backup_vault.seoul[0].name
    # 03:00 KST (18:00 UTC) — 트래픽 최저 시간대
    schedule          = "cron(0 18 * * ? *)"
    start_window      = 60  # 분
    completion_window = 180 # 분

    lifecycle {
      delete_after = var.dr_backup_retention_days
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.tokyo[0].arn

      lifecycle {
        delete_after = var.dr_backup_retention_days
      }
    }
  }

  tags = local.dr_tags
}

resource "aws_backup_selection" "rds_efs" {
  count = local.dr_count

  name         = "gochuchamchi-rds-efs"
  plan_id      = aws_backup_plan.daily[0].id
  iam_role_arn = aws_iam_role.backup[0].arn

  resources = [
    module.rds.db_instance_arn,
    aws_efs_file_system.this.arn
  ]
}


# =============================================================================
# 2. S3 CRR — 상품 이미지 버킷을 도쿄로 실시간 복제
#    (CRR은 양쪽 모두 버전관리가 켜져 있어야 동작 -> s3.tf에 versioning 추가됨)
# =============================================================================

resource "aws_s3_bucket" "images_dr" {
  count    = local.dr_count
  provider = aws.tokyo

  bucket = "gochuchamchi-images-dr-${data.aws_caller_identity.current.account_id}"

  # 원본과 같은 사유(BucketNotEmpty)로 자동 비우기
  force_destroy = true

  tags = local.dr_tags
}

resource "aws_s3_bucket_versioning" "images_dr" {
  count    = local.dr_count
  provider = aws.tokyo

  bucket = aws_s3_bucket.images_dr[0].id

  versioning_configuration {
    status = "Enabled"
  }
}

# 복제본은 평시 접근할 일이 없으므로 전부 차단. 실제 페일오버 때
# 원본(s3.tf)과 같은 public-read 정책을 적용하는 절차가 복구 런북에 있다.
resource "aws_s3_bucket_public_access_block" "images_dr" {
  count    = local.dr_count
  provider = aws.tokyo

  bucket = aws_s3_bucket.images_dr[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "s3_replication" {
  count = local.dr_count

  name = "gochuchamchi-s3-crr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "s3_replication" {
  count = local.dr_count

  name = "gochuchamchi-s3-crr"
  role = aws_iam_role.s3_replication[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadSource"
        Effect = "Allow"
        Action = [
          "s3:GetReplicationConfiguration",
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.images.arn
      },
      {
        Sid    = "ReadSourceObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObjectVersionForReplication",
          "s3:GetObjectVersionAcl",
          "s3:GetObjectVersionTagging"
        ]
        Resource = "${aws_s3_bucket.images.arn}/*"
      },
      {
        Sid    = "WriteDestination"
        Effect = "Allow"
        Action = [
          "s3:ReplicateObject",
          "s3:ReplicateDelete",
          "s3:ReplicateTags"
        ]
        Resource = "${aws_s3_bucket.images_dr[0].arn}/*"
      }
    ]
  })
}

resource "aws_s3_bucket_replication_configuration" "images" {
  count = local.dr_count

  bucket = aws_s3_bucket.images.id
  role   = aws_iam_role.s3_replication[0].arn

  rule {
    id     = "replicate-all-to-tokyo"
    status = "Enabled"

    filter {}

    delete_marker_replication {
      status = "Enabled"
    }

    destination {
      bucket        = aws_s3_bucket.images_dr[0].arn
      storage_class = "STANDARD_IA" # 평시 읽지 않는 복제본이라 저렴한 클래스로
    }
  }

  # 원본 버킷 versioning이 먼저 켜져 있어야 함 (s3.tf)
  depends_on = [
    aws_s3_bucket_versioning.images,
    aws_s3_bucket_versioning.images_dr
  ]
}


# =============================================================================
# Outputs
# =============================================================================

output "dr_backup_vault_tokyo_arn" {
  description = "도쿄 DR 백업 볼트 ARN (enable_dr=true일 때만)"
  value       = var.enable_dr ? aws_backup_vault.tokyo[0].arn : null
}

output "dr_images_bucket_name" {
  description = "도쿄 이미지 복제 버킷 (enable_dr=true일 때만)"
  value       = var.enable_dr ? aws_s3_bucket.images_dr[0].bucket : null
}
