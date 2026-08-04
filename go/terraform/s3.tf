# S3 버킷 이름은 AWS 전체에서 유일해야 하는데, 예전 계정이 이미
# "gochuchamchi-images"를 쓰고 있어서 새 계정에서는 그 이름을 못 씁니다.
# 계정 ID를 붙여서 확실히 겹치지 않게 만듭니다.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "images" {
  bucket = "gochuchamchi-images-${data.aws_caller_identity.current.account_id}"

  # 버킷에 객체가 남아있으면 destroy가 BucketNotEmpty로 막힘(실제로 매번 걸렸음).
  # 이 프로젝트는 destroy/apply를 반복하는 구조라 자동 비우기를 켠다.
  # ※ 주의: destroy 시 사용자가 업로드한 상품 이미지까지 전부 삭제됨.
  force_destroy = true
}

# (2026-08-03 full-HA에서 복원) 도쿄 CRR(dr.tf)의 전제 조건 — 복제는 원본/대상
# 모두 버전관리가 필수. 버전이 쌓이는 비용은 아래 라이프사이클로 통제한다.
resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {
      prefix = ""
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.images]
}

# 메인 페이지(index.html)가 배경으로 참조하는 텍스처.
# 버킷은 Terraform이 만들지만 내용물은 관리 대상이 아니라서, 재생성할 때마다
# 수동 업로드를 잊으면 배경이 403으로 깨졌음 -> 코드로 같이 관리한다.
resource "aws_s3_object" "texture" {
  bucket        = aws_s3_bucket.images.id
  key           = "texture.png"
  source        = "${path.module}/../assets/texture.png"
  etag          = filemd5("${path.module}/../assets/texture.png")
  content_type  = "image/png"
  cache_control = "public, max-age=31536000"
}

resource "aws_s3_bucket_public_access_block" "images" {
  bucket = aws_s3_bucket.images.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# public_access_block 설정이 실제로 AWS에 전파되기 전에 bucket_policy가
# 먼저 적용되면 AccessDenied/OperationAborted가 나는 경우가 있어(eventual
# consistency), depends_on만으로는 그래프상 순서만 보장되고 실전파 시간은
# 보장되지 않는다. time_sleep으로 실제 대기 시간을 둬서 단일 apply에서도
# 안정적으로 동작하게 한다.
resource "time_sleep" "wait_for_public_access_block" {
  depends_on      = [aws_s3_bucket_public_access_block.images]
  create_duration = "10s"
}

resource "aws_s3_bucket_policy" "images_public_read" {
  bucket = aws_s3_bucket.images.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadForProductImages"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.images.arn}/*"
      }
    ]
  })
  depends_on = [time_sleep.wait_for_public_access_block]
}
