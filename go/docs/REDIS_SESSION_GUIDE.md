# Redis 세션 스토어 적용 가이드

여러 Pod가 로그인 세션을 공유하게 하려면, 코드 한 군데만 바꾸면 됩니다.
(ALB가 요청을 다른 Pod로 분산시켜도 로그인이 안 풀리게 하는 목적)

## 1. pom.xml에 의존성 2개 추가

`src` 폴더와 같은 위치의 `pom.xml`에서, MariaDB 의존성 블록 바로 아래에 추가하세요:

```xml
<dependency>
  <groupId>org.mariadb.jdbc</groupId>
  <artifactId>mariadb-java-client</artifactId>
  <scope>runtime</scope>
</dependency>

<!-- Redis 세션 스토어 (추가) -->
<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-data-redis</artifactId>
</dependency>
<dependency>
  <groupId>org.springframework.session</groupId>
  <artifactId>spring-session-data-redis</artifactId>
</dependency>
```

## 2. application.yml에는 추가로 바꿀 것 없음

`k8s/gochuchamchi/02-configmap-app.yml`에서 환경변수로 넘겨주는 값들
(`SPRING_SESSION_STORE_TYPE=redis`, `SPRING_DATA_REDIS_HOST`, `SPRING_DATA_REDIS_PORT`)이
Spring Boot의 relaxed binding으로 자동 인식되기 때문에, application.yml 파일 자체는
안 건드려도 됩니다. (의존성만 pom.xml에 추가되어 있으면 Spring Boot가 자동으로
Redis 세션 저장소를 활성화합니다.)

## 3. 커밋 & 푸시

```bash
git add pom.xml
git commit -m "feat: Redis 세션 스토어 추가 (다중 Pod 간 세션 공유)"
git push
```

GitHub Actions가 새 이미지를 Docker Hub에 자동으로 빌드/푸시합니다.

## 4. k8s에 반영

`terraform apply` 이후 나온 `redis_endpoint` 값을
`02-configmap-app.yml`의 `SPRING_DATA_REDIS_HOST`에 채워 넣고:

```bash
kubectl apply -f 02-configmap-app.yml
kubectl set image deployment/gochuchamchi-web gochuchamchi-web=dnjstjr504/gochuchamchi:<새 커밋 SHA> -n gochuchamchi
kubectl rollout restart deployment/gochuchamchi-web -n gochuchamchi
```

## 5. 확인

```bash
kubectl logs -n gochuchamchi -l app=gochuchamchi-web --tail=50 | grep -i redis
```
`RedisHttpSessionConfiguration` 또는 `Redis` 관련 초기화 로그가 에러 없이 뜨면 정상입니다.

로그인 후, 페이지를 여러 번 새로고침하거나 다른 메뉴로 이동해도 로그인 상태가
유지되는지 확인해보세요.
