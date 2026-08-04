# =============================================================================
# CloudFront + global AWS WAF + edge access logs
#
# Rollout is intentionally two-phase:
#   1. Apply with cdn_enforce_origin_header=false, then verify apex/www through
#      CloudFront.
#   2. Set cdn_enforce_origin_header=true and apply again to block direct ALB
#      access to the application rules.
# =============================================================================

locals {
  cdn_domains = [var.domain_name, "www.${var.domain_name}"]

  edge_tags = {
    Project     = "gochuchamchi"
    Environment = "project"
    ManagedBy   = "Terraform"
    Component   = "edge-security"
  }
}

# The existing ALB is created asynchronously by the AWS Load Balancer
# Controller. The tag-discovery locals live in cloudwatch-managed-metrics.tf.
# If the ALB does not exist yet, the distribution and DNS records are skipped;
# run apply once more after the Ingress has produced the ALB.
data "aws_lb" "cdn_origin" {
  count = local.gochuchamchi_alb_arn == null ? 0 : 1

  arn = local.gochuchamchi_alb_arn
}

# -----------------------------------------------------------------------------
# CloudFront viewer certificate (CloudFront requires ACM in us-east-1)
# -----------------------------------------------------------------------------

resource "aws_acm_certificate" "cdn" {
  provider = aws.us_east_1

  domain_name               = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.edge_tags, { Name = "gochuchamchi-cloudfront" })
}

# ACM DNS validation tokens are account/domain-specific and reusable across
# Regions, so the Route53 CNAMEs already managed in dns.tf validate this cert.
resource "aws_acm_certificate_validation" "cdn" {
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.cdn.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

# -----------------------------------------------------------------------------
# Global WAF (CLOUDFRONT scope)
# -----------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "cdn" {
  provider = aws.us_east_1

  name        = "gochuchamchi-cloudfront"
  description = "Managed protection for the gochuchamchi CloudFront distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common-rule-set"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # Product-image uploads can legitimately exceed the managed rule's
        # small body-size threshold. Keep visibility without blocking them.
        rule_action_override {
          name = "SizeRestrictions_BODY"

          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-ip-reputation"
    priority = 30

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-sqli-rule-set"
    priority = 40

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-sqli-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "per-ip-rate-limit"
    priority = 50

    action {
      block {}
    }

    statement {
      rate_based_statement {
        aggregate_key_type = "IP"
        limit              = var.waf_rate_limit
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "gochuchamchi-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "gochuchamchi-cloudfront"
    sampled_requests_enabled   = true
  }

  tags = local.edge_tags
}

resource "aws_cloudwatch_log_group" "waf" {
  provider = aws.us_east_1

  name              = "aws-waf-logs-gochuchamchi-cloudfront"
  retention_in_days = var.waf_log_retention_days

  tags = merge(local.edge_tags, { Component = "waf-logs" })
}

resource "aws_wafv2_web_acl_logging_configuration" "cdn" {
  provider = aws.us_east_1

  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
  resource_arn            = aws_wafv2_web_acl.cdn.arn

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

# -----------------------------------------------------------------------------
# CloudFront distribution
# -----------------------------------------------------------------------------

resource "random_password" "cdn_origin_header" {
  length  = 40
  special = false
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  provider = aws.us_east_1
  name     = "Managed-CachingDisabled"
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  provider = aws.us_east_1
  name     = "Managed-CachingOptimized"
}

data "aws_cloudfront_origin_request_policy" "all_viewer" {
  provider = aws.us_east_1
  name     = "Managed-AllViewer"
}

resource "aws_cloudfront_origin_request_policy" "static" {
  provider = aws.us_east_1

  name    = "gochuchamchi-static-origin-request"
  comment = "Forward only the viewer Host header for static content"

  cookies_config {
    cookie_behavior = "none"
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Host"]
    }
  }

  query_strings_config {
    query_string_behavior = "none"
  }
}

resource "aws_cloudfront_distribution" "web" {
  provider = aws.us_east_1
  count    = local.gochuchamchi_alb_arn == null ? 0 : 1

  aliases         = local.cdn_domains
  comment         = "gochuchamchi application CDN"
  enabled         = true
  http_version    = "http2and3"
  is_ipv6_enabled = true
  price_class     = var.cdn_price_class
  web_acl_id      = aws_wafv2_web_acl.cdn.arn

  origin {
    domain_name = data.aws_lb.cdn_origin[0].dns_name
    origin_id   = "gochuchamchi-alb"

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.cdn_origin_header.result
    }

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_keepalive_timeout = 5
      origin_protocol_policy   = "https-only"
      origin_read_timeout      = 30
      origin_ssl_protocols     = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods          = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    cached_methods           = ["GET", "HEAD", "OPTIONS"]
    compress                 = true
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    target_origin_id         = "gochuchamchi-alb"
    viewer_protocol_policy   = "redirect-to-https"
  }

  ordered_cache_behavior {
    path_pattern             = "/assets/*"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    cached_methods           = ["GET", "HEAD", "OPTIONS"]
    compress                 = true
    origin_request_policy_id = aws_cloudfront_origin_request_policy.static.id
    target_origin_id         = "gochuchamchi-alb"
    viewer_protocol_policy   = "redirect-to-https"
  }

  ordered_cache_behavior {
    path_pattern             = "/static/*"
    allowed_methods          = ["GET", "HEAD", "OPTIONS"]
    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_optimized.id
    cached_methods           = ["GET", "HEAD", "OPTIONS"]
    compress                 = true
    origin_request_policy_id = aws_cloudfront_origin_request_policy.static.id
    target_origin_id         = "gochuchamchi-alb"
    viewer_protocol_policy   = "redirect-to-https"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cdn.certificate_arn
    minimum_protocol_version = "TLSv1.2_2021"
    ssl_support_method       = "sni-only"
  }

  tags = merge(local.edge_tags, { Name = "gochuchamchi-web" })
}

# ExternalDNS ignores the application Ingress after the annotation change in
# k8s-deploy.tf. These records then become the single source of truth.
resource "aws_route53_record" "cdn_a" {
  for_each = local.gochuchamchi_alb_arn == null ? toset([]) : toset(local.cdn_domains)

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value
  type            = "A"

  alias {
    evaluate_target_health = false
    name                   = aws_cloudfront_distribution.web[0].domain_name
    zone_id                = aws_cloudfront_distribution.web[0].hosted_zone_id
  }
}

resource "aws_route53_record" "cdn_aaaa" {
  for_each = local.gochuchamchi_alb_arn == null ? toset([]) : toset(local.cdn_domains)

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.this.zone_id
  name            = each.value
  type            = "AAAA"

  alias {
    evaluate_target_health = false
    name                   = aws_cloudfront_distribution.web[0].domain_name
    zone_id                = aws_cloudfront_distribution.web[0].hosted_zone_id
  }
}

# -----------------------------------------------------------------------------
# CloudFront standard access logging v2 -> encrypted private S3
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "cloudfront_logs" {
  bucket        = "gochuchamchi-cloudfront-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = merge(local.edge_tags, {
    Name      = "gochuchamchi-cloudfront-logs"
    Component = "cloudfront-logs"
  })
}

