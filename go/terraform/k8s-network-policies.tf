# =============================================================================
# NetworkPolicy — 클러스터 내부 east-west 차단 (2026-08-04 백로그 B5)
#
# 왜 — 모든 파드가 노드 SG를 공유하므로, RDS SG의 "EKS 노드만 허용"은 노드 단위지
#   파드 단위가 아니다. 어떤 파드든(grafana/external-dns/image-updater...) RDS 3306,
#   Redis 6379에 도달 가능했음. 인터넷에 노출된 최고위험 파드(웹앱)부터 잠근다.
#
# 범위 — gochuchamchi 네임스페이스만. 시스템 네임스페이스(kube-system/argocd 등)는
#   컨트롤러들의 egress 요구가 넓고 깨지기 쉬워 의도적으로 제외 (백로그 B5 방침).
#   -> 이 정책의 효과: 앱 파드가 침해돼도 다른 파드/kubelet으로의 측면이동이 차단되고,
#      DB·Redis·DNS·HTTPS 외의 아웃바운드(리버스쉘 임의 포트 등)가 막힌다.
#
# 시행 전제 — vpc-cni의 enableNetworkPolicy=true (main.tf). 꺼져 있으면 이 리소스들은
#   존재해도 아무것도 차단하지 않는다(무해). 적용 후 문제가 생기면 롤백은
#   `kubectl -n gochuchamchi delete netpol --all` 한 줄 (terraform이 다음 apply에서 복원).
#
# 검증 (apply 후):
#   # DNS부터 볼 것 — 여기서 막히면 나머지 규칙이 맞아도 앱은 전부 500이 난다
#   kubectl -n gochuchamchi exec deploy/gochuchamchi-web -- getent hosts <RDS 엔드포인트>   # 주소 나오면 성공
#   kubectl -n gochuchamchi exec deploy/gochuchamchi-web -- curl -sS -m 3 https://checkip.amazonaws.com  # 443 -> 성공
#   kubectl -n gochuchamchi exec deploy/gochuchamchi-web -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/9999'      # 임의 포트 -> 타임아웃이면 성공
#   사이트 로그인/상품조회/이미지 업로드 정상 동작 확인 (DB 3306·Redis 6379·S3 443 경로)
# =============================================================================

# 1) 기본 거부 — 이 네임스페이스의 모든 파드는 명시적으로 허용된 트래픽만 주고받는다
resource "kubernetes_network_policy_v1" "gochuchamchi_default_deny" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
  }

  spec {
    pod_selector {} # 네임스페이스 내 전체 파드
    policy_types = ["Ingress", "Egress"]
  }
}

# 2) 웹앱 허용 규칙 — 필요한 경로만 정확히 연다
resource "kubernetes_network_policy_v1" "gochuchamchi_web_allow" {
  metadata {
    name      = "web-allow"
    namespace = kubernetes_namespace_v1.gochuchamchi.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "gochuchamchi-web" # gitops 03-deployment-web.yml의 파드 라벨
      }
    }
    policy_types = ["Ingress", "Egress"]

    # 인바운드: ALB(target-type ip, 퍼블릭 서브넷의 ALB ENI) + kubelet 헬스체크(노드 IP)
    # 모두 VPC CIDR 안이므로 VPC -> 8080 하나로 커버. 그 외 포트는 전부 거부.
    ingress {
      from {
        ip_block {
          cidr = module.vpc.vpc_cidr_block
        }
      }
      ports {
        port     = 8080 # Spring Boot 컨테이너 포트 (타겟그룹 등록 포트와 동일)
        protocol = "TCP"
      }
    }

    # 아웃바운드 1: DNS — 목적지를 "서비스 CIDR"로 열어야 한다.
    #   파드의 resolv.conf nameserver는 kube-dns ClusterIP(10.100.0.10, 서비스 CIDR)이고,
    #   ClusterIP -> coredns 파드 IP 변환(kube-proxy DNAT)은 패킷이 파드 veth를 "떠난 뒤"
    #   호스트에서 일어난다. vpc-cni의 정책 엔진(eBPF)은 veth egress 훅에서 평가하므로
    #   원래 목적지인 ClusterIP를 본다 -> VPC CIDR만 열면 서비스 CIDR이 빠져서 DNS가
    #   전부 막히고, 앱은 RDS/Redis 호스트명 해석 실패(UnknownHostException)로 500을 낸다.
    #   (2026-08-04 실제 장애로 확인. VPC 172.30.0.0/16 ∌ 서비스 10.100.0.0/16)
    #   VPC 대역도 함께 두는 이유: 파드 IP로 직접 가는 DNS 경로와 노드 로컬 캐시 대비.
    egress {
      to {
        ip_block { cidr = module.eks.cluster_service_cidr }
      }
      to {
        ip_block { cidr = module.vpc.vpc_cidr_block }
      }
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
    }

    # 아웃바운드 2: RDS(3306)·Redis(6379) — database 서브넷도 VPC 대역.
    # "노드 SG 허용"보다 좁은 파드 단위 제한이 이 규칙의 핵심.
    egress {
      to {
        ip_block { cidr = module.vpc.vpc_cidr_block }
      }
      ports {
        port     = 3306
        protocol = "TCP"
      }
      ports {
        port     = 6379
        protocol = "TCP"
      }
    }

    # 아웃바운드 3: HTTPS — S3 업로드(VPC endpoint/NAT 경유), AWS API.
    # 앱의 외부 호출이 전부 443이라 목적지 IP는 제한하지 않는다(동적).
    egress {
      to {
        ip_block { cidr = "0.0.0.0/0" }
      }
      ports {
        port     = 443
        protocol = "TCP"
      }
    }

    # 아웃바운드 4: EKS Pod Identity 에이전트 (링크로컬 고정 주소, 노드 hostNetwork).
    # 이게 막히면 앱의 S3 자격증명 발급이 실패한다 — default-deny에서 자주 놓치는 경로.
    egress {
      to {
        ip_block { cidr = "169.254.170.23/32" }
      }
      ports {
        port     = 80
        protocol = "TCP"
      }
    }
  }
}
