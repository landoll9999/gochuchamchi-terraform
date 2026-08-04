# =============================================================================
# k8s 인프라 리소스 (Namespace/ServiceAccount/ConfigMap/Secret/Ingress)
#   - 로컬에서 terraform apply를 실행하는 IAM 주체가 이미 클러스터 admin이므로
#     (main.tf의 enable_cluster_creator_admin_permissions), S3/SSM/배스천을 거치지 않고
#     kubernetes provider로 바로 적용한다.
#   - Deployment/Service/HPA는 여기서 관리하지 않는다 -> gochuchamchi-gitops 저장소를
#     ArgoCD가 감시해서 배포한다 (argocd.tf 참고). 이미지 태그가 바뀌는 리소스라서
#     인프라 재생성 주기와 분리했다.
#   - S3 버킷은 schema.sql 전달용으로 계속 사용 (rds-schema-init.tf가 배스천 경유로 읽어감).
# =============================================================================

resource "aws_s3_bucket" "k8s_manifests" {
  bucket = "gochuchamchi-k8s-manifests-${data.aws_caller_identity.current.account_id}"

  # schema.sql 등이 올라가 있어서 destroy 시 BucketNotEmpty로 막힘 -> 자동 비우기
  # (이 버킷은 배포 산출물 전달용이라 지워져도 재생성 시 다시 올라감)
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "k8s_manifests" {
  bucket                  = aws_s3_bucket.k8s_manifests.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 실제 값 자동 조회 (RDS 엔드포인트) — module 내부 output 이름에 의존하지 않도록
# db_instance_identifier로 직접 조회. RDS가 다 만들어진 뒤에 조회되도록 depends_on 필수
data "aws_db_instance" "this" {
  db_instance_identifier = "gochuchamchi-db"
  depends_on             = [module.rds]
}

# 배스천이 schema.sql을 S3에서 읽어올 수 있게 권한 부여
resource "aws_iam_role_policy" "bastion_s3_manifests" {
  name = "gochuchamchi-bastion-s3-manifests-policy"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        aws_s3_bucket.k8s_manifests.arn,
        "${aws_s3_bucket.k8s_manifests.arn}/*"
      ]
    }]
  })
}

# RDS 스키마 초기화용 schema.sql — rds-schema-init.tf가 배스천 경유로 적용
resource "aws_s3_object" "schema_sql" {
  bucket = aws_s3_bucket.k8s_manifests.id
  key    = "db/schema.sql"
  source = "${path.module}/../k8s/gochuchamchi/schema.sql"
  etag   = filemd5("${path.module}/../k8s/gochuchamchi/schema.sql")
}

# ---------------------------------------------------------------------------
# Namespace / ServiceAccount
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "gochuchamchi" {
  metadata {
    name = "gochuchamchi"
  }

  depends_on = [module.eks]
}

resource "kubernetes_service_account_v1" "gochuchamchi_app" {
  metadata {
    # eks-pod-identity.tf의 aws_eks_pod_identity_association이
    # namespace=gochuchamchi, service_account=gochuchamchi-app 으로 지정한 것과
    # 이름이 정확히 일치해야 IAM 권한이 이 Pod에 자동으로 붙는다.
    name      = "gochuchamchi-app"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
  }
}

# ---------------------------------------------------------------------------
# ConfigMap — application.yml이 실제로 읽는 이름에 맞춘 값들
# (RDS/Redis 엔드포인트는 인프라를 destroy/apply로 재생성할 때마다 바뀌는 값이라
#  gitops 저장소가 아니라 여기서 직접 관리)
# ---------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "gochuchamchi_config" {
  metadata {
    name      = "gochuchamchi-config"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
  }

  data = {
    DB_HOST = data.aws_db_instance.this.address
    DB_PORT = "3306"
    # (2026-08-04 제로트러스트) 마스터(admin) -> 앱 전용 최소권한 계정.
    # 계정 생성/비밀번호 주입은 db-zero-trust.tf가 배스천에서 수행.
    DB_USER = "gochuchamchi_app"

    # (2026-08-04 제로트러스트) JDBC TLS — 환경변수 SPRING_DATASOURCE_URL은 이미지 안
    # application.yml의 spring.datasource.url보다 우선 적용됨(Spring 프로퍼티 우선순위)
    # -> 앱 코드 수정/리빌드 없이 TLS 접속으로 전환.
    #   sslMode=trust  : 1단계 — 암호화만 하고 서버 인증서 검증은 생략.
    #   sslMode=verify-full : 2단계 — RDS CA 번들을 파드에 넣은 뒤 서버 신원까지 검증(운영 기준).
    # (mariadb-java-client 3.x 문법. 만약 2.x면 ?useSsl=true&trustServerCertificate=true)
    SPRING_DATASOURCE_URL = "jdbc:mariadb://${data.aws_db_instance.this.address}:3306/gochuchamchi?sslMode=trust"

    SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE = "5"
    SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE      = "2"
    CLOUD_AWS_S3_BUCKET                        = aws_s3_bucket.images.bucket
    CLOUD_AWS_REGION_STATIC                    = var.region
    SPRING_SESSION_STORE_TYPE                  = "redis"
    # replication_group 전환(redis.tf)으로 엔드포인트 속성이 primary_endpoint_address로 변경됨
    SPRING_DATA_REDIS_HOST = aws_elasticache_replication_group.this.primary_endpoint_address
    SPRING_DATA_REDIS_PORT = "6379"
    # ElastiCache 전송 암호화와 세트 — lettuce가 rediss(TLS)로 접속 (Boot 3.1+ 프로퍼티)
    SPRING_DATA_REDIS_SSL_ENABLED = "true"
  }
}

