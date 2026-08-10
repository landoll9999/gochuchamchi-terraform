# 기존 gochuchamchi RDS와 동일한 방식(Secrets Manager 자동 비밀번호 관리)으로
# 이번 EKS용 VPC 안에 새 RDS를 생성합니다.
# 이미 database_subnets 를 만들어둔 module "vpc" 를 그대로 재사용합니다.

module "rds_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 6.0"

  name        = "gochuchamchi-rds-sg"
  description = "RDS accessible only from EKS nodes and bastion"
  vpc_id      = module.vpc.vpc_id

  # CIDR 허용은 '네트워크 위치'를 신뢰하지만, referenced_security_group_id는
  # '워크로드 정체성'을 신뢰함 -> NAT/같은 VPC의 다른 자원이 침해돼도 DB 접근 불가
  ingress_rules = {
    mariadb_from_nodes = {
      from_port                    = 3306
      to_port                      = 3306
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.eks.node_security_group_id
      description                  = "MariaDB from EKS nodes only"
    }
    mariadb_from_bastion = {
      from_port                    = 3306
      to_port                      = 3306
      ip_protocol                  = "tcp"
      referenced_security_group_id = module.bastion_host_sg.id
      description                  = "Schema init from bastion"
    }
  }
  # (2026-08-04 제로트러스트) egress 전면 제거 — DB는 아웃바운드 커넥션을 "시작"할
  # 일이 없다. 클라이언트 요청에 대한 응답은 SG가 stateful이라 egress 규칙 없이도
  # 자동 허용됨. 만약 DB가 밖으로 나가려 한다면 그 자체가 침해 신호다.
  # (Multi-AZ 복제/managed rotation은 AWS 내부 경로라 고객 SG를 타지 않음)
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "gochuchamchi-db"

  engine               = "mariadb"
  engine_version       = "10.11"
  family               = "mariadb10.11"
  major_engine_version = "10.11"
  instance_class       = "db.t3.micro"

  allocated_storage     = 20
  max_allocated_storage = 100

  db_name  = "gochuchamchi"
  username = "admin"
  port     = 3306

  # ---------------------------------------------------------------------------
  # (2026-08-04 제로트러스트) 전송 암호화 강제
  #   require_secure_transport=1 이면 평문 접속은 TLS 핸드셰이크 단계에서 거부됨.
  #   "같은 VPC 안이니까 평문이어도 괜찮다"는 네트워크 위치 신뢰를 버리는 것.
  #   - 동적 파라미터라 원칙상 재부팅 불필요. 단, 이미 떠 있는 인스턴스에 적용할 땐
  #     DBParameterGroups[0].ParameterApplyStatus 가 in-sync인지 확인하고,
  #     pending-reboot로 남으면 reboot-db-instance 1회 (약 1~2분).
  #   - 접속하는 쪽도 전부 TLS로 맞춰둠: 앱은 SPRING_DATASOURCE_URL의 sslMode
  #     (k8s-deploy.tf), 배스천 스크립트는 [client] ssl (rds-schema-init.tf,
  #     db-zero-trust.tf), 앱 계정은 REQUIRE SSL로 이중 강제.
  #   * IAM DB 인증(iam_database_authentication_enabled)은 MariaDB 미지원이라 제외.
  #     MySQL/PostgreSQL이었다면 비밀번호 대신 15분짜리 IAM 토큰 인증까지 가능했음
  #     — "왜 안 켰나"를 물어보면 엔진 제약이라고 답하면 되는 면접 포인트.
  # ---------------------------------------------------------------------------
  parameters = [
    {
      name         = "require_secure_transport"
      value        = "1"
      apply_method = "immediate"
    }
  ]

  # ---------------------------------------------------------------------------
  # (2026-08-04 제로트러스트) 접속/변경 감사 로그 — "모든 접근을 기록"하는 축.
  #   MARIADB_AUDIT_PLUGIN: 누가/어느 IP에서 접속(실패 포함)했고 어떤 DDL/DCL을
  #   실행했는지 남김. QUERY 전체(모든 SELECT/DML)까지 켜면 로그량·비용이 커져서
  #   접속 이벤트 + 스키마/권한 변경만 기록 (운영 전환 시 QUERY_DML 추가 검토).
  #   rdsadmin(AWS 내부 헬스체크 계정)은 노이즈라 제외.
  # ---------------------------------------------------------------------------
  options = [
    {
      option_name = "MARIADB_AUDIT_PLUGIN"
      option_settings = [
        {
          name  = "SERVER_AUDIT_EVENTS"
          value = "CONNECT,QUERY_DDL,QUERY_DCL"
        },
        {
          name  = "SERVER_AUDIT_EXCL_USERS"
          value = "rdsadmin"
        },
      ]
    }
  ]

  # Grafana의 aws-errors-overview 대시보드가 /aws/rds/instance/<id>/error 로그 그룹을
  # 조회하므로 error 로그 export가 켜져 있어야 함 (module/grafana/aws_errors_dashboard.tf)
  # audit: 위 MARIADB_AUDIT_PLUGIN 로그를 CloudWatch로 내보냄
  # (/aws/rds/instance/gochuchamchi-db/audit — GuardDuty/Athena 연계·무단접속 추적용)
  enabled_cloudwatch_logs_exports = [
    "audit",
    "error"
  ]

  # 기존과 동일하게 비밀번호를 직접 넣지 않고 Secrets Manager가 자동 생성/관리하도록 함
  manage_master_user_password = true

  vpc_security_group_ids = [module.rds_sg.id]

  create_db_subnet_group = true
  subnet_ids             = module.vpc.database_subnets

  multi_az            = false # 학습/포트폴리오용이라 우선 단일 AZ. 운영 전환 시 true로 변경
  publicly_accessible = false

  # 모듈 기본값(true)이지만 보안 리뷰 때 바로 보이도록 명시 (EBS 저장 데이터 KMS 암호화).
  # 주의: 이미 떠 있는 인스턴스에서 plan에 이 항목이 "변경"으로 뜬다면 실제로는 암호화가
  # 꺼져 있던 것 -> 그대로 apply하면 재생성(데이터 삭제)이므로 중단하고 스냅샷 경유로 전환할 것.
  storage_encrypted = true
  # (2026-08-07) 관리형 키(aws/rds) → 우리 CMK로 전환. kms.tf 주석은 "RDS/EFS 전용
  # 키"라 했지만 실제로는 지정이 없어 관리형 키를 쓰고 있었다 — 코드와 문서의 불일치
  # 해소. CMK는 키 정책·CloudTrail 사용 추적·교체 주기를 우리가 통제한다는 차이.
  # 키 변경은 인스턴스 교체를 유발하므로 전체 재구축 시점(지금)에만 적용할 것.
  kms_key_id = data.aws_kms_key.data.arn

  backup_retention_period = 1

  # (v8) 변수화. default = true — "하지 않은 것의 이유":
  #   매일 destroy하는 이 체제에서 false면 최종 스냅샷이 매일 1개씩 쌓인다
  #   (20GB 기준 개당 월 $0.4, 30일이면 ~$12/월). DB 데이터는 rds-schema-init.tf가
  #   복원하는 재현 가능한 시드라, 스냅샷 누적 비용이 데이터 가치보다 크다.
  #   운영 전환 시에만 -var rds_skip_final_snapshot=false + 스냅샷 수명 관리 추가.
  skip_final_snapshot = var.rds_skip_final_snapshot
  # prefix 방식(모듈이 유니크 suffix를 붙임) — timestamp() 기반 이름은 매 plan마다
  # 값이 바뀌어 상시 diff를 만들므로 쓰지 않는다 (8/7 결정 그대로).
  final_snapshot_identifier_prefix = "gochuchamchi-final"
  deletion_protection              = false
}

output "rds_secret_arn" {
  value       = module.rds.db_instance_master_user_secret_arn
  description = "마스터(admin) 자격증명 Secret — 배스천의 스키마 초기화/운영 작업 전용. 앱은 이제 이 시크릿에 접근 권한이 없음 (앱 전용 계정은 db-zero-trust.tf)"
}
