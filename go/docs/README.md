# gochuchamchi-eks 문서 인덱스

`gochuchamchi-eks` 프로젝트의 작업 기록 · 트러블슈팅 · 참고 문서 모음입니다.
Terraform 코드와는 무관하며(`.tf` 어디에서도 참조하지 않음), 문서만 보관합니다.

## 날짜별 작업 기록

작업한 내용과 트러블슈팅은 **하루 단위로 `YYYY-MM-DD.md` 파일 하나**에 기록합니다.

| 날짜 | 파일 | 내용 |
|---|---|---|
| 2026-08-04 | [2026-08-04.md](2026-08-04.md) | **제로트러스트 DB 하드닝** — 앱 전용 최소권한 DB 계정(`gochuchamchi_app`, DML만+REQUIRE SSL)을 배스천 런타임에서 생성/주입해 **앱 DB 비밀번호가 tfstate에 안 남는 구조**로 전환(마스터 비번의 state 평문 저장도 제거 — #1 ESO 트리거 발동 상태였음) / RDS `require_secure_transport=1` + MARIADB_AUDIT_PLUGIN→CloudWatch / Redis를 replication_group으로 교체해 TLS+AUTH(#14 이행, 세션 초기화 발생) / 배스천·앱 IAM의 `rds!*` 와일드카드를 정확한 ARN 2개로 축소 / SG egress 제거 / 보안백로그 B1~B6 이행(ESO·NetworkPolicy·GuardDuty) — **§4: 그 apply를 실제로 돌리며 장애 5건 복구** (SSM에 `HOME`이 없어 kubectl이 `localhost:8080`으로 폴백 / **helm이 YAML 주석 안의 `{{ }}`도 파싱**해 차트 깨짐 / ESO 전환으로 필수가 된 PAT 수동 주입 누락 → 503 `Backend service does not exist` / **NetworkPolicy가 서비스 CIDR을 안 열어 DNS 전면 차단** → 앱 전체 500 / Redis AUTH 미주입 + **고친 매니페스트가 kustomize `resources`에 없는 잔재 파일**이라 반영 안 됨) |
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
| [DB_SECRET_SETUP.md](DB_SECRET_SETUP.md) | DB 비밀번호 / K8s Secret 구성 방법 |
| [REDIS_SESSION_GUIDE.md](REDIS_SESSION_GUIDE.md) | Redis 세션 공유 설정 가이드 |

프로젝트 루트의 `SETUP-NEW-WORKER.txt`는 새 팀원 온보딩용 별도 안내서입니다.
