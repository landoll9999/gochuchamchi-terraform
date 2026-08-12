# =============================================================================
# 제로트러스트 DB 계정 분리 + 자격증명 무(無)state 주입  (2026-08-04)
#
# 무엇이 문제였나
#   1) 앱 파드가 DB "마스터(admin)" 계정으로 접속 — 앱이 침해되면(SQL 인젝션,
#      의존성 취약점 등) 곧바로 DBA 권한: DROP TABLE / GRANT / 다른 DB 생성까지 가능
#   2) k8s-deploy.tf가 마스터 비밀번호를 data 소스로 읽어 K8s Secret을 만들면서
#      tfstate에 평문 저장 — SECURITY_AUDIT_REPORT #1의 "state에 secret_string이
#      다시 들어가는 시점"(ESO 도입 트리거)이 이미 발동된 상태였음
#
# 어떻게 바꿨나 (제로트러스트 3원칙에 대응)
#   [최소권한]  앱 전용 계정 gochuchamchi_app — gochuchamchi.* 에 DML
#               (SELECT/INSERT/UPDATE/DELETE)만. DDL/DCL 불가
#               -> 인젝션이 터져도 스키마 파괴·권한 상승은 원천 차단
#   [명시적 검증] REQUIRE SSL — 이 계정은 TLS 없이는 로그인 자체가 불가
#               (rds.tf require_secure_transport=1 전역 강제와 이중 방어)
#   [침해 가정]  비밀번호 생성 -> Secrets Manager 저장 -> DB 계정 생성 -> K8s Secret
#               주입을 전부 "배스천 런타임"에서 수행 -> 앱 DB 비밀번호가 terraform
#               state에 단 한 번도 안 들어감. Terraform은 값이 빈 Secret "컨테이너"만
#               관리. 비밀값은 SSM 커맨드 로그에 안 남고(변수명만 기록됨), 배스천
#               안에서도 env/파일(600, 즉시 삭제)로만 전달 — 외부 프로세스 인자
#               (argv)로는 안 넘겨서 ps 순간 노출까지 차단 (감사보고서 #13 원칙 확장)
#
# 앱 쪽에서 바뀌는 것: DB_USER는 ConfigMap이 gochuchamchi_app으로 변경(k8s-deploy.tf),
# DB_PASS는 K8s Secret "gochuchamchi-db-app"에서 옴 — gitops의 03-deployment-web.yml에서
# secret 이름만 gochuchamchi-db-secret -> gochuchamchi-db-app 으로 교체하면 됨(키 동일).
# =============================================================================

resource "aws_secretsmanager_secret" "app_db" {
  name        = "gochuchamchi/app/db-credentials"
  description = "gochuchamchi_app DB user credentials (value written by bastion, never by Terraform)"

  # 실습용: destroy 후 같은 이름으로 즉시 재생성할 수 있게 유예 0일. 운영은 7~30일 권장
  # (0이 아니면 destroy 후 재-apply 때 "scheduled for deletion" 이름 충돌이 남)
  recovery_window_in_days = 0
}

output "app_db_secret_arn" {
  value       = aws_secretsmanager_secret.app_db.arn
  description = "앱 전용 DB 자격증명 Secret — 값은 배스천이 채움 (state에 없음)"
}

