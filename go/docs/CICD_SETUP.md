# CI/CD 구성 가이드 (2026-08-04)

3개 저장소에 흐르는 3종류의 변경을 각각 파이프라인으로 만든다.
설계 원칙: **CD는 이미 있다(ArgoCD, pull 방식). CI는 클러스터를 만질 필요가 없다.**
CI는 "원하는 상태"를 git에 커밋하는 데서 끝나고, 배포는 클러스터 안의 ArgoCD가
pull로 수행한다. 그래서 클러스터 자격증명이 GitHub에 존재하지 않는다 —
EKS `/32` 화이트리스트가 앱 CI/CD에는 장애물이 아닌 이유이기도 하다.

```
[앱 코드]    spring PR/push → CI: 테스트+SHA 태그 빌드+ECR push → gitops에 태그 커밋
                                                                      ↓
[매니페스트] gitops PR → CI: 계약검증+kustomize build+kubeconform → 머지 → ArgoCD sync
                                                                      (클러스터 안)
[인프라]     terraform PR → CI: fmt/validate/tflint/checkov → 머지 → apply(로컬) → 스모크 테스트
```

## 1. 파일 배치

| 파일 (이 저장소 기준) | 넣을 곳 |
|---|---|
| `.github/workflows/terraform-ci.yml` | **이 저장소** — 이미 배치됨 |
| `docs/ci-templates/for-spring-repo--build-and-deploy.yml` | `gochuchamchi-spring` 저장소 `.github/workflows/build-and-deploy.yml` |
| `docs/ci-templates/for-gitops-repo--gitops-ci.yml` | `gochuchamchi-gitops` 저장소 `.github/workflows/gitops-ci.yml` |
| `docs/ci-templates/for-gitops-repo--kustomization.yaml` | `gochuchamchi-gitops` 저장소 루트 `kustomization.yaml` |

## 2. 사전 설정 (1회)

### 2-1. GITOPS_PAT (spring 저장소 Secrets)

CI가 gitops에 태그 커밋을 푸시할 자격증명. **클러스터에 넣는 PAT와 별개**다 —
이건 GitHub Actions Secrets에만 존재한다.

- GitHub → Settings → Developer settings → Fine-grained tokens
- Repository access: **gochuchamchi-gitops 하나만**
- Permissions: **Contents: Read and write** (그 외 전부 No access)
- `gochuchamchi-spring` 저장소 → Settings → Secrets and variables → Actions →
  `GITOPS_PAT`로 등록

### 2-2. AWS 쪽 — 추가 설정 없음

`ecr.tf`의 OIDC 역할(`gochuchamchi-github-actions-ecr-push`)이 이미
`repo:landoll9999/gochuchamchi-spring:ref:refs/heads/main`만 assume을 허용한다.
새 워크플로가 이 조건과 정확히 일치하므로 그대로 쓴다. 액세스키는 어디에도 없다.

### 2-3. 브랜치 보호 (양쪽 저장소)

Settings → Branches → main 보호 규칙:
- Require a pull request before merging
- Require status checks: `verify`(gitops) / `validate`, `tflint`(terraform)

이게 있어야 "검증 실패 = 머지 불가"가 실제로 강제된다. 없으면 CI는 장식이다.

## 3. terraform-ci가 하는 것 / 안 하는 것

| 단계 | CI에서? | 이유 |
|---|---|---|
| fmt / validate / tflint | ✅ | `-backend=false`라 state·AWS 자격증명 불필요 |
| checkov 보안 스캔 | ✅ (soft_fail) | 의도적 절충(S3 퍼블릭 read 등, 문서화됨)이 걸리므로 처음엔 보고만. 운영 전환 시 정당 항목을 skip-check로 옮기고 hard fail로 승격 |
| plan / apply | ❌ 로컬 | kubernetes/helm 프로바이더가 EKS API에 붙어야 하는데 `/32` 허용목록에 호스티드 러너가 없음. **배스천 self-hosted runner를 붙이면**: PR에 plan 코멘트 + main 머지 시 Environment 승인 → apply → 스모크 테스트(enforce)로 완성. plan용(ReadOnly)/apply용 OIDC 역할 분리도 그때 `ecr.tf`에 추가 |

