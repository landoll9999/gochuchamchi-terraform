# =============================================================================
# 공통 설정
# =============================================================================

locals {
  grafana_https_enabled = try(trimspace(var.certificate_arn), "") != ""

  grafana_root_url = (
    local.grafana_https_enabled
    ? "https://${var.grafana_hostname}"
    : "http://${var.grafana_hostname}"
  )

  grafana_tags = merge(
    {
      Project   = "gochuchamchi"
      ManagedBy = "Terraform"
      Component = "grafana"
    },
    var.tags
  )

  grafana_ingress_annotations = merge(
    tomap({
      "alb.ingress.kubernetes.io/group.name"       = var.alb_group_name
      "alb.ingress.kubernetes.io/group.order"      = "30"
      "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"      = "ip"
      "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"

      "alb.ingress.kubernetes.io/healthcheck-path"     = "/api/health"
      "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTP"
      "alb.ingress.kubernetes.io/success-codes"        = "200"

      "external-dns.alpha.kubernetes.io/hostname" = var.grafana_hostname
    }),

    local.grafana_https_enabled
    ? tomap({
      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([
        {
          HTTP = 80
        },
        {
          HTTPS = 443
        }
      ])

      "alb.ingress.kubernetes.io/certificate-arn" = var.certificate_arn
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
    })
    : tomap({
      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([
        {
          HTTP = 80
        }
      ])
    })
  )
}


# =============================================================================
# monitoring Namespace
# =============================================================================

resource "kubernetes_namespace_v1" "monitoring" {
  metadata {
    name = var.namespace

    labels = {
      name       = var.namespace
      monitoring = "enabled"
    }
  }
}


# =============================================================================
# Grafana ServiceAccount
# =============================================================================

resource "kubernetes_service_account_v1" "grafana" {
  metadata {
    name      = var.service_account_name
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    labels = {
      app = "grafana"
    }
  }

  automount_service_account_token = true
}


# =============================================================================
# EKS Pod Identity IAM Role 신뢰 정책
# =============================================================================

data "aws_iam_policy_document" "grafana_pod_identity_assume_role" {
  statement {
    sid    = "AllowEksPodIdentity"
    effect = "Allow"

    principals {
      type = "Service"

      identifiers = [
        "pods.eks.amazonaws.com"
      ]
    }

    actions = [
      "sts:AssumeRole",
      "sts:TagSession"
    ]
  }
}


# =============================================================================
# Grafana IAM Role
# =============================================================================

resource "aws_iam_role" "grafana" {
  name = "${var.cluster_name}-grafana-cloudwatch"

  # IAM description은 ASCII + Latin-1( -~, ¡-ÿ)만 허용해서
  # 한글을 넣으면 CreateRole이 ValidationError로 실패함 -> 영문으로 유지할 것.
  # (다른 리소스의 description/태그는 유니코드가 되지만 IAM만 예외)
  description = (
    "IAM role for Grafana pods to read CloudWatch metrics and logs"
  )

  assume_role_policy = (
    data.aws_iam_policy_document
    .grafana_pod_identity_assume_role
    .json
  )

  tags = merge(
    local.grafana_tags,
    {
      Name = "${var.cluster_name}-grafana-cloudwatch"
    }
  )
}


# =============================================================================
# CloudWatch Metrics 및 Logs 조회 권한
# =============================================================================

