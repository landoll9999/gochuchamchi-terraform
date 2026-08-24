# data.aws_eks_cluster_auth 토큰은 plan 시점에 1회 발급되고 15분 만료라, helm_release가
# 여러 개 있고 timeout=600까지 겹치면 apply 도중 Unauthorized가 남 -> exec 플러그인으로
# 전환해서 호출 시마다(각 provider 호출마다) aws eks get-token으로 새 토큰을 받는다.
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = ["eks", "get-token",
        "--cluster-name", var.cluster_name,
        "--region", var.region,
      "--profile", var.aws_profile]
    }
  }
}

# ArgoCD/Image Updater 등 k8s 오브젝트를 배스천 없이 로컬에서 직접 적용하기 위한 프로바이더.
# 인증 정보는 위 helm 프로바이더와 동일 (enable_cluster_creator_admin_permissions로
# terraform apply를 실행하는 IAM 주체가 이미 클러스터 admin이라 별도 access entry 불필요).
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = ["eks", "get-token",
      "--cluster-name", var.cluster_name,
      "--region", var.region,
    "--profile", var.aws_profile]
  }
}

# ---------------------------------------------------------------------------
# AWS Load Balancer Controller (Ingress -> ALB 자동 생성)
# ---------------------------------------------------------------------------
module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # (v8) 버전 핀
  name    = "gochuchamchi-alb-controller"

  attach_aws_lb_controller_policy = true

  associations = {
    alb_controller = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  cleanup_on_fail = true
  # destroy 시 이 컨트롤러가 살아있는 동안 AWS API에 닿을 수 있어야 ALB/타겟그룹을
  # 정리하고 Ingress finalizer를 뗄 수 있다. 경로가 하나라도 먼저 끊기면 교착이 생김.
  #   - module.nat_instance / aws_route.private_subnet
  #       : private subnet -> NAT 경로 (2026-07-29 1차 교착의 원인이었음)
  #   - module.vpc (모듈 전체)
  #       : NAT 인스턴스가 있는 public subnet -> IGW 경로. set 블록에서
  #         module.vpc.vpc_id를 참조하므로 VPC "리소스" 자체와는 순서가 잡히지만,
  #         모듈 안의 public 라우트 테이블까지는 순서가 안 잡혀서 먼저 삭제됨
  #         -> NAT가 인터넷으로 못 나가 컨트롤러 API 호출이 전부 타임아웃
  #            (2026-07-29 2차 교착의 원인). 모듈 전체를 명시해서 순서를 고정.
  #   - module.nat_sg / module.add_node_sg (모듈 전체)
  #       : SG "그룹"과 SG "규칙"은 별개 리소스다. module.eks가 add_node_sg.id를,
  #         nat_instance가 nat_sg.id를 참조하지만 그건 aws_security_group 리소스에만
  #         순서를 걸 뿐, 같은 모듈 안의 aws_vpc_security_group_*_rule 은 아무도
  #         참조하지 않아 언제든 먼저 삭제된다. 실제로 규칙만 0개가 되어
  #         NAT가 트래픽을 못 받고/못 내보내 컨트롤러 API 호출이 전부 타임아웃됨
  #         (2026-07-30 3차 교착의 원인). module.vpc과 똑같은 이유·똑같은 해법.
  depends_on = [
    module.aws_lb_controller_pod_identity,
    module.eks,
    module.nat_instance,
    aws_route.private_subnet,
    module.vpc,
    module.nat_sg,
    module.add_node_sg,
  ]

  set = [
    { name = "clusterName", value = module.eks.cluster_name },
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "aws-load-balancer-controller" },
    { name = "vpcId", value = module.vpc.vpc_id },
    { name = "region", value = var.region },
  ]
}

