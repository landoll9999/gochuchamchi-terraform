# ============================================================
# Lambda 소스 코드 ZIP 생성
# ============================================================

data "archive_file" "cloudwatch_discord" {
  type        = "zip"
  source_file = "${path.module}/lambda_function.py"
  output_path = "${path.module}/cloudwatch-discord.zip"
}


# ============================================================
# Lambda 실행 역할 신뢰 정책
# ============================================================

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole"
    ]
  }
}


# ============================================================
# Lambda 실행 역할
# ============================================================

resource "aws_iam_role" "cloudwatch_discord" {
  name = "gochuchamchi-cloudwatch-discord-lambda"

  assume_role_policy = (
    data.aws_iam_policy_document.lambda_assume_role.json
  )

  tags = {
    Name = "gochuchamchi-cloudwatch-discord-lambda"
  }
}


# ============================================================
# Lambda 기본 로그 기록 권한
# ============================================================

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role = aws_iam_role.cloudwatch_discord.name

  policy_arn = (
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  )
}


# ============================================================
# Secrets Manager Discord Webhook 읽기 권한
# ============================================================

data "aws_iam_policy_document" "read_discord_secret" {
  statement {
    sid    = "ReadDiscordWebhookSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue"
    ]

    resources = [
      data.aws_secretsmanager_secret.discord_webhook.arn
    ]
  }
}

resource "aws_iam_role_policy" "read_discord_secret" {
  name = "gochuchamchi-read-discord-webhook"
  role = aws_iam_role.cloudwatch_discord.id

  policy = data.aws_iam_policy_document.read_discord_secret.json
}


# ============================================================
# CloudWatch Alarm Discord 전송 Lambda
# ============================================================

resource "aws_lambda_function" "cloudwatch_discord" {
  function_name = "gochuchamchi-cloudwatch-discord"

  role    = aws_iam_role.cloudwatch_discord.arn
  handler = "lambda_function.lambda_handler"
  runtime = "python3.12"

  filename = data.archive_file.cloudwatch_discord.output_path

  source_code_hash = (
    data.archive_file.cloudwatch_discord.output_base64sha256
  )

  timeout     = 15
  memory_size = 128

  environment {
    variables = {
      DISCORD_SECRET_ARN = (
        data.aws_secretsmanager_secret.discord_webhook.arn
      )
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_iam_role_policy.read_discord_secret
  ]

  tags = {
    Name = "gochuchamchi-cloudwatch-discord"
  }
}