## 4. 컷오버 절차 — latest → SHA 태그 (순서 중요)

기존 `latest + Image Updater` 경로를 살려둔 채 전환하고, 확인 후 제거한다.

1. **gitops**: `kustomization.yaml` 추가 (resources에 **모든** 매니페스트 등재 —
   빠진 파일은 배포에서 제외된다), `gitops-ci.yml` 추가, PR로 머지.
   ⚠ `images.newTag`는 반드시 `latest`로 시작 — 지금 배포 상태와 동일해야
   머지가 무중단이다. placeholder를 두면 ArgoCD가 그 문자열을 태그로 렌더링해서
   ImagePullBackOff가 난다. 머지 후 사이트 정상 확인하고 다음 단계로.
2. **spring**: `build-and-deploy.yml` 추가(기존 워크플로 대체), `GITOPS_PAT` 등록.
   main에 푸시 → SHA 태그 + latest가 같이 푸시되고, gitops `newTag`가 SHA로 갱신됨.
3. **확인**: ArgoCD가 kustomize 렌더링 결과로 sync하는지, 파드 이미지가
   `:2026….-…` SHA 태그인지 (`kubectl -n gochuchamchi get pod -o jsonpath='{..image}'`).
4. **Image Updater 제거**: ArgoCD Application의 image-updater 어노테이션 삭제
   (+ image-updater 배포 자체를 쓰고 있으면 그것도 제거).
5. **클러스터 PAT 강등**: 새 fine-grained PAT를 **Contents: Read-only**로 발급 →
   `terraform output argocd_git_pat_inject_command`의 명령으로 재주입.
   이제 클러스터가 털려도 gitops에 쓸 수 없다 — 감사보고서의 "state 접근 = 배포
   권한" 등가가 깨진다. (ESO가 1시간 주기로 동기화하므로 즉시 반영하려면
   `kubectl -n argocd annotate externalsecret <이름> force-sync=$(date +%s)`)
6. **latest 제거**: `build-and-deploy.yml`에서 latest 푸시 두 줄 삭제.
7. **ECR IMMUTABLE**: `ecr.tf`의 `image_tag_mutability = "IMMUTABLE"`로 변경 후 apply.
   (6번 전에 하면 latest 재푸시가 거부되어 CI가 깨진다 — 순서 준수)

롤백: 어느 단계든 gitops에서 `git revert` 하면 ArgoCD가 이전 상태로 되돌린다.

## 5. 계약 동기화 규칙

gitops-ci의 `ALLOWED_REFS`/`FORBIDDEN_NAMES` 등 env 상수는
`go/terraform/contract.tf`의 `deployment_contract`와 같은 값이다.
**contract.tf를 바꾸면 gitops-ci.yml의 env도 같이 바꿔야 한다** — 계약 변경은
원래 두 저장소가 한 세트로 움직여야 하는 작업이므로(8/4 교훈), 이 중복은
"양쪽 PR을 강제로 만들게 하는" 의도된 마찰이다. 계약 변경이 잦아지면
`terraform output -json deployment_contract > contract.json`을 gitops에 커밋하는
방식으로 자동화한다.

## 6. 면접 설명

> "CD는 ArgoCD pull 방식이라 CI가 클러스터 자격증명을 가질 필요가 없게 설계했습니다.
> 앱 CI는 git SHA로 불변 태그를 만들어 OIDC로 ECR에 푸시하고, gitops 저장소의
> kustomize 이미지 태그를 커밋하는 데서 끝납니다. 덕분에 롤백이 git revert 하나가
> 됐고, ECR을 IMMUTABLE로 전환할 수 있었고, 클러스터가 쥐고 있던 gitops write PAT를
> read-only로 강등해 '클러스터 침해 = 공급망 커밋 권한'이라는 최악 경로를 끊었습니다.
> terraform은 PR에서 fmt/validate/tflint/checkov를 강제하되, plan/apply는 EKS
> 엔드포인트 /32 제한 때문에 로컬에 남겼고 — self-hosted runner를 붙이면 Environment
> 승인 기반 apply까지 올릴 계획입니다."