resource "aws_s3_bucket_ownership_controls" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id

  rule {
    id     = "archive-cloudfront-access-logs"
    status = "Enabled"

    filter {
      prefix = ""
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = var.cdn_log_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

data "aws_iam_policy_document" "cloudfront_logs" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.cloudfront_logs.arn,
      "${aws_s3_bucket.cloudfront_logs.arn}/*"
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryAclCheck"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:GetBucketAcl", "s3:ListBucket"]
    resources = [aws_s3_bucket.cloudfront_logs.arn]

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:*"]
    }
  }

  statement {
    sid    = "AWSLogDeliveryWrite"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudfront_logs.arn}/*"]

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudfront_logs" {
  bucket = aws_s3_bucket.cloudfront_logs.id
  policy = data.aws_iam_policy_document.cloudfront_logs.json

  depends_on = [
    aws_s3_bucket_ownership_controls.cloudfront_logs,
    aws_s3_bucket_public_access_block.cloudfront_logs
  ]
}

resource "aws_cloudwatch_log_delivery_source" "cloudfront" {
  provider = aws.us_east_1
  count    = local.gochuchamchi_alb_arn == null ? 0 : 1

  name         = "gochuchamchi-cloudfront-access-logs"
  log_type     = "ACCESS_LOGS"
  resource_arn = aws_cloudfront_distribution.web[0].arn
}

resource "aws_cloudwatch_log_delivery_destination" "cloudfront_s3" {
  provider = aws.us_east_1

  name          = "gochuchamchi-cloudfront-s3"
  output_format = "parquet"

  delivery_destination_configuration {
    destination_resource_arn = aws_s3_bucket.cloudfront_logs.arn
  }
}

resource "aws_cloudwatch_log_delivery" "cloudfront_s3" {
  provider = aws.us_east_1
  count    = local.gochuchamchi_alb_arn == null ? 0 : 1

  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.cloudfront_s3.arn

  s3_delivery_configuration {
    enable_hive_compatible_path = true
    suffix_path                 = "/{DistributionId}/{yyyy}/{MM}/{dd}/{HH}"
  }

  depends_on = [aws_s3_bucket_policy.cloudfront_logs]
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID; null until the ALB has been discovered"
  value       = try(aws_cloudfront_distribution.web[0].id, null)
}

output "cloudfront_domain_name" {
  description = "CloudFront distribution hostname; null until the ALB has been discovered"
  value       = try(aws_cloudfront_distribution.web[0].domain_name, null)
}

output "waf_web_acl_arn" {
  description = "Global WAF web ACL ARN"
  value       = aws_wafv2_web_acl.cdn.arn
}

output "waf_log_group_name" {
  description = "CloudWatch Logs group receiving WAF request logs"
  value       = aws_cloudwatch_log_group.waf.name
}

output "cloudfront_log_bucket_name" {
  description = "S3 bucket receiving CloudFront standard access logs"
  value       = aws_s3_bucket.cloudfront_logs.id
}
