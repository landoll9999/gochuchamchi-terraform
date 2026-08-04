# =============================================================================
# RDS 생성 후 schema.sql 자동 적용
# =============================================================================

resource "null_resource" "apply_db_schema" {
  triggers = {
    schema_hash = filemd5("${path.module}/../k8s/gochuchamchi/schema.sql")
    rds_id      = data.aws_db_instance.this.db_instance_identifier
  }

  depends_on = [
    module.rds,
    module.bastion_host,
    aws_s3_object.schema_sql,
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-Command"]
    command     = <<-EOT
      # 배스천 SSM 온라인 대기
      $maxRetries = 20; $retry = 0; $isOnline = $false
      while ($retry -lt $maxRetries -and -not $isOnline) {
        $status = aws ssm describe-instance-information --filters "Key=InstanceIds,Values=${module.bastion_host.id}" --region ${var.region} --profile ${var.aws_profile} --query "InstanceInformationList[0].PingStatus" --output text
        if ($status -eq "Online") { $isOnline = $true; Write-Host "배스천 SSM 온라인 확인됨" }
        else { Write-Host "SSM 대기 중... ($retry/$maxRetries)"; Start-Sleep -Seconds 15; $retry++ }
      }
      if (-not $isOnline) { Write-Error "배스천이 SSM 온라인 상태가 아닙니다."; exit 1 }

      # depends_on은 리소스 "생성 순서"만 보장할 뿐, RDS가 "접속 가능"해질 때까지
      # 기다려주지 않는다. 2026-08-03: 스키마 적용이 RDS 생성 완료보다 5분 먼저 실행돼
      # 통째로 실패했는데, 아래 상태 검사가 없어서 terraform은 성공으로 기록했다.
      # 그 뒤로는 filemd5 트리거가 그대로라 apply를 다시 돌려도 재시도되지 않아
      # "테이블이 없는 DB"가 계속 남았다(회원가입 500).
      $maxRetries = 40; $retry = 0; $isAvailable = $false
      while ($retry -lt $maxRetries -and -not $isAvailable) {
        $dbStatus = aws rds describe-db-instances --db-instance-identifier ${data.aws_db_instance.this.db_instance_identifier} --region ${var.region} --profile ${var.aws_profile} --query "DBInstances[0].DBInstanceStatus" --output text
        if ($dbStatus -eq "available") { $isAvailable = $true; Write-Host "RDS available 확인됨" }
        else { Write-Host "RDS 대기 중... ($dbStatus, $retry/$maxRetries)"; Start-Sleep -Seconds 15; $retry++ }
      }
      if (-not $isAvailable) { Write-Error "RDS가 available 상태가 아닙니다."; exit 1 }

      # mysql -p"$DB_PASS" 형태로 넘기면 ps 목록/SSM 커맨드 로그에 비밀번호가 그대로 남는다.
      # MYSQL_PWD(env 접두)로 인증 — ps에도 SSM 로그에도 안 남는다.
      # (구 방식이던 .my.cnf는 비밀번호에 '#'이 섞이면 옵션 파일 파서가 주석으로 잘라
      #  조용히 실패하는 함정이 있어 폐기 — runbook §1.4. RDS 관리형 비밀번호는 '#' 포함 가능)
      $cmds = @(
        "which mysql || sudo dnf install -y mariadb105",
        "aws s3 cp s3://${aws_s3_bucket.k8s_manifests.id}/db/schema.sql /home/ec2-user/schema.sql --region ${var.region}",
        'SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id ''${module.rds.db_instance_master_user_secret_arn}'' --region ${var.region} --query SecretString --output text)',
        'DB_PASS=$(echo "$SECRET_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin)[''password''])")',
        # --ssl: require_secure_transport=1(rds.tf) 적용 후에도 접속이 거부되지 않도록
        # 명시 — mariadb 클라이언트는 기본이 평문 시도라 명시하지 않으면 차단됨.
        # `mysql ...; rm ...` 로 두면 그 줄의 종료코드가 rm(항상 0)의 것이 되어
        # mysql이 실패해도 SSM은 Success로 끝난다. 종료코드를 보존해서 내보낸다.
        'MYSQL_PWD="$DB_PASS" mysql --ssl -h ${data.aws_db_instance.this.address} -u admin < /home/ec2-user/schema.sql; rc=$?; rm -f /home/ec2-user/schema.sql; exit $rc'
      )

      $json = @{ commands = $cmds } | ConvertTo-Json -Depth 5
      $json | Out-File -Encoding ascii -NoNewline apply-schema-params.json

      $cmdId = aws ssm send-command --instance-ids ${module.bastion_host.id} --document-name "AWS-RunShellScript" --parameters file://apply-schema-params.json --region ${var.region} --profile ${var.aws_profile} --query "Command.CommandId" --output text

      # 고정 Sleep 후 결과를 "출력만" 하면 SSM이 실패해도 local-exec은 exit 0으로 끝나고
      # terraform이 성공으로 기록해버린다. 완료까지 폴링하고 Status를 반드시 검사할 것.
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
        Write-Error "스키마 적용 실패 (Status=$cmdStatus). 재시도하려면: terraform taint null_resource.apply_db_schema"
        exit 1
      }
      Write-Host "스키마 적용 완료"
    EOT
  }
}
