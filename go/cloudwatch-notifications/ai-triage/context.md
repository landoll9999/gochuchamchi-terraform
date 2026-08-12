# 환경 컨텍스트 — GuardDuty 트리아지 판단 근거

이 문서는 트리아지 모델의 **system 프롬프트로 통째로 주입**되고, 프롬프트 캐시
breakpoint가 이 블록 끝에 걸린다. 즉 내용이 한 글자라도 바뀌면 캐시가 깨지고 그날
첫 호출은 캐시 쓰기 가격(정가의 1.25배)을 낸다. **자주 바뀌는 값(오늘 배포한 커밋
해시 같은 것)은 여기 넣지 말 것** — 그런 건 finding 쪽 컨텍스트로 붙인다.

여기가 이 파이프라인의 실질적 경쟁력이다. Wiz·Panther·Datadog 같은 상용 도구는
구조적으로 이 정보를 모른다 — **우리 IaC를 안 보기 때문**이다. "그 역할은 매일 그
시간에 도는 CI용 OIDC 역할"이라는 판단은 이 문서가 있어야만 가능하다.

> ⚠️ 이 문서가 부정확하면 모델이 자신 있게 틀린다. 인프라를 바꿨는데 여기를 안
> 고치면, 새로 생긴 정상 패턴이 위협으로, 없어진 정상 패턴이 알리바이로 쓰인다.
> 인프라 변경 PR에 이 파일 갱신을 딸려 보내는 편이 안전하다.

---

## 조직 구조

3계정 AWS Organizations, 전 계정 서울 리전(`ap-northeast-2`) 사용.

| 계정 ID | 역할 | 성격 |
|---|---|---|
| `307223751140` | Management | Organizations 관리 계정. SCP가 적용되지 않는다(AWS 사양). 통제 수단은 Identity Center 권한 설계 + MFA뿐이라, 이 계정에서의 이상 행위는 **다른 계정보다 심각하게 볼 것.** |
| `564186750363` | Security/Log | 로그 아카이브. 조직 보안 서비스 위임 관리자 예정. 이 계정의 로그 버킷에 대한 **삭제·정책 변경 시도는 증거 인멸 시나리오**로 간주할 것. |
| `828885965304` | Workload | EKS 서비스 운영. 아래 "정상 운영 패턴"은 대부분 이 계정 이야기다. |

## 워크로드 계정 인프라

- **EKS 클러스터** `gochuchamchi-eks` — 관리형 노드그룹, `t3.medium`, desired 2 / min 2 / max 4.
  퍼블릭 서브넷 없이 프라이빗 노드 + NAT 인스턴스(EC2, `t3.*` AL2023) 구성.
- **접속 경로는 SSM Session Manager 하나뿐이다.** 노드·NAT·배스천에 SSH 키페어가
  붙어 있지 않다. 따라서 **22번 포트로의 성공적인 SSH 연결이나 키 기반 로그인
  흔적은 그 자체로 비정상**이다.
- **도메인** `gochuchamchi.shop` (Route53), ALB Ingress.
- **ECR** 이미지 저장소 — 태그 불변성 + 푸시 시 스캔 활성.
- **Grafana / Prometheus** 모니터링 스택이 클러스터 안에 있고, Pod Identity로 AWS
  자격증명을 받는다.

## 매일 반복되는 정상 패턴 (오탐의 최대 원인)

이 환경은 **비용 절감을 위해 매일 인프라를 통째로 내렸다 올린다.** `scripts/daily-down.ps1`
/ `daily-up.ps1`이 Terraform destroy/apply를 돌린다. 여기서 파생되는 정상 신호:

- **대량의 리소스 생성·삭제 API 호출이 짧은 시간에 몰린다.** EC2/EKS/ELB/EIP/
  NAT/보안그룹 생성·삭제가 수십~수백 건. 단독으로는 "리소스 대량 삭제" 류
  finding처럼 보이지만 매일 있는 일이다.
- **EC2 인스턴스 ID·프라이빗 IP·ENI가 매일 바뀐다.** "새로 뜬 인스턴스가 처음 보는
  IP로 통신한다"는 신호는 여기서 정상적으로 발생한다.