# ---------------------------------------------------------------------------
# DB Secret — (2026-08-04 제로트러스트로 "제거"됨. 왜 지웠는지가 중요해서 기록)
#   기존: data.aws_secretsmanager_secret_version으로 "마스터" 비밀번호를 읽어
#         K8s Secret(gochuchamchi-db-secret)을 만들었음.
#   문제: 1) 앱이 DB 마스터 계정으로 돌던 구조의 한 축
#         2) 마스터 비밀번호 평문이 tfstate에 저장됨 — SECURITY_AUDIT_REPORT #1이
#            정의한 "state에 secret_string이 다시 들어가는 시점"(ESO 트리거)이
#            이미 발동된 상태였음
#   현재: 앱 자격증명은 배스천이 생성해서 K8s Secret(gochuchamchi-db-app)으로 직접
#         주입 (db-zero-trust.tf) -> 앱 DB 비밀번호가 state에 전혀 남지 않음.
#   * gitops(03-deployment-web.yml)에서 secretKeyRef/secretRef 이름을
#     gochuchamchi-db-secret -> gochuchamchi-db-app 으로 바꿔야 함 (키는 DB_PASS 동일)
# ---------------------------------------------------------------------------

# Redis AUTH 토큰 주입 — DB와 달리 auth_token은 aws_elasticache_replication_group의
# 리소스 인자라 Terraform(state) 경유가 불가피함(redis.tf 주석 참고). 이미 state에 있는
# 값이므로 여기서 K8s Secret으로 만들어도 "추가" 노출은 없음. ESO 도입 시 최우선 이관 대상.
# 키 이름을 Spring 환경변수명 그대로 두면 gitops에서 envFrom secretRef 한 줄로 끝남.
resource "kubernetes_secret_v1" "gochuchamchi_redis_secret" {
  metadata {
    name      = "gochuchamchi-redis-secret"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
  }

  data = {
    SPRING_DATA_REDIS_PASSWORD = random_password.redis_auth.result
  }
}

# ---------------------------------------------------------------------------
# Ingress — aws-load-balancer-controller가 이 리소스를 보고 ALB를 자동 생성/구성.
# external-dns가 host 값을 보고 Route53에 A(Alias) 레코드를 자동으로 만들어줌.
# (ACM cert ARN은 인프라 재생성마다 바뀌는 값이라 여기서 직접 관리)
# ---------------------------------------------------------------------------
resource "kubernetes_ingress_v1" "gochuchamchi_web" {
  metadata {
    name      = "gochuchamchi-web-ingress"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      "alb.ingress.kubernetes.io/certificate-arn" = aws_acm_certificate_validation.this.certificate_arn
      # 미지정 시 ALB 기본값(ELBSecurityPolicy-2016-08)이 적용되는데, 이 정책은
      # 이미 deprecated된 TLS 1.0/1.1을 허용하고 TLS 1.3은 지원하지 않음(실제 확인).
      # TLS 1.2/1.3만 허용하는 정책으로 고정.
      "alb.ingress.kubernetes.io/ssl-policy" = "ELBSecurityPolicy-TLS13-1-2-2021-06"
      # 명시적 IngressGroup. Grafana Ingress(module/grafana, group.order=30)가 같은
      # group.name으로 이 ALB에 합류함 -> ALB 1개만 유지.
      # 또 cloudwatch-managed-metrics.tf가 ingress.k8s.aws/stack 태그 = 이 group.name
      # 으로 ALB/Target Group을 조회하므로, 값을 바꾸면 거기도 같이 바꿔야 함.
      "alb.ingress.kubernetes.io/group.name"  = "gochuchamchi-web"
      "alb.ingress.kubernetes.io/group.order" = "10"
    }
  }

  spec {
    rule {
      host = var.domain_name
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "gochuchamchi-web-svc"
              port {
                number = 80
              }
            }
          }
        }
      }
    }

    rule {
      host = "www.${var.domain_name}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "gochuchamchi-web-svc"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.aws_load_balancer_controller]
}
