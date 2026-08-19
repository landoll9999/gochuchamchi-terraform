# =============================================================================
# Security Hub CSPM
#
# AWS Config가 기록한 리소스 구성을 근거로 보안 표준(Control)을 평가합니다.
# AWS 기본 표준 자동 활성화는 끄고, 활성화할 표준을 코드로 명시해서 관리합니다.
#
# 주의: Security Hub는 module.aws_config가 Recorder를 켠 뒤에 활성화되어야
#       Control 평가가 정상적으로 시작됩니다(아래 depends_on).
# =============================================================================

locals {
  # 이 프로젝트에서 쓰지 않는 서비스의 FSBP Control 목록.
  # 리소스가 없어 상시 판정만 돌며 securityhub-* Config 규칙·ResourceCompliance
  # CI·finding 비용을 만들던 Control들이다. DISABLED로 비용/노이즈를 줄인다.
  #
  # 실사용 확인으로 SQS(DLQ 큐 1개 존재)·Inspector(activation ENABLED)는 제외했다.
  # 재산출: aws securityhub describe-standards-controls 로 ControlId를 뽑아
  #         프로젝트 미사용 서비스 접두사만 필터(2026-08-19 기준 149개).
  unused_fsbp_controls = [
    "APIGateway.1",
    "APIGateway.2",
    "APIGateway.3",
    "APIGateway.4",
    "APIGateway.5",
    "APIGateway.8",
    "APIGateway.9",
    "APIGateway.10",
    "APIGateway.11",
    "AppSync.2",
    "AppSync.5",
    "BedrockAgentCore.1",
    "BedrockAgentCore.2",
    "BedrockAgentCore.5",
    "BedrockAgentCore.6",
    "CloudFormation.3",
    "CloudFormation.4",
    "CodeBuild.1",
    "CodeBuild.2",
    "CodeBuild.3",
    "CodeBuild.4",
    "CodeBuild.7",
    "Cognito.1",
    "Cognito.3",
    "Cognito.4",
    "Cognito.5",
    "Cognito.6",
    "Connect.2",
    "DMS.1",
    "DMS.6",
    "DMS.7",
    "DMS.8",
    "DMS.9",
    "DMS.10",
    "DMS.11",
    "DMS.12",
    "DMS.13",
    "DataSync.1",
    "DocumentDB.1",
    "DocumentDB.2",
    "DocumentDB.3",
    "DocumentDB.4",
    "DocumentDB.5",
    "DocumentDB.6",
    "ECS.2",
    "ECS.3",
    "ECS.4",
    "ECS.5",
    "ECS.8",
    "ECS.9",
    "ECS.10",
    "ECS.12",
    "ECS.16",
    "ECS.18",
    "ECS.19",
    "ECS.20",
    "ECS.21",
    "EMR.1",
    "EMR.2",
    "EMR.3",
    "EMR.4",
    "ES.1",
    "ES.2",
    "ES.3",
    "ES.4",
    "ES.5",
    "ES.6",
    "ES.7",
    "ES.8",
    "ElasticBeanstalk.1",
    "ElasticBeanstalk.2",
    "ElasticBeanstalk.3",
    "FSx.1",
    "FSx.2",
    "FSx.3",
    "FSx.4",
    "FSx.5",
    "Kinesis.1",
    "Kinesis.3",
    "MQ.2",
    "MSK.1",
    "MSK.3",
    "MSK.4",
    "MSK.5",
    "MSK.6",
    "Macie.1",
    "Macie.2",
    "Neptune.1",
    "Neptune.2",
    "Neptune.3",
    "Neptune.4",
    "Neptune.5",
    "Neptune.6",
    "Neptune.7",
    "Neptune.8",
    "NetworkFirewall.2",
    "NetworkFirewall.3",
    "NetworkFirewall.4",
    "NetworkFirewall.5",
    "NetworkFirewall.6",
    "NetworkFirewall.9",
    "NetworkFirewall.10",
    "Opensearch.1",
    "Opensearch.2",
    "Opensearch.3",
    "Opensearch.4",
    "Opensearch.5",
    "Opensearch.6",
    "Opensearch.7",
    "Opensearch.8",
    "Opensearch.10",
    "PCA.1",
    "Redshift.1",
    "Redshift.2",
    "Redshift.3",
    "Redshift.4",
    "Redshift.6",
    "Redshift.7",
    "Redshift.8",
    "Redshift.10",
    "Redshift.15",
    "RedshiftServerless.1",
    "RedshiftServerless.2",
    "RedshiftServerless.3",
    "RedshiftServerless.5",
    "RedshiftServerless.6",
    "SES.3",
    "SageMaker.1",
    "SageMaker.2",
    "SageMaker.3",
    "SageMaker.4",
    "SageMaker.5",
    "SageMaker.8",
    "SageMaker.9",
    "SageMaker.10",
    "SageMaker.11",
    "SageMaker.12",
    "SageMaker.13",
    "SageMaker.14",
    "SageMaker.15",
    "SageMaker.16",
    "SageMaker.17",
    "SageMaker.19",
    "ServiceCatalog.1",
    "StepFunctions.1",
    "Transfer.2",
    "Transfer.3",
    "WorkSpaces.1",
    "WorkSpaces.2",
  ]
}

module "security_hub" {
  source = "./module/security-hub"

  # AWS Foundational Security Best Practices - 기본 활성화
  enable_foundational_security_best_practices = true

  # CIS AWS Foundations Benchmark v3.0.0 - 점검 항목/비용이 늘어나므로 선택
  enable_cis_aws_foundations_benchmark_v3 = var.security_hub_enable_cis_benchmark_v3

  # AWS가 표준에 새 Control을 추가하면 자동으로 켬
  auto_enable_new_controls = true

  # 이 프로젝트에서 쓰지 않는 서비스의 Control을 DISABLED 처리해 비용을 줄인다.
  disabled_control_ids = local.unused_fsbp_controls

  depends_on = [
    module.aws_config
  ]
}


# =============================================================================
# Outputs
# =============================================================================

output "security_hub_arn" {
  description = "현재 리전 Security Hub ARN"
  value       = module.security_hub.security_hub_arn
}

output "security_hub_enabled_standards" {
  description = "활성화한 Security Hub 표준 ARN"
  value       = module.security_hub.enabled_standard_arns
}