resource "null_resource" "provision_app_db_user" {
  triggers = {
    rds_id     = data.aws_db_instance.this.db_instance_identifier
    secret_arn = aws_secretsmanager_secret.app_db.arn
    # K8s Secret(gochuchamchi-db-app)은 Terraform 관리 밖 -> 네임스페이스만 단독
    # 재생성되면 Secret은 증발하는데 트리거는 그대로라 재실행이 안 됨. uid는
    # 네임스페이스가 재생성될 때마다 바뀌므로 이 경우 자동으로 다시 돈다.
    namespace_uid = kubernetes_namespace_v1.gochuchamchi.metadata[0].uid
    # 아래 스크립트를 고치면 이 값을 올려서 재실행 (비밀번호는 재사용되므로 안전)
    script_version = "v3"
  }

  depends_on = [
    module.rds,
    null_resource.apply_db_schema, # gochuchamchi.* 스키마가 먼저 있어야 GRANT 대상이 존재
    module.bastion_host,
    kubernetes_namespace_v1.gochuchamchi, # K8s Secret을 넣을 네임스페이스
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      # 배스천 SSM 온라인 대기 (schema init과 별도로 단독 재실행(taint)될 수 있어 유지)
      $maxRetries = 20; $retry = 0; $isOnline = $false
      while ($retry -lt $maxRetries -and -not $isOnline) {
        $status = aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${module.bastion_host.id}" --region ${var.region} --profile ${var.aws_profile} --query "InstanceInformationList[0].PingStatus" --output text
        if ($status -eq "Online") { $isOnline = $true; Write-Host "배스천 SSM 온라인 확인됨" }
        else { Write-Host "SSM 대기 중... ($retry/$maxRetries)"; Start-Sleep -Seconds 15; $retry++ }
      }
      if (-not $isOnline) { Write-Error "배스천이 SSM 온라인 상태가 아닙니다."; exit 1 }

      # 비밀값은 전부 배스천 "런타임"에서 조회/생성 -> SSM 커맨드 텍스트(로그)에는
      # 변수명만 남고 값은 안 남는다. 배스천 안에서의 전달 규칙:
      #   - 외부 프로세스(python3/kubectl/mysql)에 인자(argv)로 안 넘김 — argv는 실행
      #     순간 ps에 노출됨. env 접두(VAR=x cmd)나 파일(umask 077=600, 즉시 삭제)만 사용.
      #     printf는 셸 내장이라 인자로 받아도 프로세스가 안 뜸 -> 예외.
      #   - mysql 인증은 MYSQL_PWD — 옵션 파일(.my.cnf)은 비밀번호에 '#'이 섞이면
      #     주석으로 잘려 조용히 실패한다 (runbook §1.4에서 확인된 함정. RDS 관리형
      #     마스터 비밀번호는 '#' 포함 가능)
      $cmds = @(
        'set -e',
        "which mysql || sudo dnf install -y mariadb105",
        # SSM은 root로 실행됨: root용 kubeconfig를 매번 갱신(멱등) + ec2-user의 kubectl 사용.
        # 단 SSM 셸에는 HOME이 안 잡혀서 ~/.kube/config 기본 경로가 해석되지 않는다
        # -> kubectl이 kubeconfig를 못 찾고 localhost:8080으로 붙어 connection refused.
        # 그래서 경로를 양쪽 다 명시: 쓸 때는 --kubeconfig, 읽을 때는 KUBECONFIG env
        'export KUBECONFIG=/root/.kube/config',
        'mkdir -p /root/.kube',
        "aws eks update-kubeconfig --name ${var.cluster_name} --region ${var.region} --kubeconfig /root/.kube/config > /dev/null",
        'umask 077',
        # 1) 앱 비밀번호: Secret에 이미 값이 있으면 재사용(멱등 — 재실행해도 로테이션 안 됨)
        'APP_PASS=$(aws secretsmanager get-secret-value --secret-id ''${aws_secretsmanager_secret.app_db.arn}'' --region ${var.region} --query SecretString --output text 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)[''password''])" 2>/dev/null || true)',
        'if [ -z "$APP_PASS" ]; then APP_PASS=$(openssl rand -base64 24 | tr ''+/'' ''-_''); echo "새 앱 비밀번호 생성"; else echo "기존 앱 비밀번호 재사용"; fi',
        # 2) Secrets Manager에 저장 (호스트가 바뀌었을 수도 있어 매번 갱신. 비밀번호는 env로 전달)
        'APP_PASS="$APP_PASS" python3 -c "import json,sys,os;json.dump({''username'':''gochuchamchi_app'',''password'':os.environ[''APP_PASS''],''host'':sys.argv[1],''port'':''3306'',''dbname'':''gochuchamchi''},open(''/home/ec2-user/app-db-secret.json'',''w''))" "${data.aws_db_instance.this.address}"',
        'aws secretsmanager put-secret-value --secret-id ''${aws_secretsmanager_secret.app_db.arn}'' --region ${var.region} --secret-string file:///home/ec2-user/app-db-secret.json > /dev/null',
        # 3) 마스터로 접속해 앱 계정 생성/수렴 (CREATE IF NOT EXISTS + ALTER 조합 = 재실행 안전)
        'SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ''${module.rds.db_instance_master_user_secret_arn}'' --region ${var.region} --query SecretString --output text)',
        'DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)[''password''])")',
        'printf "CREATE USER IF NOT EXISTS ''gochuchamchi_app''@''%%'' IDENTIFIED BY ''%s'' REQUIRE SSL;\nALTER USER ''gochuchamchi_app''@''%%'' IDENTIFIED BY ''%s'' REQUIRE SSL;\nGRANT SELECT, INSERT, UPDATE, DELETE ON gochuchamchi.* TO ''gochuchamchi_app''@''%%'';\nFLUSH PRIVILEGES;\n" "$APP_PASS" "$APP_PASS" > /home/ec2-user/app-user.sql',
        'MYSQL_PWD="$DB_PASS" mysql --ssl -h ${data.aws_db_instance.this.address} -u admin < /home/ec2-user/app-user.sql',
        # 4) K8s Secret 생성/갱신 (dry-run|apply 패턴 = 멱등 upsert). DB_USER는 ConfigMap 담당
        #    --from-file(600 파일) 사용 — --from-literal은 값이 kubectl의 argv에 실림
        'printf %s "$APP_PASS" > /home/ec2-user/app-db-pass',
        '/home/ec2-user/bin/kubectl create secret generic gochuchamchi-db-app -n gochuchamchi --from-file=DB_PASS=/home/ec2-user/app-db-pass --dry-run=client -o yaml | /home/ec2-user/bin/kubectl apply -f -',
        # 5) 검증: 앱 계정으로 "TLS" 접속이 되는지 + 권한이 DML뿐인지 + 실제 암호화 여부
        'MYSQL_PWD="$APP_PASS" mysql --ssl -h ${data.aws_db_instance.this.address} -u gochuchamchi_app -e "SELECT CURRENT_USER() AS whoami; SHOW GRANTS FOR CURRENT_USER; SHOW STATUS LIKE ''Ssl_cipher'';"',
        'rm -f /home/ec2-user/app-user.sql /home/ec2-user/app-db-secret.json /home/ec2-user/app-db-pass',
        'echo "APP DB USER PROVISIONED"'
      )

      $json = @{ commands = $cmds } | ConvertTo-Json -Depth 5
      $json | Out-File -Encoding ascii -NoNewline provision-app-user-params.json

      $cmdId = aws ssm send-command --instance-ids ${module.bastion_host.id} --document-name "AWS-RunShellScript" --parameters file://provision-app-user-params.json --region ${var.region} --profile ${var.aws_profile} --query "Command.CommandId" --output text

      # rds-schema-init.tf와 동일한 원칙: 완료까지 폴링 + Status 검사 (실패를 삼키지 않음)
      $maxRetries = 40; $retry = 0; $cmdStatus = "Pending"
      while ($retry -lt $maxRetries -and ($cmdStatus -eq "Pending" -or $cmdStatus -eq "InProgress")) {
        Start-Sleep -Seconds 15
        $cmdStatus = aws ssm get-command-invocation --command-id $cmdId --instance-id ${module.bastion_host.id} --region ${var.region} --profile ${var.aws_profile} --query "Status" --output text
        $retry++
      }

      Write-Host "--- SSM stdout ---"
      aws ssm get-command-invocation --command-id $cmdId --instance-id ${module.bastion_host.id} --region ${var.region} --profile ${var.aws_profile} --query "StandardOutputContent" --output text

      if ($cmdStatus -ne "Success") {
        Write-Host "--- SSM stderr ---"
        aws ssm get-command-invocation --command-id $cmdId --instance-id ${module.bastion_host.id} --region ${var.region} --profile ${var.aws_profile} --query "StandardErrorContent" --output text
        Write-Error "앱 DB 계정 프로비저닝 실패 (Status=$cmdStatus). 재시도: terraform taint null_resource.provision_app_db_user"
        exit 1
      }
      Write-Host "앱 DB 계정 프로비저닝 완료"
    EOT
  }
}

