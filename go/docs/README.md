# gochuchamchi-eks 문서 인덱스

`gochuchamchi-eks` 프로젝트의 작업 기록 · 트러블슈팅 · 참고 문서 모음입니다.
Terraform 코드와는 무관하며(`.tf` 어디에서도 참조하지 않음), 문서만 보관합니다.

## 날짜별 작업 기록

작업한 내용과 트러블슈팅은 **하루 단위로 `YYYY-MM-DD.md` 파일 하나**에 기록합니다.

| 날짜 | 파일 | 내용 |
|---|---|---|
| 2026-08-04 | [2026-08-04-automation.md](2026-08-04-automation.md) | **배포 파이프라인 자동화 3종 (별도 세션)** — 반복 장애의 공통점("apply 성공 ≠ 서비스 정상")을 코드로 메움: **배포 계약**(`contract.tf` — terraform↔gitops 인터페이스를 output으로 선언, `forbidden_refs`로 옛 이름 부활 차단) / **계약 검증**(`scripts/verify-contract.ps1` — gitops 참조와 양방향 대조) / **스모크 테스트**(`scripts/smoke-test.ps1` 12개 검사 + `smoke-test.tf`로 apply 후 자동 실행, 기본 경고 모드) / **수동 변경 감지**(`cloudwatch-notifications/drift-detection.tf` — SG/RDS/IAM 콘솔 변경을 EventBridge 3룰로 Discord 통보) / terraform PR CI(`.github/workflows/terraform-ci.yml` — fmt·validate·tflint·checkov, AWS 자격증명 없음) — plan/apply CI는 배스천 self-hosted runner 결정 대기 |
| 2026-08-04 | [2026-08-04-트러블슈팅-종합.md](2026-08-04-트러블슈팅-종합.md) | 8/4 하루치 트러블슈팅 **종합본(색인 겸 post-mortem)** — 증상으로 찾아 들어가는 표 + §1~§7 (DB 전면 500 "반쪽 배포" / 작업 PC 환경 / 사라진 full-HA 라인 / 파괴적 plan 판별 / Cost Anomaly Monitor 한도 / Inspector2 타임아웃 / git 우회 동기화 사고) |
| 2026-08-04 | [2026-08-04-incident-and-review.md](2026-08-04-incident-and-review.md) | **복구 후 재점검 + 자동화 + full-HA 복원 (별도 세션)** — 장애 근본원인 요약("terraform apply와 gitops 수정이 한 세트인데 반쪽만 실행") + 복구 외부 검증(`/api/health` 500→302) / **하드코딩 인벤토리**(🔴 AMI ID·backend 계정 종속·secret 이름 계약 / 🟡 의도적 / 🟢 정답) / **보안 재점검**: Grafana admin 비밀번호 state 평문(→코드 조치 완료), `.gitignore` 보강(초기 과대 판정은 문서 내 정정), IAM `"*"` 전수 확인 전부 정당 / **SNS 알림 허브**: EventBridge→SNS 팬아웃 + 이메일 구독 + SQS DLQ + 자기 감시 알람 (`cloudwatch-notifications/sns.tf`) / **8/3 full-HA 라인 13개 파일이 저장소 재생성 때 통째로 누락된 것을 발견·복원**: CloudFront+WAF(edge), IAM 보안, KMS, NACL, VPC 엔드포인트, Flow Logs, 비용 모니터링, Kyverno, LimitRange/Quota, 도쿄 DR, Config 버킷 분리 + NAT AZ별 2대·PSA 라벨·Inspector ENHANCED·GuardDuty 확장·로그 불변성 Deny 이식 — 제로트러스트(8/4)와 3-way 병합, validate 통과. RDS/EFS CMK·Object Lock은 파괴적이라 재구축 사이클로 보류 |
| 2026-08-04 | [2026-08-04.md](2026-08-04.md) | **제로트러스트 DB 하드닝** — 앱 전용 최소권한 DB 계정(`gochuchamchi_app`, DML만+REQUIRE SSL)을 배스천 런타임에서 생성/주입해 **앱 DB 비밀번호가 tfstate에 안 남는 구조**로 전환(마스터 비번의 state 평문 저장도 제거 — #1 ESO 트리거 발동 상태였음) / RDS `require_secure_transport=1` + MARIADB_AUDIT_PLUGIN→CloudWatch / Redis를 replication_group으로 교체해 TLS+AUTH(#14 이행, 세션 초기화 발생) / 배스천·앱 IAM의 `rds!*` 와일드카드를 정확한 ARN 2개로 축소 / SG egress 제거 / 보안백로그 B1~B6 이행(ESO·NetworkPolicy·GuardDuty) — **§4: 그 apply를 실제로 돌리며 장애 5건 복구** (SSM에 `HOME`이 없어 kubectl이 `localhost:8080`으로 폴백 / **helm이 YAML 주석 안의 `{{ }}`도 파싱**해 차트 깨짐 / ESO 전환으로 필수가 된 PAT 수동 주입 누락 → 503 `Backend service does not exist` / **NetworkPolicy가 서비스 CIDR을 안 열어 DNS 전면 차단** → 앱 전체 500 / Redis AUTH 미주입 + **고친 매니페스트가 kustomize `resources`에 없는 잔재 파일**이라 반영 안 됨) — **§5: destroy→재구축 사이클에서 실패 9건** (계정당 1개인 Cost Anomaly Monitor를 매번 생성 시도 → `Limit exceeded` / **Inspector2는 5분 타임아웃이 나도 AWS 작업은 완료돼** apply는 `tainted`, destroy는 state 잔존으로 갈라짐 / `NotReady` 노드의 파드 하나가 네임스페이스를 `Terminating`에 영구 고정 / **`destroy`는 config가 아니라 prior state를 읽어** `force_destroy` 변경이 안 먹음 / 진짜 원인은 **Object Lock COMPLIANCE — 루트도 9/2까지 삭제 불가**, `delete-objects`의 `Quiet` 응답을 버려 76,489건 무한 재시도한 오진 포함 / 못 지운 버킷이 다음 apply에서 이름 충돌 → import / `IMMEDIATE`+`EMAIL` 조합 금지 / **git 우회 파일 다운로드로 수정 3개 유실**돼 같은 에러 재발) — 6/9가 "유지할 것과 부술 것이 같은 state"에서 기인 → **레이어 3분할 제안** — **§6: destroy 교착의 진짜 원인은 Kyverno 고아 웹훅**(§5에서 개별 증상 3건으로 기록한 것이 실은 하나의 원인이었음 — resource webhook은 helm이 아니라 컨트롤러가 런타임에 등록해 `helm uninstall` 후에도 남고, `failurePolicy: Fail`이라 API 서버가 **모든 변경을 거부** → 파드 삭제 불가·네임스페이스 고착·helm uninstall 실패가 동시 발생. `kubectl delete`조차 거부당해서 발견) / **`validationFailureAction`(정책 위반)과 `failurePolicy`(웹훅 연결 실패)를 혼동**한 주석이 출발점 — 차트 기본값은 `Fail`인데 주석은 `Ignore`라고 기술 → `failurePolicy = "Ignore"` 명시 / `timeouts` 블록만 추가하면 diff가 없어 **state에 기록되지 않아** 재생성 전까지 무효(`force_destroy`와 같은 계열) / 나머지 2건은 인프라가 아니라 **작업 PC PMTUD**(8/3 기록분 재발) — **최종 `Destroy complete! 102 destroyed`, 에러 0건, 고아 자원 0** |
| 2026-08-03 | [2026-08-03.md](2026-08-03.md) | 재구축 후 사이트 복구 4건 — `helm_release`의 `Error locating chart`가 작업 PC의 **PMTUD 블랙홀**(MTU 1500 vs 경로 1492)이었던 건(단독 테스트는 통과해서 일시 장애로 오진) / kubeconfig가 삭제된 옛 클러스터를 가리켜 `no such host` / **회원가입 500 — `schema.sql`이 한 번도 실행되지 않음**(RDS 준비 전 실행 + `rm`이 종료코드를 덮고 프로비저너가 Status를 검사하지 않아 terraform이 성공으로 기록, 트리거가 그대로라 재시도도 안 됨) / ECR 비어 503 + 이미지 푸시 후에도 kubelet 백오프로 안 붙던 건 / ArgoCD port-forward 미기동 / `rds-schema-init.tf` 3곳 수정 / runbook §5.1·§6.3 신설, §8 전면 개편 |
| 2026-07-31 | [2026-07-31.md](2026-07-31.md) | **ECR state 분리 매뉴얼 작성 — 계획만 수립되고 미실행**(`go/ecr/` 없음, `ecr.tf` 그대로, state에 리소스 5개 잔존, S3에 `ecr/terraform.tfstate` 없음 → 2026-08-03에 같은 503 문제 재발) / `.tf` 11개 수정 흔적은 git 이력이 없어 **내용 복원 불가**(채워 넣을 공란 있음) / 알림 모듈 2개의 state 파일이 버킷에 없는 것 발견 ※ 8/3 사후 재구성 |
| 2026-07-30 | [2026-07-30.md](2026-07-30.md) | 문서 구조를 날짜별로 분할 / EKS 엔드포인트 `/32` 허용목록 밖에서 apply해 kubernetes·helm 리소스 전부 TCP 타임아웃 / destroy로 비워진 ECR 때문에 `ImagePullBackOff` → 사이트 503 / ArgoCD internal ALB 접속 경로와 port-forward 프로토콜 함정 / 배스천 유지 근거 정리 / AWS Config·Security Hub 모듈 연결 및 타겟 apply (시크릿 변수 때문에 전체 apply 불가) / 로그 인프라(CloudWatch·Grafana·CloudTrail·Athena) 별도 브랜치에서 운영으로 병합 / `data.aws_lb`와 IngressGroup 순환으로 2단계 apply / IngressGroup 전환 시 옛 ALB 스택 고아화 → 수동 정리 / ACM deposed 객체 / IAM description에 한글 불가 / Kinesis 계열 계정 단위 차단(`SubscriptionRequiredException`) / 검증 명령 모음(실행 위치 구분) |
| 2026-07-29 | [2026-07-29.md](2026-07-29.md) | EKS+ArgoCD+Discord 재구축 트러블슈팅 (destroy 교착 3차 재발 포함) / `gochuchamchi.shop` NXDOMAIN / Docker Hub → ECR 마이그레이션 |
| 2026-07-28 | [2026-07-28.md](2026-07-28.md) | 메인 페이지 텍스처 배경 미노출 / 상품 등록 이미지 업로드 413 |

### 새 날짜 파일 작성 형식

```markdown
# YYYY-MM-DD 작업 기록

## 1. <한 줄 제목>

### 작업 목적
### 문제가 발생한 지점
### 문제 원인
### 해결 방법
### 검증 완료 사항
```

- 하루에 여러 건이면 `## 1.`, `## 2.` … 로 건별 번호를 붙이고, 세부 이슈는 `### 1.1`, `### 1.2` 로 나눕니다.
- 같은 이슈가 나중에 재발하면 `### 1.2-1`, `### 1.2-2` 처럼 하위 번호로 이어 붙입니다.
- 재사용 가치가 있는 교훈은 [pitfalls-checklist.md](pitfalls-checklist.md)에도 한 줄 추가합니다.
- 작성 후 위 표에 최신 날짜를 맨 위로 추가합니다.

## 상시 참고 문서

| 파일 | 내용 |
|---|---|
| **[runbook.md](runbook.md)** | **자주 쓰는 명령어 치트시트** — 접속(배스천/kubectl/ArgoCD/RDS/Redis), 상태 확인, 배포, terraform, 재구축 후 복구 체크리스트, 에러별 빠른 판별 |
| [architecture.md](architecture.md) | 초기 구축 기록 — 최종 아키텍처, k8s 매니페스트 자동 배포 파이프라인, 배스천/RDS/ALB 구성, 자주 쓴 디버깅 명령, 작업 PC 이전 체크리스트 |
| [pitfalls-checklist.md](pitfalls-checklist.md) | 재발 방지 체크리스트 (누적) — 지금까지 밟은 함정 전부 |
| [SECURITY_AUDIT_REPORT.md](SECURITY_AUDIT_REPORT.md) | 보안 점검 보고서 및 조치 이력 |
| [SECURITY_BACKLOG.md](SECURITY_BACKLOG.md) | **보안 잔여 과제 백로그** — 감사 이후에도 남은 문제(노드 SG 전 포트 개방, SSH 키 잔존, ESO 도입, ArgoCD admin 비번, NetworkPolicy 등) + "ESO 트리거" 용어 해설 |
| [CICD_SETUP.md](CICD_SETUP.md) | CI/CD 구성 가이드 — 3개 저장소의 파이프라인 설계(CD는 ArgoCD pull, CI는 클러스터 무접촉), 러너 선택지, `ci-templates/` 배치 |
| [IMAGE_SIGNING_SETUP.md](IMAGE_SIGNING_SETUP.md) | 컨테이너 이미지 서명 — 빌드/서명 역할 분리(KMS cosign), `signed-*` 태그 승격, Kyverno 서명 검증 적용 절차 |
| [DB_SECRET_SETUP.md](DB_SECRET_SETUP.md) | DB 비밀번호 / K8s Secret 구성 방법 |
| [REDIS_SESSION_GUIDE.md](REDIS_SESSION_GUIDE.md) | Redis 세션 공유 설정 가이드 |

프로젝트 루트의 `SETUP-NEW-WORKER.txt`는 새 팀원 온보딩용 별도 안내서입니다.