# ---------------------------------------------------------------------------
# ExternalDNS (Ingress 생성 시 gochuchamchi.shop 레코드를 Route53에 자동 등록)
# ---------------------------------------------------------------------------
module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # (v8) 버전 핀
  name    = "gochuchamchi-external-dns"

  attach_external_dns_policy = true
  # 계정 내 전체 호스팅존이 아니라 gochuchamchi.shop 존 하나로 제한
  external_dns_hosted_zone_arns = [
    "arn:aws:route53:::hostedzone/${data.aws_route53_zone.this.zone_id}"
  ]

  associations = {
    external_dns = {
      cluster_name    = module.eks.cluster_name
      namespace       = "external-dns"
      service_account = "external-dns"
    }
  }
}

resource "helm_release" "external_dns" {
  name             = "external-dns"
  repository       = "https://kubernetes-sigs.github.io/external-dns/"
  chart            = "external-dns"
  namespace        = "external-dns"
  create_namespace = true

  cleanup_on_fail = true
  # aws-load-balancer-controller의 mutating webhook이 클러스터 전역 Service 생성을
  # 가로채므로, 그 컨트롤러 파드가 준비되기 전에 Service를 만들면
  # "no endpoints available for service aws-load-balancer-webhook-service" 에러가 남
  depends_on = [module.external_dns_pod_identity, module.eks, helm_release.aws_load_balancer_controller]

  set = [
    { name = "serviceAccount.create", value = "true" },
    { name = "serviceAccount.name", value = "external-dns" },
    { name = "provider", value = "aws" },
    { name = "domainFilters[0]", value = var.domain_name },
    { name = "policy", value = "upsert-only" }, # 안전하게 생성/수정만, 삭제는 수동으로
    { name = "txtOwnerId", value = module.eks.cluster_name },
  ]
}

# ---------------------------------------------------------------------------
# Cluster Autoscaler (파드가 스케줄 못 될 때 노드그룹 min/max 범위 안에서 자동 증감)
# ---------------------------------------------------------------------------
module "cluster_autoscaler_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # (v8) 버전 핀
  name    = "gochuchamchi-cluster-autoscaler"

  attach_cluster_autoscaler_policy = true
  cluster_autoscaler_cluster_names = [module.eks.cluster_name]

  associations = {
    cluster_autoscaler = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "cluster-autoscaler"
    }
  }
}

# ---------------------------------------------------------------------------
# argocd-image-updater가 ECR 인증 토큰을 발급받기 위한 Pod Identity
#   (argocd.tf의 argocd_image_updater 인증 스크립트가 이 권한으로 `aws ecr
#    get-login-password`를 실행함)
# ---------------------------------------------------------------------------
module "image_updater_ecr_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # (v8) 버전 핀
  name    = "gochuchamchi-image-updater-ecr"

  additional_policy_arns = {
    ecr_read_only = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }

  associations = {
    image_updater = {
      cluster_name    = module.eks.cluster_name
      namespace       = "argocd"
      service_account = "argocd-image-updater"
    }
  }
}

resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"

  cleanup_on_fail = true
  # 다른 helm_release들과 동일하게, destroy 시 NAT보다 먼저 정리되도록 순서 고정
  depends_on = [module.cluster_autoscaler_pod_identity, module.eks, module.nat_instance, aws_route.private_subnet]

  set = [
    { name = "autoDiscovery.clusterName", value = module.eks.cluster_name },
    { name = "awsRegion", value = var.region },
    { name = "rbac.serviceAccount.create", value = "true" },
    { name = "rbac.serviceAccount.name", value = "cluster-autoscaler" },
  ]
}

# ---------------------------------------------------------------------------
# EFS CSI Driver (Pod가 EFS를 PV/PVC로 마운트할 수 있게 함)
#   서비스어카운트 이름(efs-csi-controller-sa)은 aws-efs-csi-driver addon 기본값과 일치해야 함
# ---------------------------------------------------------------------------
module "efs_csi_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0" # (v8) 버전 핀
  name    = "gochuchamchi-efs-csi"

  attach_aws_efs_csi_policy = true

  associations = {
    efs_csi = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "efs-csi-controller-sa"
    }
  }
}

