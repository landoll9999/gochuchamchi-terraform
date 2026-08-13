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

    # (2026-08-03 full-HA에서 복원) Pod Security Standards (컨테이너 보안 레이어 1/3)
    #   enforce — 위반 파드는 생성 자체가 거부됨. 앱 이미지가 root 로 도는지
    #     검증 전이라 기본값은 baseline(privileged/hostPath/hostNetwork 등
    #     컨테이너 탈출 벡터 차단)으로 시작하고, gitops Deployment 에
    #     securityContext 를 넣은 뒤 restricted 로 올린다.
    #   warn/audit — restricted 위반을 kubectl 경고 + API 감사로그로 남겨서
    #     enforce 를 올리기 전에 무엇이 걸릴지 미리 보이게 함.
    labels = {
      "pod-security.kubernetes.io/enforce" = var.pss_enforce_level
      "pod-security.kubernetes.io/warn"    = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
    }
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
    # (2026-08-12) 고정 비밀번호 계정 -> IAM 토큰 계정. 이 계정은 AWSAuthenticationPlugin 으로
    # 만들어져서 비밀번호가 아예 없다. 접속마다 15분짜리 토큰을 새로 받아야 하고,
    # 토큰을 받을 수 있는 것은 rds-db:connect 가 붙은 파드 역할(gochuchamchi-app-role)뿐이다.
    # 정책 Resource 에 유저명이 박혀 있어(db-zero-trust.tf) 이 이름을 바꾸면 즉시 권한이 끊긴다.
    DB_USER = "gochuchamchi_app_iam"

    # (2026-08-04 제로트러스트) JDBC TLS — 환경변수 SPRING_DATASOURCE_URL은 이미지 안
    # application.yml의 spring.datasource.url보다 우선 적용됨(Spring 프로퍼티 우선순위)
    # -> 앱 코드 수정/리빌드 없이 TLS 접속으로 전환.
    #   sslMode=trust  : 1단계 — 암호화만 하고 서버 인증서 검증은 생략.
    #   sslMode=verify-full : 2단계 — RDS CA 번들을 파드에 넣은 뒤 서버 신원까지 검증(운영 기준).
    # (mariadb-java-client 3.x 문법. 만약 2.x면 ?useSsl=true&trustServerCertificate=true)
    #
    # (2026-08-12) 2단계 + IAM 토큰으로 전환. 각 파라미터가 왜 있는지:
    #   credentialType=AWS-IAM
    #     드라이버의 AwsIamCredentialPlugin 이 접속마다 rds:generate-db-auth-token 을 호출해
    #     비밀번호 자리에 토큰을 넣는다. 토큰 유효 15분 / 드라이버 내부 캐시 10분이라
    #     앱 코드도 HikariCP 갱신 로직도 필요 없다. 대신 이미지에
    #     software.amazon.awssdk:rds 가 들어 있어야 한다(pom.xml). v1(com.amazonaws)은 안 된다.
    #     -> 그래서 이미지 배포가 이 ConfigMap 변경보다 반드시 먼저다.
    #   region
    #     안 주면 DefaultAwsRegionProviderChain 으로 떨어진다. EKS Pod Identity 는 자격증명만
    #     주입하고 리전을 보장하지 않으므로 명시한다.
    #   serverSslCert=/app/rds-ca.pem
    #     verify-full 은 서버 인증서를 검증하는데, ap-northeast-2 RDS 는 자체 서명 리전 루트
    #     3장으로 서명돼 있고 JDK cacerts(amazonrootca1~4)에 없다. 번들을 안 주면 verify-full 이
    #     반드시 실패한다. 경로는 Dockerfile 이 이미지에 구워 넣은 위치다.
    SPRING_DATASOURCE_URL = "jdbc:mariadb://${data.aws_db_instance.this.address}:3306/gochuchamchi?credentialType=AWS-IAM&region=${var.region}&sslMode=verify-full&serverSslCert=/app/rds-ca.pem"

    SPRING_DATASOURCE_HIKARI_MAXIMUM_POOL_SIZE = "5"
    SPRING_DATASOURCE_HIKARI_MINIMUM_IDLE      = "2"
    CLOUD_AWS_S3_BUCKET                        = aws_s3_bucket.images.bucket
    CLOUD_AWS_S3_PUBLIC_BASE_URL               = "https://${aws_cloudfront_distribution.images.domain_name}"
    CLOUD_AWS_REGION_STATIC                    = var.region
    SPRING_SESSION_STORE_TYPE                  = "redis"
    # replication_group 전환(redis.tf)으로 엔드포인트 속성이 primary_endpoint_address로 변경됨
    SPRING_DATA_REDIS_HOST = aws_elasticache_replication_group.this.primary_endpoint_address
    SPRING_DATA_REDIS_PORT = "6379"
    # ElastiCache 전송 암호화와 세트 — lettuce가 rediss(TLS)로 접속 (Boot 3.1+ 프로퍼티)
    SPRING_DATA_REDIS_SSL_ENABLED = "true"

    # (2026-08-03 full-HA에서 복원) 기동 시 이 아이디를 superadmin으로 승격
    # (SuperAdminBootstrap). 이 환경변수가 app.superadmin.username 프로퍼티를
    # 직접 덮으므로 설정 파일과 무관하게 동작한다.
    APP_SUPERADMIN_USERNAME = var.superadmin_username
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
#   8/4~8/12: 앱 자격증명은 배스천이 생성해서 K8s Secret(gochuchamchi-db-app)으로 직접
#         주입 (db-zero-trust.tf) -> 앱 DB 비밀번호가 state에 전혀 남지 않음.
#   현재(2026-08-13): 그 Secret 도 없앴다. 앱은 IAM 토큰으로 붙으므로 DB 비밀번호가
#         state 에 안 남는 정도가 아니라 아예 존재하지 않는다. 파드 환경변수에 쓰이지도
#         않는 DB_PASS 가 남아 있던 것을 없앤 것이 이 단계의 핵심이다.
#   * gitops(03-deployment-web.yml)에서 envFrom 의 secretRef: gochuchamchi-db-app 을
#     제거해야 한다. Secret 이 더는 만들어지지 않으므로 참조가 남아 있으면 파드가
#     CreateContainerConfigError 로 못 뜬다 — 그래서 gitops 수정이 먼저다.
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
    annotations = merge(
      {
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
        # ALB access logs are written directly to the immutable Log-account
        # bucket. The bucket must be applied first in ../log-archive.
        "alb.ingress.kubernetes.io/load-balancer-attributes" = join(",", [
          "access_logs.s3.enabled=true",
          "access_logs.s3.bucket=gochuchamchi-alb-access-logs-${var.log_archive_account_id}",
          "access_logs.s3.prefix=alb"
        ])
      },
      # (2026-08-03 full-HA에서 복원) CloudFront 전환(edge.tf, enable_edge=true) 시
      # 이 호스트의 Route53 레코드 소유권을 Terraform으로 넘긴다. ExternalDNS가
      # spec.rules[].host를 계속 보면 ALB Alias로 되돌리는 upsert가 일어나므로,
      # annotation-only 모드로 바꿔 이 Ingress의 호스트를 관리 대상에서 뺀다.
      #
      # security-groups: ALB 인바운드를 CloudFront origin-facing prefix list +
      # 관리자 IP로 제한하는 SG(edge.tf §5)를 컨트롤러 자동 생성 SG 대신 사용
      # -> ALB DNS를 직접 때려 WAF를 우회하는 경로 차단.
      # manage-backend-security-group-rules: 컨트롤러가 백엔드(노드/파드) SG에
      # ALB→타겟 허용 규칙을 자동 관리하게 함 (커스텀 SG 사용 시 필수 권장).
      var.enable_edge ? {
        "external-dns.alpha.kubernetes.io/ingress-hostname-source"      = "annotation-only"
        "alb.ingress.kubernetes.io/security-groups"                     = aws_security_group.alb_edge[0].id
        "alb.ingress.kubernetes.io/manage-backend-security-group-rules" = "true"
        # CloudFront가 추가한 비밀 헤더가 있는 요청만 앱 Target Group으로 전달한다.
        # 직접 ALB 호출이나 다른 CloudFront 배포를 통한 우회는 listener default
        # action으로 떨어져 애플리케이션에 도달하지 않는다.
        "alb.ingress.kubernetes.io/conditions.gochuchamchi-web-svc" = jsonencode([
          {
            field = "http-header"
            httpHeaderConfig = {
              httpHeaderName = "X-Gochuchamchi-Origin-Verify"
              values         = [random_password.cloudfront_origin_verify[0].result]
            }
          }
        ])
      } : {}
    )
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
