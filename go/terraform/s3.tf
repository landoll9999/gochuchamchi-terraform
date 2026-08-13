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

# (v8 병합) 계정 수준 S3 퍼블릭 차단은 account-baseline/account-hardening.tf 로 이동.
# 계정 싱글턴이라 일일 destroy 계층에 두면 매일 껐다 켜는 사이클이 됨.
# 이 버킷의 새 정책(cloudfront_read)은 퍼블릭 정책이 아니므로 계정 차단과 충돌하지 않는다.

resource "aws_s3_bucket_ownership_controls" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# (2026-08-03 full-HA에서 복원) 도쿄 CRR(dr.tf)의 전제 조건 — 복제는 원본/대상
# 모두 버전관리가 필수. 버전이 쌓이는 비용은 아래 라이프사이클로 통제한다.
resource "aws_s3_bucket_versioning" "images" {
  bucket = aws_s3_bucket.images.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 기본 SSE-S3에도 의존하지 않고, 이미지 객체의 저장 시 암호화를 IaC로 명시한다.
resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  bucket = aws_s3_bucket.images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
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

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  depends_on = [aws_s3_bucket_policy.images_cloudfront_read]
}

resource "aws_cloudfront_origin_access_control" "images" {
  name                              = "gochuchamchi-images-oac"
  description                       = "Signed CloudFront access to the private product image bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_response_headers_policy" "images_security" {
  name    = "gochuchamchi-images-security"
  comment = "Prevent content-type sniffing for user-uploaded product images"

  security_headers_config {
    content_type_options {
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "images" {
  enabled         = true
  is_ipv6_enabled = true
  comment         = "Private S3 product images via CloudFront OAC"
  price_class     = "PriceClass_200"

  origin {
    domain_name              = aws_s3_bucket.images.bucket_regional_domain_name
    origin_id                = "gochuchamchi-images-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.images.id
  }

  default_cache_behavior {
    target_origin_id       = "gochuchamchi-images-s3"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.images_security.id
    compress                   = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Project   = "gochuchamchi"
    Component = "private-image-delivery"
  }
}

resource "aws_s3_bucket_policy" "images_cloudfront_read" {
  bucket = aws_s3_bucket.images.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontReadOnly"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.images.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.images.arn
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.images.arn,
          "${aws_s3_bucket.images.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })
}

moved {
  from = aws_s3_bucket_policy.images_public_read
  to   = aws_s3_bucket_policy.images_cloudfront_read
}

output "images_cloudfront_domain_name" {
  description = "CloudFront domain used to serve objects from the private image bucket"
  value       = aws_cloudfront_distribution.images.domain_name
}
