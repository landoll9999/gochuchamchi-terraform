# =============================================================================

variable "retire_legacy_app_db_user" {
  description = "Web/Admin 전환 검증 후 기존 gochuchamchi_app_iam DB 사용자를 삭제할지 여부"
  type        = bool
  default     = false
}

locals {
  # RDS는 daily-up 때 재생성될 수 있으므로 "삭제를 미룬다"만으로는 부족하다.
  # GitOps main의 레거시 Deployment가 gochuchamchi_app_iam을 사용하는 동안에는
  # 매번 계정과 기존 DML 권한을 다시 만들고, 전환 완료 후 명시적으로 삭제한다.
  legacy_app_db_compat_sql = (var.retire_legacy_app_db_user ?
    "DROP USER IF EXISTS ''gochuchamchi_app_iam''@''%%'';\\n" :
    "CREATE USER IF NOT EXISTS ''gochuchamchi_app_iam''@''%%'' IDENTIFIED WITH AWSAuthenticationPlugin AS ''RDS'' REQUIRE SSL;\\nGRANT SELECT, INSERT, UPDATE, DELETE ON gochuchamchi.* TO ''gochuchamchi_app_iam''@''%%'';\\n"
  )
}
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
# (2026-08-13) 위 [침해 가정] 항목은 역사 기록이다. 비밀번호 계정 gochuchamchi_app 과
# 그 자격증명 일체(Secrets Manager 시크릿, K8s Secret gochuchamchi-db-app, 배스천
# 프로비저닝 112줄)를 이 파일에서 제거했다. 아래 IAM 토큰 계정만 남는다.
#
#   왜 지웠나 — 토큰으로 바꾼 목적이 "상시 유효한 자격증명을 없애는 것"인데,
#   비밀번호 계정을 남겨두면 그 목적이 반감된다. 앱이 토큰을 쓰기 시작한 뒤에도
#   DB_PASS 는 envFrom 으로 파드 환경변수에 계속 앉아 있었고, 쓰이지도 않으면서
#   파드가 침해되면 그대로 읽히는 값이었다. 게다가 그 자격증명은 15분이 아니라
#   무기한 유효하다. 안 쓰는 문이라도 열려 있으면 문이다.
#
#   청소가 간단했던 이유 — DB 인스턴스가 매일 재생성되므로 계정은 매일 아침
#   새로 만들어지던 것이었다. 즉 "만드는 코드를 지우면" 다음 아침부터 그 계정은
#   태어나지 않는다. DROP USER 로 쫓아다닐 잔재가 없다.
# =============================================================================

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
  description = "전환 중 구 App 파드가 gochuchamchi_app_iam 유저로 계속 접속하도록 유지"

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

resource "aws_iam_policy" "web_db_iam_auth" {
  name        = "gochuchamchi-web-db-iam-auth"
  description = "Web 파드가 gochuchamchi_web_iam 유저로만 RDS IAM 토큰 인증을 하도록 허용"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.db_instance_resource_id}/gochuchamchi_web_iam"
    }]
  })
}

resource "aws_iam_policy" "admin_db_iam_auth" {
  name        = "gochuchamchi-admin-db-iam-auth"
  description = "Admin 파드가 gochuchamchi_admin_iam 유저로만 RDS IAM 토큰 인증을 하도록 허용"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.db_instance_resource_id}/gochuchamchi_admin_iam"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "admin_db_iam_auth" {
  role       = aws_iam_role.gochuchamchi_admin_role.name
  policy_arn = aws_iam_policy.admin_db_iam_auth.arn
}

resource "aws_iam_role_policy_attachment" "app_db_iam_auth" {
  role       = aws_iam_role.gochuchamchi_app_role.name
  policy_arn = aws_iam_policy.app_db_iam_auth.arn
}

resource "aws_iam_role_policy_attachment" "web_db_iam_auth" {
  role       = aws_iam_role.gochuchamchi_web_role.name
  policy_arn = aws_iam_policy.web_db_iam_auth.arn
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
      Effect = "Allow"
      Action = "rds-db:connect"
      Resource = [
        "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.db_instance_resource_id}/gochuchamchi_web_iam",
        "arn:aws:rds-db:${var.region}:${data.aws_caller_identity.current.account_id}:dbuser:${module.rds.db_instance_resource_id}/gochuchamchi_admin_iam"
      ]
    }]
  })
}

