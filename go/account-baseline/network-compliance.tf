# =============================================================================
# 네트워크 위험 상태 지속 검사
#
# CloudTrail/EventBridge는 "누가 설정을 바꿨는가"를 기록하고 알린다. 이 규칙들은
# 변경 주체와 무관하게 "지금도 위험한 상태인가"를 AWS Config가 계속 평가한다.
# 자동 복구는 의도적으로 두지 않는다. 미복구 상태의 1시간 재알림은
# ../cloudwatch-notifications/config-compliance-reminder.tf가 담당한다.
# =============================================================================

locals {
  network_config_rule_names = {
    restricted_ports = "gochuchamchi-network-restricted-ports"
    rds_private      = "gochuchamchi-rds-private-only"
    flow_logs        = "gochuchamchi-vpc-flow-logs-enabled"
    default_sg       = "gochuchamchi-default-sg-closed"
  }
}

# 인터넷 전체(0.0.0.0/0, ::/0)에 관리·데이터·클러스터 포트를 열면 비준수.
# 80/443은 의도적인 공개 포트라 목록에서 제외한다.
resource "aws_config_config_rule" "network_restricted_ports" {
  name        = local.network_config_rule_names.restricted_ports
  description = "Flags security groups that expose sensitive management, database, cache, or cluster ports to the internet."

  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }

  input_parameters = jsonencode({
    blockedPorts = "22,2375,27017,3306,3389,6379,6443,8080,9200"
  })

  maximum_execution_frequency = "One_Hour"

  depends_on = [module.aws_config]

  tags = merge(local.cloudwatch_log_archive_tags, {
    Name      = local.network_config_rule_names.restricted_ports
    Component = "network-compliance"
  })
}

# DB subnet/SG가 안전해도 publiclyAccessible=true 자체가 켜지면 비준수.
resource "aws_config_config_rule" "rds_private_only" {
  name        = local.network_config_rule_names.rds_private
  description = "Requires RDS instances to remain private."

  source {
    owner             = "AWS"
    source_identifier = "RDS_INSTANCE_PUBLIC_ACCESS_CHECK"
  }

  depends_on = [module.aws_config]

  tags = merge(local.cloudwatch_log_archive_tags, {
    Name      = local.network_config_rule_names.rds_private
    Component = "network-compliance"
  })
}

# Flow Logs가 지워진 채 방치되면 네트워크 조사 증거가 끊기므로 비준수.
resource "aws_config_config_rule" "vpc_flow_logs_enabled" {
  name        = local.network_config_rule_names.flow_logs
  description = "Requires VPC Flow Logs to remain enabled for all traffic."

  source {
    owner             = "AWS"
    source_identifier = "VPC_FLOW_LOGS_ENABLED"
  }

  input_parameters = jsonencode({
    trafficType = "ALL"
  })

  maximum_execution_frequency = "One_Hour"

  depends_on = [module.aws_config]

  tags = merge(local.cloudwatch_log_archive_tags, {
    Name      = local.network_config_rule_names.flow_logs
    Component = "network-compliance"
  })
}

# 기본 SG는 실수로 리소스에 연결되기 쉬우므로 인바운드·아웃바운드 모두 비워 둔다.
resource "aws_config_config_rule" "default_security_group_closed" {
  name        = local.network_config_rule_names.default_sg
  description = "Requires the default VPC security group to have no rules."

  source {
    owner             = "AWS"
    source_identifier = "VPC_DEFAULT_SECURITY_GROUP_CLOSED"
  }

  depends_on = [module.aws_config]

  tags = merge(local.cloudwatch_log_archive_tags, {
    Name      = local.network_config_rule_names.default_sg
    Component = "network-compliance"
  })
}

output "network_config_rule_names" {
  description = "AWS Config rules monitored by the hourly network compliance reminder."
  value       = values(local.network_config_rule_names)
}
