# =============================================================================
# SSM Session Manager 세션 전사 로깅
#
# 이 환경에는 SSH 경로가 없다 — 노드·NAT·배스천 어디에도 키페어가 붙어 있지 않고
# 접속은 SSM Session Manager 하나뿐이다. 따라서 이 두 리소스가 **유일한 접속 감사
# 증적**이다. 문서(SSM-SessionManagerRunShell)가 전사 스트리밍을 켜고, 로그 그룹이
# 그 내용을 받는다.
#
# 왜 이 파일이 2026-08-12 에 생겼나:
#   두 리소스가 account-baseline state 와 실제 AWS 에는 있는데 어느 스택의 코드에도
#   선언이 없는 상태였다(전 스택 grep 0건, git 이력에도 0건). 그래서 이 스택을
#   apply 하는 순간 "not in configuration" 사유로 둘 다 삭제될 상황이었다.
#   OAM Link 도 같은 스택이라, 그걸 적용하려다 세션 로깅을 지울 뻔했다.
#   실물 설정을 그대로 코드로 옮겨 다시 IaC 관리 아래로 되돌린다.
#
#   terraform state rm 으로 state 에서만 떼어내는 선택지도 있었지만 쓰지 않았다.
#   실물은 살아남아도 관리 대상 밖으로 밀려나 같은 사고가 반복된다.
#
# 값은 추측하지 않고 terraform state show 로 읽은 실물을 그대로 옮겼다.
# 따라서 이 파일 추가 후 plan 은 두 리소스에 대해 no change 여야 한다.
# =============================================================================

resource "aws_cloudwatch_log_group" "ssm_sessions" {
  name              = "/gochuchamchi/ssm-sessions"
  retention_in_days = 90

  tags = {
    Project   = "gochuchamchi"
    ManagedBy = "Terraform"
    Component = "ssm-session-audit"
  }
}

# 이름이 SSM-SessionManagerRunShell 로 고정인 이유: Session Manager 는 세션을 열 때
# 계정·리전 단위로 이 이름의 문서를 찾는다. 다른 이름으로 만들면 설정이 적용되지 않고
# 조용히 기본값(전사 로깅 없음)으로 돌아간다.
resource "aws_ssm_document" "session_manager_prefs" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager 전역 설정 — 세션 전사를 CloudWatch Logs로 스트리밍"
    sessionType   = "Standard_Stream"
    inputs = {
      # 전사 스트리밍. 이 값이 false 가 되면 접속 감사 증적이 사라진다.
      cloudWatchStreamingEnabled  = true
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.ssm_sessions.name
      cloudWatchEncryptionEnabled = false

      # 방치된 세션을 20분에 끊는다. 열어 둔 셸이 그대로 남는 것을 막는다.
      idleSessionTimeout = "20"
      maxSessionDuration = ""

      # 루트로 붙는 것을 막지 않는 대신, 무엇을 했는지는 전부 남긴다.
      runAsEnabled     = false
      runAsDefaultUser = ""

      kmsKeyId            = ""
      s3BucketName        = ""
      s3KeyPrefix         = ""
      s3EncryptionEnabled = true

      shellProfile = {
        linux   = ""
        windows = ""
      }
    }
  })
}