resource "null_resource" "provision_app_db_iam_user" {
  triggers = {
    rds_id     = data.aws_db_instance.this.db_instance_identifier
    policy_arn = aws_iam_policy.web_db_iam_auth.arn
    # 계정은 K8s 리소스가 아니지만, 네임스페이스 재생성 = 전체 재구축 신호라 함께 재실행
    namespace_uid = kubernetes_namespace_v1.gochuchamchi.metadata[0].uid
    # 아래 스크립트를 고치면 이 값을 올려서 재실행
    script_version = "v3-web-admin-legacy-compat"
    retire_legacy  = tostring(var.retire_legacy_app_db_user)
  }

  depends_on = [
    module.rds,
    null_resource.apply_db_schema, # GRANT 대상 스키마가 먼저 있어야 한다
    module.bastion_host,
    # 검증 단계에서 배스천이 토큰을 발급하므로 권한이 먼저 붙어 있어야 한다
    aws_iam_role_policy.bastion_db_iam_auth,
    aws_iam_role_policy_attachment.web_db_iam_auth,
    aws_iam_role_policy_attachment.admin_db_iam_auth,
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
        # Web은 관리자 행을 포함한 users 원본 테이블을 직접 볼 수 없다. SQL SECURITY
        # DEFINER + CHECK OPTION 뷰를 통해 user/seller 행만 노출하고 컬럼 권한도 축소한다.
        'printf "CREATE OR REPLACE SQL SECURITY DEFINER VIEW gochuchamchi.web_users AS SELECT * FROM gochuchamchi.users WHERE role IN (''user'',''seller'') WITH CASCADED CHECK OPTION;\nCREATE USER IF NOT EXISTS ''gochuchamchi_web_iam''@''%%'' IDENTIFIED WITH AWSAuthenticationPlugin AS ''RDS'' REQUIRE SSL;\nCREATE USER IF NOT EXISTS ''gochuchamchi_admin_iam''@''%%'' IDENTIFIED WITH AWSAuthenticationPlugin AS ''RDS'' REQUIRE SSL;\nREVOKE ALL PRIVILEGES, GRANT OPTION FROM ''gochuchamchi_web_iam''@''%%'';\nREVOKE ALL PRIVILEGES, GRANT OPTION FROM ''gochuchamchi_admin_iam''@''%%'';\nGRANT SELECT ON gochuchamchi.web_users TO ''gochuchamchi_web_iam''@''%%'';\nGRANT INSERT (username,name,email,password,phone,birthdate,gender,nationality,address,role,created_at) ON gochuchamchi.web_users TO ''gochuchamchi_web_iam''@''%%'';\nGRANT UPDATE (name,email,password,phone,birthdate,gender,nationality,address) ON gochuchamchi.web_users TO ''gochuchamchi_web_iam''@''%%'';\nGRANT SELECT ON gochuchamchi.products TO ''gochuchamchi_web_iam''@''%%'';\nGRANT INSERT (seller_id,brand,name,category,price,stock,image,description,new_item,created_at) ON gochuchamchi.products TO ''gochuchamchi_web_iam''@''%%'';\nGRANT UPDATE (view_count) ON gochuchamchi.products TO ''gochuchamchi_web_iam''@''%%'';\nGRANT SELECT ON gochuchamchi.product_sizes TO ''gochuchamchi_web_iam''@''%%'';\nGRANT INSERT (product_id,size_name,stock,sort_order,sold_out) ON gochuchamchi.product_sizes TO ''gochuchamchi_web_iam''@''%%'';\nGRANT SELECT ON gochuchamchi.notices TO ''gochuchamchi_web_iam''@''%%'';\nGRANT UPDATE (views) ON gochuchamchi.notices TO ''gochuchamchi_web_iam''@''%%'';\nGRANT INSERT ON gochuchamchi.audit_logs TO ''gochuchamchi_web_iam''@''%%'';\nGRANT INSERT ON gochuchamchi.user_behavior_logs TO ''gochuchamchi_web_iam''@''%%'';\nGRANT SELECT ON gochuchamchi.users TO ''gochuchamchi_admin_iam''@''%%'';\nGRANT UPDATE (role,suspended_until,suspended_permanent,suspended_at,suspended_by) ON gochuchamchi.users TO ''gochuchamchi_admin_iam''@''%%'';\nGRANT SELECT, INSERT, UPDATE, DELETE ON gochuchamchi.notices TO ''gochuchamchi_admin_iam''@''%%'';\nGRANT SELECT ON gochuchamchi.products TO ''gochuchamchi_admin_iam''@''%%'';\nGRANT UPDATE (active) ON gochuchamchi.products TO ''gochuchamchi_admin_iam''@''%%'';\nGRANT SELECT ON gochuchamchi.product_sizes TO ''gochuchamchi_admin_iam''@''%%'';\nGRANT INSERT ON gochuchamchi.audit_logs TO ''gochuchamchi_admin_iam''@''%%'';\n${local.legacy_app_db_compat_sql}FLUSH PRIVILEGES;\n" > /home/ec2-user/app-iam-user.sql',
        'printf "GRANT INSERT (seller_id,brand,name,category,price,stock,image,description,new_item,created_at) ON gochuchamchi.products TO ''gochuchamchi_admin_iam''@''%%'';\nGRANT INSERT (product_id,size_name,stock,sort_order,sold_out) ON gochuchamchi.product_sizes TO ''gochuchamchi_admin_iam''@''%%'';\n" >> /home/ec2-user/app-iam-user.sql',
        'MYSQL_PWD="$DB_PASS" mysql --ssl -h ${data.aws_db_instance.this.address} -u admin < /home/ec2-user/app-iam-user.sql',
        # 검증: 실제로 토큰을 발급받아 붙는지 + 권한이 DML 뿐인지 + TLS 로 붙었는지.
        # 토큰도 비밀값이므로 env 로만 넘긴다(argv 는 ps 에 노출된다).
        'TOKEN=$(aws rds generate-db-auth-token --hostname ${data.aws_db_instance.this.address} --port 3306 --username gochuchamchi_web_iam --region ${var.region})',
        'MYSQL_PWD="$TOKEN" mysql --ssl -h ${data.aws_db_instance.this.address} -u gochuchamchi_web_iam -e "SELECT CURRENT_USER() AS whoami; SHOW GRANTS FOR CURRENT_USER; SELECT COUNT(*) AS visible_admins FROM gochuchamchi.web_users WHERE role IN (''admin'',''superadmin''); SHOW STATUS LIKE ''Ssl_cipher'';"',
        'TOKEN=$(aws rds generate-db-auth-token --hostname ${data.aws_db_instance.this.address} --port 3306 --username gochuchamchi_admin_iam --region ${var.region})',
        'MYSQL_PWD="$TOKEN" mysql --ssl -h ${data.aws_db_instance.this.address} -u gochuchamchi_admin_iam -e "SELECT CURRENT_USER() AS whoami; SHOW GRANTS FOR CURRENT_USER; SHOW STATUS LIKE ''Ssl_cipher'';"',
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
