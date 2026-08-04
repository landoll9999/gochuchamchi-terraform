# DB 자격증명 구조 (2026-08-04 제로트러스트 전환 이후)

> 이 문서는 원래 "배스천에서 마스터 비밀번호를 조회해 K8s Secret을 수동 생성"하는
> 가이드였으나, 그 절차는 **전부 자동화되어 폐기**됐습니다. 현재 구조와 트러블슈팅
> 진입점만 남깁니다. 상세 설계는 `terraform/db-zero-trust.tf` 헤더 주석과
> `docs/2026-08-04.md` 참고.

## 현재 구조 — 수동 작업 없음

`terraform apply` 한 번에 아래가 자동으로 이뤄집니다 (`null_resource.provision_app_db_user`):

1. 앱 전용 계정 `gochuchamchi_app` 생성 — `gochuchamchi.*`에 DML만, `REQUIRE SSL`
2. 비밀번호는 배스천 런타임에서 생성 → Secrets Manager `gochuchamchi/app/db-credentials`에 저장
   (**terraform state에 안 남음** — Terraform은 빈 Secret 컨테이너만 관리)
3. K8s Secret `gochuchamchi-db-app`(키 `DB_PASS`)으로 주입 — 앱 파드가 이걸 씀
4. 재실행해도 안전 (기존 비밀번호 재사용, upsert)

| 항목 | 값 |
|---|---|
| 앱 DB 계정 | `gochuchamchi_app` (ConfigMap `DB_USER`) |
| 앱 비밀번호 위치 | K8s Secret `gochuchamchi-db-app` + Secrets Manager `gochuchamchi/app/db-credentials` |
| 마스터(admin) 비밀번호 위치 | Secrets Manager만 (`terraform output -raw rds_secret_arn`) — K8s/state에 없음 |
| 접속 방법 | `docs/runbook.md` §1.4 (앱 계정 ③ / 마스터 ④, `--ssl` 필수) |

## Secret이 없어서 파드가 `CreateContainerConfigError`일 때

```powershell
# 프로비저너 재실행 (비밀번호는 재사용되므로 안전)
terraform taint null_resource.provision_app_db_user
terraform apply
```

- apply 직후 잠깐의 `CreateContainerConfigError`는 정상 — 프로비저너가 Secret을 만들면 kubelet이 자동 재시도
- 네임스페이스를 재생성한 경우는 트리거(`namespace_uid`)가 바뀌므로 taint 없이 apply만으로 다시 돕니다

## ESO(External Secrets Operator) 도입 시

Secrets Manager가 이미 원본(source of truth)이므로, ESO를 붙이면 배스천의 K8s Secret
주입 단계만 ESO 동기화로 대체하면 됩니다. 이관 1순위는 state에 남아 있는
Redis `auth_token`입니다 (`redis.tf` 주석 참고).
