# 판정용 환경 설명

이 문서는 Groq 판정 프롬프트에 그대로 실린다.

**멘토 지적("커스텀 룰을 유지보수하는 게 현실적으로 힘들다")에 대한 답이 이 구조다.**
조건문 테이블을 늘려 가는 대신 이 문서 한 장을 최신으로 유지한다. 인프라가
바뀌면 코드가 아니라 여기를 고친다.

문서가 부정확하면 판정도 부정확해진다. 특히 "정상 패턴" 절이 비어 있으면
모델이 정상 자동화를 위협으로 올린다.

---

## 조직 구조

3개 AWS 계정으로 나뉜 조직이다. 계정 ID는 판정에 넘길 때 `ACCT-1` 같은
가명으로 치환된다(같은 가명 = 같은 계정).

| 계정 | 역할 |
|---|---|
| Management | Organizations, SCP, Identity Center, Organization Trail |
| Security/Log | 모든 로그의 중앙 저장소. 워크로드 없음 |
| Workload | EKS, VPC, RDS, ALB. **GuardDuty가 도는 곳이자 이 finding들의 출처** |

## 워크로드 구성

- 서울 리전(`ap-northeast-2`) 단일 리전. **다른 리전에서 오는 활동은 그 자체로 이상하다.**
- EKS 클러스터 위에 Spring Boot 웹 애플리케이션 1종
- 트래픽 경로: CloudFront/WAF → ALB → EKS 파드 → RDS(MariaDB) / Redis
- 배포는 ArgoCD가 GitOps 저장소를 보고 수행. 이미지는 ECR
- 배스천 EC2 접근은 SSH가 아니라 **SSM Session Manager** 경유
- RDS는 `publicly_accessible = false`
- EKS 노드의 외부 통신은 전부 NAT를 거친다 — 아웃바운드 출발지는 NAT IP다

## 정상 패턴 — 위협으로 오해하기 쉬운 것들

아래는 **정상이다.** 이것만으로는 TRUE_POSITIVE가 아니다.

- **GitHub Actions OIDC 역할의 ECR 푸시/풀** — CI가 커밋마다 수행한다.
  역할 이름에 `github-actions`가 들어간다.
- **ArgoCD의 반복적인 EKS API 호출** — 3분 주기 동기화라 호출량이 많다.
- **EKS 노드의 외부 대용량 아웃바운드** — ECR 이미지 풀, OS 패키지 업데이트가
  NAT를 통해 나간다. 목적지가 AWS 대역이면 정상 쪽.
- **terraform apply 중의 대량 API 호출** — 사람이 로컬에서 실행하며 짧은 시간에
  몰린다. 단, **계획된 apply인지는 finding만으로 알 수 없다.** 권한 변경·로그
  설정 변경 계열은 정상이라고 단정하지 말고 UNCERTAIN으로 둘 것.
- **배스천에서의 kubectl / aws CLI 호출** — 운영 작업이다.

## 반대로, 이 환경에서는 명백히 비정상인 것

- 서울 이외 리전에서의 리소스 생성
- 루트 계정 사용 (어떤 형태든)
- RDS `publicly_accessible` 변경, 보안그룹에 `0.0.0.0/0` 인바운드 추가
- CloudTrail/GuardDuty/Config를 끄거나 로그 버킷 정책을 바꾸는 시도
- SSM을 거치지 않은 배스천 직접 SSH 접속 성공
- 처음 보는 IAM 사용자·액세스키 생성
- 암호화폐 채굴 도메인/IP로의 통신 — 이 환경에 그럴 이유가 전혀 없다

## finding을 읽을 때 특히 볼 것

- **`occurrence.resource_role`** — `TARGET`이면 우리 리소스가 공격 **대상**이고,
  `ACTOR`면 우리 리소스가 **발신자**다. ACTOR는 침해를 강하게 시사한다.
- **`occurrence.count`** — 1회성인지 지속 중인지. 큰 값은 진행 중이라는 뜻이다.
- **`threat_intel`** — 위협 인텔 목록에 걸렸다면 FALSE_POSITIVE 판정을 뒤집는
  강한 근거다.
- **`action.blocked`** — 이미 차단됐다면 위험도(risk_score)는 낮아진다. 다만
  시도 자체는 여전히 신호다.

---

## ⚠️ 아직 채워지지 않은 부분

운영하며 아래를 채우면 판정 정확도가 크게 오른다. 비워 두면 그만큼 모델이
"모르겠으니 UNCERTAIN"으로 올려 알림이 시끄러워진다.

- [ ] 관리자가 접속하는 공인 IP 대역 (재택/사무실)
- [ ] daily-up / daily-down 스크립트가 도는 정확한 UTC 시각
- [ ] 정상적으로 통신하는 외부 엔드포인트 (결제/외부 API 등)
- [ ] 사람 IAM 사용자 이름 목록 (자동화 역할과 구분하기 위해)
- [ ] NAT Gateway 공인 IP (아웃바운드 출발지 판단용)