# =============================================================================
# (2026-08-12) IAM 토큰 인증 전용 DB 계정 — 비밀번호 → 토큰 전환의 1단계
#
# 왜 "전환"이 아니라 "추가"인가
#   AWSAuthenticationPlugin 으로 만든 계정은 비밀번호 인증이 불가능해진다. 둘 중
#   하나만 된다. 그래서 gochuchamchi_app 을 그대로 바꾸면, 앱이 토큰을 발급받도록
#   고쳐지기 전까지 파드가 즉시 DB 접속에 실패한다(= 사이트 다운). 기존 계정은
#   그대로 두고 토큰 전용 계정을 하나 더 만든다. 이 시점에는 이 계정을 쓰는 쪽이
#   없으므로 서비스 영향이 0이다.
#
#   전환 순서: (1) 이 계정 추가 -> (2) 앱이 토큰 쓰도록 변경(Spring 저장소, 별도)
#              -> (3) 확인 후 gochuchamchi_app 제거
#
# 비밀번호 방식 대비 무엇이 나아지나
#   - 자격증명이 15분 뒤 만료된다(AWS 고정값, 조정 불가). 유출돼도 수명이 짧다.
#   - dbuser ARN 이 "DB 리소스 ID / 유저명"까지 못박혀서, 그 IAM 역할을 실제로
#     가진 주체만 접속할 수 있다. 비밀번호처럼 "값만 알면 누구나"가 아니다.
#   - 저장할 비밀번호가 아예 없다 — Secrets Manager 보관·회전 부담이 사라진다.
#     (현재 gochuchamchi_app 은 자동 회전이 걸려 있지 않은 상태다)
#
# 참고: RDS for MariaDB 는 IAM DB 인증을 지원한다. rds.tf 에 "미지원"이라고
# 적혀 있던 것은 오기였고 2026-08-12 에 API 로 확인해 정정했다.
# =============================================================================