- **어제 격리·태깅한 리소스는 오늘 존재하지 않는다.** finding이 가리키는 인스턴스가
  이미 없다는 사실 자체는 이상 신호가 아니다.

> 단, **"매일 있는 일"이 곧 "무해하다"는 뜻은 아니다.** 공격자가 이 창을 노려
> 자기 활동을 섞을 수 있다. 시각·주체·대상이 평소 패턴과 어긋나면 매일 하는
> 작업과 닮았더라도 needs_review로 올릴 것.

## 알려진 정상 주체(principal)

| 주체 | 하는 일 | 정상 범위 |
|---|---|---|
| `gochuchamchi-ci` | Terraform CI 실행 역할 | 인프라 전 영역 CRUD. daily-up/down 시간대에 집중. |
| `gochuchamchi-github-actions-ecr-push` | GitHub Actions → ECR 푸시 | `ecr:*` 위주. 다른 서비스 호출은 비정상. |
| `gochuchamchi-github-actions-image-signer` | 이미지 서명 | ECR + KMS 서명 관련. |
| `gochuchamchi-cloudwatch-discord-lambda` | 알림 Lambda | Secrets Manager 읽기 + 로그. |
| `gochuchamchi-guardduty-isolation-lambda` | 자동 격리 Lambda | EC2 SG 교체·태깅. **이 역할이 격리 외의 일을 하면 비정상.** |
| `gochuchamchi-ai-triage-lambda` | 이 트리아지 Lambda | Bedrock 호출 + DynamoDB + SNS. |

## 배치된 통제 (finding 해석에 필요)

- **Region Guard** — 콘솔 관리자 그룹에 `ap-northeast-2`, `ap-northeast-1` 외 리전
  API를 명시적 Deny하는 IAM 정책이 붙어 있다. 따라서 **다른 리전에서의 리소스
  생성 시도가 실패로 끝난 finding**은 "차단이 작동했다"는 뜻이지 무해하다는 뜻이
  아니다 — 시도했다는 사실 자체가 탈취된 자격증명의 강한 신호다. `real_threat`
  또는 최소 `needs_review`로 볼 것.
- **자동 격리** — severity 7 이상 + EC2 대상 finding은 별도 Lambda가 이미 해당
  인스턴스의 ENI를 검역 SG로 교체했을 수 있다. 이 경로는 트리아지와 **독립적으로**
  동작한다(AI 판정을 기다리지 않는다). 격리 결과는 별도 알림으로 따로 온다.
- **SCP** — Workloads OU에 감사 로그 훼손 방지 SCP(`DenyWorkloadAuditTampering`)가
  붙어 있다. CloudTrail/GuardDuty/Security Hub 비활성화 시도는 실패하지만,
  **시도 자체를 방어 회피(defense evasion)로 취급할 것.**

## 이 환경에서 특히 심각하게 볼 신호

1. Management 계정(`307223751140`)에서의 IAM/Organizations 변경.
2. Log 계정(`564186750363`) 로그 버킷의 삭제·정책 변경·퍼블릭화 시도.
3. 허용되지 않은 리전에서의 리소스 생성 시도(성공/실패 무관).
4. CloudTrail·GuardDuty·Config·Security Hub 비활성화 시도.
5. EKS 익명 접근, 특권 파드 생성, `kube-system` 침투 시도.
6. 노드에서의 아웃바운드 C2 통신, 코인 채굴 도메인 조회.
7. SSH(22) 기반 접속 성공 — 이 환경에는 SSH 경로 자체가 없어야 한다.

## 아직 채워지지 않은 부분

정확도를 더 올리고 싶으면 아래를 이 문서에 추가한다. 지금은 비어 있으므로,
모델은 이 항목들에 대해 "모른다"를 전제로 판단해야 한다.

- daily-up / daily-down의 정확한 실행 시각(UTC)과 요일 — 지금은 "매일 특정
  시간대에 몰린다"까지만 안다.
- 정상적으로 접속하는 관리자 IP 대역 / 국가.
- 서비스가 정상적으로 통신하는 외부 엔드포인트 목록.
