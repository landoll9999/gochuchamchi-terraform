# ============================================================
# CloudWatch Observability Add-on용 Pod Identity
# ============================================================

module "cloudwatch_observability_pod_identity" {
  source = "terraform-aws-modules/eks-pod-identity/aws"

  name = "gochuchamchi-cloudwatch-observability"

  # CloudWatch에 메트릭과 로그를 전송할 IAM 권한
  attach_aws_cloudwatch_observability_policy = true

  associations = {
    cloudwatch_agent = {
      cluster_name    = module.eks.cluster_name
      namespace       = "amazon-cloudwatch"
      service_account = "cloudwatch-agent"
    }
  }
}


# ============================================================
# 현재 Kubernetes 버전에 맞는 최신 Add-on 버전 조회
# ============================================================

data "aws_eks_addon_version" "cloudwatch_observability" {
  addon_name         = "amazon-cloudwatch-observability"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}


# ============================================================
# Container Insights - Pod 애플리케이션 로그
# ============================================================

resource "aws_cloudwatch_log_group" "container_insights_application" {
  name = "/aws/containerinsights/${module.eks.cluster_name}/application"

  retention_in_days = var.container_insights_log_retention_days

  tags = {
    Name        = "${module.eks.cluster_name}-container-application-logs"
    Project     = "gochuchamchi"
    ManagedBy   = "Terraform"
    LogCategory = "application"
  }
}

# ============================================================
# Container Insights - 성능 원본 로그
# ============================================================

resource "aws_cloudwatch_log_group" "container_insights_performance" {
  name = "/aws/containerinsights/${module.eks.cluster_name}/performance"

  retention_in_days = var.container_insights_log_retention_days

  tags = {
    Name        = "${module.eks.cluster_name}-container-performance-logs"
    Project     = "gochuchamchi"
    ManagedBy   = "Terraform"
    LogCategory = "performance"
  }
}

# ============================================================
# Amazon CloudWatch Observability EKS Add-on 설치
# ============================================================

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = data.aws_eks_addon_version.cloudwatch_observability.version

  configuration_values = jsonencode({
    # Grafana 대시보드가 사용하는 기존 ContainerInsights 메트릭 생성
    containerInsights = {
      enabled = true
    }

    # 현재 Grafana 대시보드는 Classic Container Insights 메트릭과
    # kubernetes.* 로그 필드를 사용하므로 OTel 이중 발행은 비활성화
    otelContainerInsights = {
      enabled = false
    }

    # Pod stdout/stderr 로그 수집
    containerLogs = {
      enabled = true

      # 우선 우리 애플리케이션 Namespace 로그만 수집
      # includeNamespaces = [
      #   "gochuchamchi"
      # ]
    }
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    module.cloudwatch_observability_pod_identity,
    aws_cloudwatch_log_group.container_insights_application,
    aws_cloudwatch_log_group.container_insights_performance,
    aws_route.private_subnet
  ]
}