resource "aws_iam_policy" "app_db_iam_auth" {
  name        = "gochuchamchi-app-db-iam-auth"
  description = "앱 파드가 gochuchamchi_app_iam 유저로만 RDS IAM 토큰 인증을 하도록 허용"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "rds-db:connect"
      # 유저명까지 리소스에 박는다 — 이 역할로는 다른 DB 유저가 될 수 없고,
      # 유저명을 바꾸면 그 즉시 권한이 끊긴다.
      Resource = "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.db_instance_resource_id}/gochuchamchi_app_iam"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "app_db_iam_auth" {
  role       = aws_iam_role.gochuchamchi_app_role.name
  policy_arn = aws_iam_policy.app_db_iam_auth.arn
}

# 배스천에도 같은 권한을 준다 — 아래 프로비저닝의 마지막 단계에서 실제로 토큰을
# 발급받아 접속되는지 검증하기 위해서다. 배스천은 이미 마스터 비밀번호를 읽을 수
# 있으므로(iamRole.tf 의 bastion_secrets_read) 권한 확대가 아니라 같은 수준의 다른 경로다.
resource "aws_iam_role_policy" "bastion_db_iam_auth" {
  name = "bastion-db-iam-auth"
  role = aws_iam_role.bastion_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.db_instance_resource_id}/gochuchamchi_app_iam"
    }]
  })
}

