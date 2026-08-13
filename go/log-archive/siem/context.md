# 판정용 환경 설명

이 문서는 Groq 판정 계층의 시스템 프롬프트에 그대로 실린다.
**룰 조건문을 계속 고치는 대신 이 문서를 최신으로 유지하는 것**이 이 SIEM의
유지보수 전략이다. 인프라가 바뀌면 여기를 고친다.

문서가 부정확하면 판정도 부정확해진다. 특히 "정상 패턴" 절이 비어 있으면
모델이 정상 자동화를 위협으로 올린다.

---

## 조직 구조

3개 AWS 계정으로 나뉜 조직이다.

| 계정 | 역할 |
|---|---|
| Management | Organizations, SCP, Identity Center, Organization Trail 소유 |
| Security/Log | 모든 로그의 중앙 저장소. 이 SIEM이 도는 곳. 워크로드가 없다 |
| Workload | EKS, VPC, RDS, ALB, 실제 애플리케이션 |

계정 ID는 판정에 넘길 때 `ACCT-1`, `ACCT-2` 같은 가명으로 치환된다.
같은 가명은 같은 계정을 뜻하므로 "여러 계정에 걸친 활동인가"는 판단할 수 있다.

## 워크로드 구성

- 서울 리전(`ap-northeast-2`) 단일 리전. **다른 리전에서 오는 활동은 그 자체로 이상하다.**
- EKS 클러스터 위에 Spring Boot 웹 애플리케이션 1종
- 트래픽 경로: CloudFront/WAF → ALB → EKS 파드 → RDS(MariaDB) / Redis
- 배포는 ArgoCD가 GitOps 저장소를 보고 수행. 이미지는 ECR
- 배스천 EC2 접근은 SSH가 아니라 **SSM Session Manager** 경유
- RDS는 `publicly_accessible = false`. 외부에서 직접 붙을 수 없다

## 로그 소스와 각각이 뜻하는 것

| source_type | 무엇 |
|---|---|
| `cloudtrail` | AWS API 호출. actor는 IAM 주체 |
| `waf` | 엣지 차단/허용. 인증 주체 개념 없음 |
| `alb` | WAF를 통과해 실제 처리된 HTTP 요청 |
| `application` | 앱이 스스로 남긴 로그인 실패·권한 거부 |
| `vpc_flow` | ENI 단위 네트워크 흐름. 주체 개념 없음 |

## 정상 패턴 — 위협으로 오해하기 쉬운 것들

아래는 **정상이다.** 이것만으로는 threat이 아니다.

- **GitHub Actions OIDC 역할의 ECR 푸시/풀** — CI가 커밋마다 수행한다.
  역할 이름에 `github-actions`가 들어간다.
- **ArgoCD의 반복적인 EKS API 호출** — 3분 주기 동기화라 호출량이 많다.
- **terraform apply 중의 대량 변경** — IAM 역할·KMS 키 정책·S3 버킷 정책이
  한꺼번에 바뀐다. 사람이 로컬에서 실행하며, 짧은 시간에 몰려서 발생한다.
  단, **이게 계획된 apply인지 아닌지는 이 데이터만으로 알 수 없다.**
  그러므로 권한 상승·감사 무력화 계열은 정상이라고 단정하지 말고 최소
  suspicious로 둘 것.
- **EKS 노드의 외부 아웃바운드 대용량** — ECR 이미지 풀, OS 패키지 업데이트,
  컨테이너 레지스트리 접근이 NAT를 통해 나간다. 목적지가 AWS 대역이면 정상 쪽.
- **배포 직후의 5xx/헬스체크 실패 급증** — 롤링 업데이트 중 일시적으로 발생한다.
- **`Too many connections` 계열 DB 오류** — 인스턴스가 작아 커넥션 한도가 낮다.
  보안 사건이 아니라 용량 문제다.

## 반대로, 이 환경에서는 명백히 비정상인 것

- 서울 이외 리전에서의 리소스 생성
- 루트 계정 사용 (어떤 형태든)
- RDS의 `publicly_accessible` 변경, 보안그룹에 `0.0.0.0/0` 인바운드 추가
- CloudTrail/GuardDuty/Config를 끄거나 로그 버킷 정책을 바꾸는 시도
- SSM을 거치지 않은 배스천 직접 SSH 접속 성공
- 처음 보는 IAM 사용자·액세스키 생성

---

## ⚠️ 아직 채워지지 않은 부분

운영하면서 아래를 채우면 판정 정확도가 크게 오른다. 비워 두면 그만큼
모델이 "모르겠으니 suspicious"로 올린다.

- [ ] 관리자가 접속하는 IP 대역 (재택/사무실)
- [ ] daily-up / daily-down 스크립트가 도는 정확한 UTC 시각
- [ ] 정상적으로 통신하는 외부 엔드포인트 목록 (결제/외부 API 등)
- [ ] 사람 IAM 사용자 이름 목록 (자동화 역할과 구분하기 위해)
