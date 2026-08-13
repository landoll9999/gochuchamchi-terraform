# Bastion EC2용 IAM Role & Instance Profile
resource "aws_iam_role" "bastion_role" {
  name = "gochuchamchi-bastion-eks-admin-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# aws eks update-kubeconfig 를 위한 최소 권한
resource "aws_iam_role_policy" "bastion_eks_describe" {
  name = "gochuchamchi-bastion-eks-describe-policy"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "*"
      }
    ]
  })
}

# DB 자격증명 접근 권한
# (2026-08-04 제로트러스트) 기존 rds!* 와일드카드는 "리전 안의 모든 RDS 관리형 마스터
# 시크릿"을 읽을 수 있는 과잉 권한이었음 -> 이 스택이 실제로 쓰는 시크릿 2개의 정확한
# ARN으로 축소. 배스천이 털려도 다른 DB 시크릿까지 번지지 않게 폭발 반경을 줄이는 것.
#   - 마스터: 스키마 초기화(rds-schema-init.tf)·IAM 계정 생성(db-zero-trust.tf)의 읽기 전용
# (2026-08-13) 앱 시크릿 항목이 사라졌다. IAM 토큰 전환으로 앱 비밀번호라는 것이
# 없어졌고, 배스천의 secretsmanager 쓰기 권한도 함께 사라져 읽기 하나만 남았다.
resource "aws_iam_role_policy" "bastion_secrets_read" {
  name = "gochuchamchi-bastion-secrets-read-policy"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "MasterSecretReadOnly"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = module.rds.db_instance_master_user_secret_arn
      }
      # (2026-08-13) AppSecretManage 문장을 제거했다. 배스천이 앱 비밀번호를 만들어
      # 시크릿에 Put 하던 권한인데, IAM 토큰 전환으로 그 시크릿도 그 절차도 없어졌다.
      # 배스천은 이제 마스터 시크릿만 읽는다 — 스키마 초기화와 IAM 계정 생성용이다.
      # 쓰기(Put) 권한이 통째로 사라진 것이 이 변경의 부수 효과다.
    ]
  })
}

# 기존 프로젝트에서 쓰던 SSM Session Manager 접속 방식을 Bastion에도 그대로 적용
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion_instance_profile" {
  name = "gochuchamchi-bastion-instance-profile"
  role = aws_iam_role.bastion_role.name
}

# ---------------------------------------------------------------------------
# NAT 인스턴스용 IAM Role & Instance Profile (디버깅용 SSM 접속)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "nat_role" {
  name = "gochuchamchi-nat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat_instance_profile" {
  name = "gochuchamchi-nat-instance-profile"
  role = aws_iam_role.nat_role.name
}