# ---------------------------------------------------------------------------
# 앱(Spring Boot Pod)용 Pod Identity
#   - S3(gochuchamchi-images) 업로드 권한
#   - RDS 비밀번호가 들어있는 Secrets Manager 조회 권한
#   기존 EC2 시절 web_role과 동일한 최소권한 철학을 그대로 K8s ServiceAccount에 이식
# ---------------------------------------------------------------------------
resource "aws_iam_policy" "gochuchamchi_app_policy" {
  name = "gochuchamchi-app-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ProductImageUploadOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.images.arn}/products/*"]
      }
      # (2026-08-13) AppDbSecretRead 문장을 제거했다.
      #   원래는 앱 DB 비밀번호가 든 시크릿을 앱이 읽을 수 있게 열어둔 것이었다
      #   (8/4 에 rds!* 와일드카드를 이 시크릿 1개로 좁힌 흔적). IAM 토큰 전환으로
      #   그 시크릿 자체가 없어졌으므로 읽을 대상이 존재하지 않는다.
      #   앱의 DB 자격증명은 이제 secretsmanager 가 아니라 rds-db:connect 로 받는다
      #   (db-zero-trust.tf 의 app_db_iam_auth 정책).
    ]
  })
}

resource "aws_iam_role" "gochuchamchi_app_role" {
  name = "gochuchamchi-app-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["sts:AssumeRole", "sts:TagSession"]
        Principal = { Service = "pods.eks.amazonaws.com" }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gochuchamchi_app_attach" {
  role       = aws_iam_role.gochuchamchi_app_role.name
  policy_arn = aws_iam_policy.gochuchamchi_app_policy.arn
}

resource "aws_eks_pod_identity_association" "gochuchamchi_app" {
  cluster_name    = module.eks.cluster_name
  namespace       = "gochuchamchi"
  service_account = "gochuchamchi-app"
  role_arn        = aws_iam_role.gochuchamchi_app_role.arn
}

# 신규 Web 경로는 기존 App 경로를 이름 변경하지 않고 병행 생성한다. 첫 apply에서
# 구 Pod Identity를 제거하면 신규 Deployment가 Ready 되기 전에 현재 서비스의 DB/S3
# 연결이 끊길 수 있기 때문이다. 레거시 리소스는 전환 검증 후 별도 정리한다.
resource "aws_iam_policy" "gochuchamchi_web_policy" {
  name = "gochuchamchi-web-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "S3ProductImageUploadOnly"
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = ["${aws_s3_bucket.images.arn}/products/*"]
    }]
  })
}

resource "aws_iam_role" "gochuchamchi_web_role" {
  name = "gochuchamchi-web-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "pods.eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gochuchamchi_web_attach" {
  role       = aws_iam_role.gochuchamchi_web_role.name
  policy_arn = aws_iam_policy.gochuchamchi_web_policy.arn
}

resource "aws_eks_pod_identity_association" "gochuchamchi_web" {
  cluster_name    = module.eks.cluster_name
  namespace       = "gochuchamchi"
  service_account = "gochuchamchi-web"
  role_arn        = aws_iam_role.gochuchamchi_web_role.arn
}

# Admin은 S3 업로드 등 일반 웹 기능의 AWS 권한을 상속하지 않는다. DB 연결 권한은
# db-zero-trust.tf에서 admin DB 사용자 ARN 하나에만 별도로 붙인다.
resource "aws_iam_role" "gochuchamchi_admin_role" {
  name = "gochuchamchi-admin-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Principal = { Service = "pods.eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_policy" "gochuchamchi_admin_product_image_policy" {
  name = "gochuchamchi-admin-product-image-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AdminProductImageUploadOnly"
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = ["${aws_s3_bucket.images.arn}/products/*"]
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gochuchamchi_admin_product_image" {
  role       = aws_iam_role.gochuchamchi_admin_role.name
  policy_arn = aws_iam_policy.gochuchamchi_admin_product_image_policy.arn
}

resource "aws_eks_pod_identity_association" "gochuchamchi_admin" {
  cluster_name    = module.eks.cluster_name
  namespace       = "gochuchamchi"
  service_account = "gochuchamchi-admin"
  role_arn        = aws_iam_role.gochuchamchi_admin_role.arn
}
