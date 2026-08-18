# =============================================================================
# 계정 수준 하드닝 — EBS 기본 암호화 · 스냅샷 공개 차단 · S3 계정 퍼블릭 차단
#
# (2026-08-10 v8 병합) 원래 main 브랜치의 terraform/ebs-encryption.tf 와
# terraform/s3.tf 에 있던 것을 이 계층으로 이식했다.
#
# 왜 account-baseline 인가 — 분류 기준 그대로:
#   셋 다 계정/리전 싱글턴이라 "지워도 비용이 안 줄면서, 매일 destroy 계층에
#   있으면 매일 껐다 켜는 무의미한 사이클"이 된다. CloudTrail·GuardDuty와
#   같은 부류.
# =============================================================================

# ---------------------------------------------------------------------------
# EBS default encryption
#
# 이 AWS 계정의 현재 리전에서 새로 생성되는 EBS 볼륨과 스냅샷 복사본을
# 기본적으로 암호화한다. 별도 고객 관리형 KMS 키를 만들지 않으므로,
# 변경하지 않았다면 AWS 관리형 기본 키(alias/aws/ebs)가 사용된다.
# 기존 EBS 볼륨과 스냅샷의 암호화 상태는 변경하지 않는다.
# ---------------------------------------------------------------------------
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# 기존 공개 스냅샷을 포함해 EBS 스냅샷의 공개 공유를 리전 수준에서 차단한다.
# 특정 AWS 계정에 대한 비공개 공유는 계속 허용된다.
resource "aws_ebs_snapshot_block_public_access" "this" {
  state = "block-all-sharing"
}

# ---------------------------------------------------------------------------
# S3 계정 수준 퍼블릭 차단 — 현재/미래의 모든 버킷에 적용 (전 리전)
#
# 이미지 버킷은 CloudFront OAC(SourceArn 조건 서비스 프린시펄) 정책이라
# "퍼블릭 정책"으로 분류되지 않는다 → 이 차단과 충돌 없음.
# main 브랜치에 있던 depends_on(이미지 정책 선행)은 "퍼블릭 정책이 남아 있는
# 계정에서 차단을 켜는" 마이그레이션 순서 방어였고, 매일 새로 짓는 이 구조에서는
# 필요 없다. 단, 이 계층을 처음 apply하는 시점에 구(舊) 퍼블릭 정책이 계정에
# 살아 있으면 안 된다 — 메인 스택이 v8 s3.tf(OAC 정책)로 apply된 뒤에 적용할 것.
# ---------------------------------------------------------------------------
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# IMDSv2 계정 기본값 (2026-08-18, Prowler 감사 ec2_instance_account_imdsv2_enabled)
#
# 왜 — 모든 인스턴스(EKS 노드·bastion·NAT)는 launch template에서 이미 명시적으로
# http_tokens=required 지만, "계정 기본값"은 미설정이었다. 명시적 설정을 빠뜨린
# 인스턴스가 실수로 새로 생기면 IMDSv1(토큰 없는 SSRF 자격증명 탈취)로 열린다.
# 이 기본값은 그런 인스턴스에만 적용되고, metadata_options를 명시한 기존 인스턴스는
# 인스턴스 설정이 우선하므로 영향이 없다 — 순수한 미래 안전망이다.
#
# hop_limit·tags는 지정하지 않는다(no-preference) — 인스턴스별 설정(노드=1)을
# 존중하고, 여기서는 IMDSv2 강제(http_tokens)만 계정 차원에서 보증한다.
# ---------------------------------------------------------------------------
resource "aws_ec2_instance_metadata_defaults" "this" {
  http_tokens   = "required"
  http_endpoint = "enabled"
}
