# =============================================================================
# 로그 계정 전용 KMS CMK — 중앙 로그 버킷 암호화
#
# ../account-baseline/kms-logs.tf 에서 이식. 그쪽 키는 Config 버킷 전용으로
# 축소되어 워크로드 계정에 남는다 — 즉 "logs 키"는 계정마다 하나씩, 총 2개.
#
# 크로스 계정 차이: Flow Logs 암호화 요청은 Workload 계정에서, Org Trail은
# Management 계정에서 온다. 둘 다 SourceAccount/SourceArn으로 제한한다.
# Config는 워크로드 계정 자기 버킷을 쓰므로 여기서는 허용하지 않는다.
# =============================================================================

resource "aws_kms_key" "logs" {
  description             = "gochuchamchi 로그 계정 중앙 아카이브 암호화 (CloudTrail/Firehose/Flow Logs)"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # 실습 환경 최소값. 운영 전환 시 30일 권장

  policy = data.aws_iam_policy_document.kms_logs.json

  tags = merge(
    local.cloudwatch_log_archive_tags,
    { Name = "gochuchamchi-logs-cmk" }
  )
}

resource "aws_kms_alias" "logs" {
  name          = "alias/gochuchamchi-logs"
  target_key_id = aws_kms_key.logs.key_id
}

data "aws_iam_policy_document" "kms_logs" {
  # 계정 루트 위임 — IAM 정책 기반 접근(assume한 admin의 Athena 조회 등)을
  # 가능하게 하는 표준 문구. 이게 없으면 키가 "관리 불가" 상태가 될 수 있다.
  statement {
    sid    = "EnableIAMPolicies"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Management 계정 소유 Org Trail이 로그 객체를 암호화할 때
  statement {
    sid    = "AllowCloudTrailEncrypt"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.cloudtrail_arn]
    }
  }

  # 워크로드 계정의 VPC Flow Logs S3 전달
  statement {
    sid    = "AllowLogDeliveryServices"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt"
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.workload_account_id]
    }
  }

  # 이 계정의 gochuchamchi-* IAM 역할(Firehose 전달 역할)이 버킷에 쓸 때.
  # baseline과 같은 이름 패턴 방식 — 역할 ARN 직접 참조는 순환 의존을 만든다.
  statement {
    sid    = "AllowProjectRoles"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "kms:GenerateDataKey*",
      "kms:Decrypt"
    ]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "aws:PrincipalArn"
      values   = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/gochuchamchi-*"]
    }
  }
}


# =============================================================================
# Outputs
# =============================================================================

output "kms_logs_key_arn" {
  description = "로그 계정 중앙 아카이브 CMK ARN"
  value       = aws_kms_key.logs.arn
}
