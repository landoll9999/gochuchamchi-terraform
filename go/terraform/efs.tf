# =============================================================================
# EFS — EKS Pod가 마운트하는 공유 스토리지
#   - private_subnets(= var.azs = 2a, 2c)마다 mount target을 하나씩 생성
#   - aws-efs-csi-driver addon(main.tf) + Pod Identity(eks-pod-identity.tf)로
#     Pod가 PVC를 통해 동적으로 볼륨을 프로비저닝(efs-ap 모드, 액세스포인트 자동 생성)
# =============================================================================

resource "aws_efs_file_system" "this" {
  creation_token = "gochuchamchi-efs"
  encrypted      = true
  # (2026-08-07 복원) 전 구간 KMS CMK 원칙 적용. 키는 persistent 계층에 있어
  # 일일 destroy와 무관하게 ARN이 고정된다 — "키 변경 = 파일시스템 교체" 리스크는
  # 키가 매일 순환하던 구조의 문제였고, 이제 구조적으로 소멸.
  kms_key_id       = data.aws_kms_key.data.arn
  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = {
    Name = "gochuchamchi-efs"
  }
}

module "efs_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-efs-sg"
  description = "EFS accessible only from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress_rules = {
    nfs_from_nodes = {
      from_port                    = 2049
      to_port                      = 2049
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.eks.node_security_group_id
      description                  = "NFS from EKS nodes only"
    }
  }
  egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
}

# private_subnets[0]/[1]이 각각 var.azs[0]/[1] (ap-northeast-2a / 2c)에 대응 -> 자동으로 두 AZ 모두 커버
resource "aws_efs_mount_target" "this" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [module.efs_sg.id]
}

# 동적 프로비저닝용 StorageClass. PVC를 만들면 efs-csi-driver가 이 파일시스템 안에
# 액세스포인트를 자동 생성해줌 (PVC마다 독립된 디렉터리) - 실제 PVC/Deployment volume
# 마운트는 gochuchamchi-gitops 저장소에서 필요할 때 추가.
resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs-sc"
  }

  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.this.id
    directoryPerms   = "700"
  }

  # module.eks(전체)를 명시해야 access_entries(admin cluster-admin 권한 부여)까지 기다림.
  # EFS mount target/pod identity는 빨리 끝나는 리소스라 이게 없으면 access entry가
  # API 서버 인증 웹훅에 전파되기 전에 먼저 요청이 나가서 403 Forbidden이 남
  # (2026-07-29 실제로 겪음: "cannot create resource storageclasses ... at the cluster scope").
  depends_on = [aws_efs_mount_target.this, module.efs_csi_pod_identity, module.eks]
}

output "efs_file_system_id" {
  value       = aws_efs_file_system.this.id
  description = "PVC의 volumeAttributes / StorageClass parameters.fileSystemId로 참조되는 EFS 파일시스템 ID"
}