resource "null_resource" "provision_app_db_iam_user" {
  triggers = {
    rds_id     = data.aws_db_instance.this.db_instance_identifier
    policy_arn = aws_iam_policy.app_db_iam_auth.arn
    # 계정은 K8s 리소스가 아니지만, 네임스페이스 재생성 = 전체 재구축 신호라 함께 재실행
    namespace_uid = kubernetes_namespace_v1.gochuchamchi.metadata[0].uid
    # 아래 스크립트를 고치면 이 값을 올려서 재실행
    script_version = "v1"
  }

  depends_on = [
    module.rds,
    null_resource.apply_db_schema, # GRANT 대상 스키마가 먼저 있어야 한다
    module.bastion_host,
    # 같은 마스터 접속을 쓰므로 기존 계정 프로비저닝 뒤에 돌려 충돌을 피한다
    null_resource.provision_app_db_user,
    # 검증 단계에서 배스천이 토큰을 발급하므로 권한이 먼저 붙어 있어야 한다
    aws_iam_role_policy.bastion_db_iam_auth,
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      $cmds = @(
        'set -e',
        "which mysql || sudo dnf install -y mariadb105",
        'umask 077',
        'SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ''${module.rds.db_instance_master_user_secret_arn}'' --region ${var.region} --query SecretString --output text)',
        'DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)[''password''])")',
        # AWSAuthenticationPlugin = 비밀번호가 아니라 IAM 토큰으로만 인증. 저장되는
        # 비밀값이 없으니 재실행해도 로테이션 개념 자체가 없다(완전 멱등).
        # 권한은 gochuchamchi_app 과 동일하게 gochuchamchi.* DML 만 — DDL/DCL 불가.
        'printf "CREATE USER IF NOT EXISTS ''gochuchamchi_app_iam''@''%%'' IDENTIFIED WITH AWSAuthenticationPlugin AS ''RDS'' REQUIRE SSL;\nGRANT SELECT, INSERT, UPDATE, DELETE ON gochuchamchi.* TO ''gochuchamchi_app_iam''@''%%'';\nFLUSH PRIVILEGES;\n" > /home/ec2-user/app-iam-user.sql',
        'MYSQL_PWD="$DB_PASS" mysql --ssl -h ${data.aws_db_instance.this.address} -u admin < /home/ec2-user/app-iam-user.sql',
        # 검증: 실제로 토큰을 발급받아 붙는지 + 권한이 DML 뿐인지 + TLS 로 붙었는지.
        # 토큰도 비밀값이므로 env 로만 넘긴다(argv 는 ps 에 노출된다).
        'TOKEN=$(aws rds generate-db-auth-token --hostname ${data.aws_db_instance.this.address} --port 3306 --username gochuchamchi_app_iam --region ${var.region})',
        'MYSQL_PWD="$TOKEN" mysql --ssl -h ${data.aws_db_instance.this.address} -u gochuchamchi_app_iam -e "SELECT CURRENT_USER() AS whoami; SHOW GRANTS FOR CURRENT_USER; SHOW STATUS LIKE ''Ssl_cipher'';"',
        'rm -f /home/ec2-user/app-iam-user.sql',
        'echo "IAM DB USER PROVISIONED"'
      )

      $json = @{ commands = $cmds } | ConvertTo-Json -Depth 5
      $json | Out-File -Encoding ascii -NoNewline provision-app-iam-user-params.json

      $cmdId = aws ssm send-command --instance-ids ${module.bastion_host.id} --document-name "AWS-RunShellScript" --parameters file://provision-app-iam-user-params.json --region ${var.region} --profile ${var.aws_profile} --query "Command.CommandId" --output text

      $maxRetries = 40; $retry = 0; $cmdStatus = "Pending"
      while ($retry -lt $maxRetries -and ($cmdStatus -eq "Pending" -or $cmdStatus -eq "InProgress")) {
        Start-Sleep -Seconds 15
        $cmdStatus = aws ssm get-command-invocation --command-id $cmdId --instance-id ${module.bastion_host.id} --region ${var.region} --profile ${var.aws_profile} --query "Status" --output text
        $retry++
      }

      Write-Host "--- SSM stdout ---"
      aws ssm get-command-invocation --command-id $cmdId --instance-id ${module.bastion_host.id} --region ${var.region} --profile ${var.aws_profile} --query "StandardOutputContent" --output text

      if ($cmdStatus -ne "Success") {
        Write-Host "--- SSM stderr ---"
        aws ssm get-command-invocation --command-id $cmdId --instance-id ${module.bastion_host.id} --region ${var.region} --profile ${var.aws_profile} --query "StandardErrorContent" --output text
        Write-Error "IAM DB 계정 프로비저닝 실패 (Status=$cmdStatus). 재시도: terraform taint null_resource.provision_app_db_iam_user"
        exit 1
      }
      Write-Host "IAM DB 계정 프로비저닝 완료 — 앱은 아직 이 계정을 쓰지 않는다(전환 2단계에서)"
    EOT
  }
}