data "aws_iam_policy_document" "grafana_cloudwatch" {
  statement {
    sid    = "ReadCloudWatchMetrics"
    effect = "Allow"

    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ReadCloudWatchLogs"
    effect = "Allow"

    actions = [
      "logs:DescribeLogGroups",
      "logs:GetLogGroupFields",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogEvents"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ReadAwsResourceInformation"
    effect = "Allow"

    actions = [
      "ec2:DescribeRegions",
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
      "tag:GetResources"
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ReadRdsPerformanceInsights"
    effect = "Allow"

    actions = [
      "pi:GetResourceMetrics"
    ]

    resources = ["*"]
  }

  # ---------------------------------------------------------------------------
  # (2026-08-19) Log 계정 조회 역할 전환
  #
  # Grafana 파드는 워크로드 계정에 있고 통합 로그 뷰(security_events)는 Log
  # 계정에 있다. 파드가 그 뷰를 보려면 Log 계정 역할로 전환해야 한다.
  #
  # 대상을 특정 ARN 하나로 못박는다. Resource = "*"로 두면 신뢰 관계만 맞으면
  # 어떤 역할로도 전환할 수 있게 되는데, 그건 대시보드 도구에 줄 권한이 아니다.
  # ---------------------------------------------------------------------------
  dynamic "statement" {
    for_each = trimspace(var.athena_reader_role_arn) != "" ? [1] : []

    content {
      sid    = "AssumeLogAccountReaderRole"
      effect = "Allow"

      # Athena 데이터소스 플러그인은 AssumeRole에 세션 태그를 붙이므로
      # TagSession도 함께 허용해야 한다 (없으면 AssumeRole은 통과해도
      # sts:TagSession에서 403 AccessDenied — 2026-08-19 실측).
      # 대칭으로 Log 계정 reader 역할의 신뢰 정책에도 sts:TagSession이 있어야 한다.
      actions = ["sts:AssumeRole", "sts:TagSession"]

      resources = [var.athena_reader_role_arn]
    }
  }
}

resource "aws_iam_role_policy" "grafana_cloudwatch" {
  name = "${var.cluster_name}-grafana-cloudwatch-read"
  role = aws_iam_role.grafana.id

  policy = data.aws_iam_policy_document.grafana_cloudwatch.json
}


# =============================================================================
# Grafana ServiceAccount와 IAM Role 연결
# =============================================================================

resource "aws_eks_pod_identity_association" "grafana" {
  cluster_name = var.cluster_name
  namespace    = kubernetes_namespace_v1.monitoring.metadata[0].name

  service_account = (
    kubernetes_service_account_v1.grafana.metadata[0].name
  )

  role_arn = aws_iam_role.grafana.arn
}


# Pod Identity 자격증명 주입은 파드가 "생성되는 순간" EKS admission이 한 번만 한다
# (AWS_CONTAINER_CREDENTIALS_FULL_URI + eks-pod-identity-token 볼륨). 그런데 위
# association은 API가 200을 돌려준 뒤에도 admission 쪽에 반영되기까지 시간이 걸린다.
# depends_on은 "Terraform이 association 생성을 끝냈다"까지만 보장하므로, 바로 다음
# 스텝인 helm_release가 그 갭 안에서 파드를 띄우면 주입이 통째로 누락된다. 주입 기회는
# 파드 생성 시 1회뿐이라, 이후 association이 전파돼도 그 파드는 끝까지 자격증명이 없다.
#   -> AWS SDK가 자격증명 체인 끝의 IMDS로 폴백 -> "no EC2 IMDS role found"
#   -> CloudWatch 데이터소스가 GetMetricData 실패 -> 대시보드 전 패널 No data
# 2026-08-06 실제 장애. depends_on이 이미 걸려 있었는데도 발생했다(RS가 1개뿐인
# 최초 배포 파드에 env·볼륨이 둘 다 없었음). s3.tf의 wait_for_public_access_block과
# 같은 뿌리 — 그래프상 순서 != 실제 전파 완료.
resource "time_sleep" "grafana_pod_identity_propagation" {
  depends_on      = [aws_eks_pod_identity_association.grafana]
  create_duration = "30s"
}


# =============================================================================
# Grafana Helm 설치
# =============================================================================

resource "helm_release" "grafana" {
  name = "grafana"

  repository = "https://grafana-community.github.io/helm-charts"
  chart      = "grafana"
  version    = "12.8.0"

  namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

  create_namespace = false
  atomic           = true
  cleanup_on_fail  = true
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      fullnameOverride = "grafana"

      replicas = 1

      rbac = {
        create = false
      }

      serviceAccount = {
        create = false
        name   = kubernetes_service_account_v1.grafana.metadata[0].name
      }

      automountServiceAccountToken = true

      testFramework = {
        enabled = false
      }

      service = {
        type       = "ClusterIP"
        port       = 80
        targetPort = 3000
      }

      # Ingress는 아래 kubernetes_ingress_v1 리소스에서 별도로 생성
      ingress = {
        enabled = false
      }

      persistence = {
        enabled = false
        # type             = "pvc"
        # storageClassName = var.storage_class_name

        # accessModes = [
        #   "ReadWriteOnce"
        # ]

        # size = var.storage_size
      }

      resources = {
        requests = {
          cpu    = "250m"
          memory = "512Mi"
        }

        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      # Athena 데이터소스는 기본 번들에 없으므로 시작 시 설치한다.
      # 서명된 공식 플러그인이라 allow_loading_unsigned_plugins 설정은 필요 없다.
      plugins = [
        "grafana-athena-datasource"
      ]

      env = {
        AWS_REGION         = var.region
        AWS_DEFAULT_REGION = var.region
      }


      # CloudWatch 데이터 소스를 Grafana 시작 시 자동 등록
      datasources = {
        "datasources.yaml" = {
          apiVersion = 1

          datasources = concat(
            [
              {
                name      = "CloudWatch"
                uid       = "cloudwatch"
                type      = "cloudwatch"
                access    = "proxy"
                isDefault = true
                editable  = false

                jsonData = {
                  authType                = "default"
                  defaultRegion           = var.region
                  customMetricsNamespaces = "ContainerInsights"
                }
              }
            ],

            # Log 계정 역할 ARN이 주어졌을 때만 Athena를 등록한다.
            # 값이 없는데 등록하면 파드는 뜨지만 모든 패널이 인증 오류를 뱉어서
            # "대시보드가 깨졌다"로 보인다 — 아예 없는 편이 진단하기 쉽다.
            trimspace(var.athena_reader_role_arn) != "" ? [
              {
                name      = "Athena (Security Logs)"
                uid       = "athena"
                type      = "grafana-athena-datasource"
                access    = "proxy"
                isDefault = false
                editable  = false

                jsonData = {
                  authType      = "default"
                  defaultRegion = var.region

                  # 파드 자격증명 -> Log 계정 조회 역할로 전환
                  assumeRoleArn = var.athena_reader_role_arn

                  catalog   = var.athena_catalog
                  database  = var.athena_database
                  workgroup = "gochuchamchi-security-logs"

                  # 워크그룹에 enforce_workgroup_configuration = true가 걸려 있어
                  # 실제 출력 위치는 워크그룹 설정이 이긴다. 여기 값은 UI 표시용.
                  outputLocation = ""
                }
              }
            ] : []
          )
        }
      }
      # Grafana 대시보드 프로비저닝 설정
      dashboardProviders = {
        "dashboardproviders.yaml" = {
          apiVersion = 1

          providers = [
            {
              name            = "gochuchamchi"
              orgId           = 1
              folder          = "Gochuchamchi"
              type            = "file"
              disableDeletion = false
              editable        = true

              options = {
                path = "/var/lib/grafana/dashboards/gochuchamchi"
              }
            }
          ]
        }
      }

      # Grafana 시작 시 자동으로 등록할 대시보드
      dashboards = {
        gochuchamchi = {
          "01-service-dependencies" = {
            json = local.aws_errors_dashboard
          }

          "02-platform-health" = {
            json = local.eks_health_dashboard
          }

          "03-application-logs" = {
            json = local.eks_logs_dashboard
          }

          # (2026-08-19) SIEM 화면 — siem_dashboards.tf / siem_realtime_dashboard.tf
          "04-siem-search" = {
            json = local.siem_search_dashboard
          }

          "05-siem-realtime" = {
            json = local.siem_realtime_dashboard
          }
        }
      }


      "grafana.ini" = {
        server = {
          domain              = var.grafana_hostname
          root_url            = local.grafana_root_url
          serve_from_sub_path = false
        }

        security = {
          cookie_secure = local.grafana_https_enabled
        }

        users = {
          allow_sign_up = false
        }

        auth_anonymous = {
          enabled = false
        }

        aws = {
          allowed_auth_providers = "default"
          assume_role_enabled    = true
        }
      }
    })
  ]

  # association "직후"가 아니라 전파 대기를 거친 뒤에 파드를 띄운다 (위 time_sleep 주석 참고)
  depends_on = [
    time_sleep.grafana_pod_identity_propagation,
    aws_iam_role_policy.grafana_cloudwatch
  ]
}


# =============================================================================
# Grafana ALB Ingress
# =============================================================================

resource "kubernetes_ingress_v1" "grafana" {
  metadata {
    name      = "grafana"
    namespace = kubernetes_namespace_v1.monitoring.metadata[0].name

    annotations = local.grafana_ingress_annotations
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.grafana_hostname

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "grafana"

              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  wait_for_load_balancer = true

  depends_on = [
    helm_release.grafana
  ]
}
