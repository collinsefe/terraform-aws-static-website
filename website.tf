#------------------------------------------------------------------------------
# CloudFront Origin Access Identity
#------------------------------------------------------------------------------

resource "aws_cloudfront_origin_access_identity" "cf_oai" {
  provider = aws.main

  comment = "OAI to restrict access to AWS S3 content"
}


#-------------------------------------------------------------------------
# Website S3 Bucket
#------------------------------------------------------------------------------

resource "aws_kms_key" "mykey" {
  provider                = aws.main
  description             = "This key is used to encrypt bucket objects"
  deletion_window_in_days = 10
  enable_key_rotation     = true
}

resource "aws_s3_bucket" "website" {
  provider      = aws.main
  bucket        = local.website_bucket_name
  force_destroy = var.website_bucket_force_destroy

  tags = merge({
    Name = "${var.name_prefix}-website"
  }, var.tags)
}

locals {
  mime_types = {
    ".html" = "text/html"
    ".css"  = "text/css"
    ".js"   = "application/javascript"
    ".ico"  = "image/vnd.microsoft.icon"
    ".jpeg" = "image/jpeg"
    ".png"  = "image/png"
    ".svg"  = "image/svg+xml"
  }
}

resource "aws_s3_object" "website" {
  provider     = aws.main
  bucket       = aws_s3_bucket.website.id
  for_each     = fileset("..//..//s3_bucket_files/", "*")
  key          = each.value
  source       = "..//..//s3_bucket_files/${each.value}"
  content_type = lookup(local.mime_types, regex("\\.[^.]+$", each.value), null) #https://engineering.statefarm.com/blog/terraform-s3-upload-with-mime/
  source_hash  = filemd5("..//..//s3_bucket_files/${each.value}")
}


resource "aws_s3_bucket_acl" "website" {
  provider = aws.main

  bucket     = aws_s3_bucket.website.id
  acl        = var.website_bucket_acl
  depends_on = [aws_s3_bucket_ownership_controls.s3_bucket_acl_ownership]
}


# Resource to avoid error "AccessControlListNotSupported: The bucket does not allow ACLs"
resource "aws_s3_bucket_ownership_controls" "s3_bucket_acl_ownership" {
  provider = aws.main
  bucket   = aws_s3_bucket.website.id
  rule {
    object_ownership = "ObjectWriter"
  }
}

resource "aws_s3_bucket_versioning" "website" {
  provider = aws.main

  bucket = aws_s3_bucket.website.id
  versioning_configuration {
    status     = var.website_versioning_status
    mfa_delete = var.website_versioning_mfa_delete
  }
}

resource "aws_s3_bucket_logging" "website" {
  provider = aws.main

  bucket        = aws_s3_bucket.website.id
  target_bucket = module.s3_logs_bucket.s3_bucket_id
  target_prefix = "website/"

}




resource "aws_s3_bucket_policy" "website" {
  provider = aws.main

  bucket = aws_s3_bucket.website.id
  policy = templatefile("${path.module}/templates/s3_website_bucket_policy.json", {
    bucket_name = local.website_bucket_name
    cf_oai_arn  = aws_cloudfront_origin_access_identity.cf_oai.iam_arn
  })
}

resource "aws_s3_bucket_public_access_block" "website_bucket_public_access_block" {
  provider = aws.main

  bucket                  = aws_s3_bucket.website.id
  ignore_public_acls      = true
  block_public_acls       = true
  restrict_public_buckets = true
  block_public_policy     = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "website" {
  provider = aws.main
  bucket   = aws_s3_bucket.website.id

  rule {
    apply_server_side_encryption_by_default {

      #kms_master_key_id = aws_kms_key.mykey.arn
      sse_algorithm = "AES256"

    }
  }
}


resource "aws_s3_bucket_server_side_encryption_configuration" "website_bucket_website_server_side_encryption_configuration" {
  provider = aws.main
  count    = length(keys(var.website_server_side_encryption_configuration)) > 0 ? 1 : 0

  bucket = aws_s3_bucket.website.id

  dynamic "rule" {
    for_each = try(flatten([var.website_server_side_encryption_configuration["rule"]]), [])

    content {
      bucket_key_enabled = try(rule.value.bucket_key_enabled, null)

      dynamic "apply_server_side_encryption_by_default" {
        for_each = try([rule.value.apply_server_side_encryption_by_default], [])

        content {
          sse_algorithm = apply_server_side_encryption_by_default.value.sse_algorithm
        }
      }
    }
  }
}



#------------------------------------------------------------------------------
# Cloudfront for S3 Bucket Website
#------------------------------------------------------------------------------
# 

resource "aws_cloudfront_distribution" "website" {
  provider = aws.main

  aliases = var.www_website_redirect_enabled ? [
    local.website_bucket_name,
    local.www_website_bucket_name
  ] : [local.website_bucket_name]

  web_acl_id = var.cloudfront_web_acl_id
  comment    = var.comment_for_cloudfront_website


  default_cache_behavior {
    cache_policy_id          = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
    origin_request_policy_id = "88a5eaf4-2fd4-4709-b370-b4c650ea3fcf" # Managed-CORS-S3Origin
    allowed_methods          = var.cloudfront_allowed_cached_methods
    cached_methods           = var.cloudfront_allowed_cached_methods
    target_origin_id         = local.website_bucket_name
    viewer_protocol_policy   = var.cloudfront_viewer_protocol_policy
    compress                 = var.cloudfront_enable_compression
    dynamic "function_association" {
      for_each = var.cloudfront_function_association
      content {
        event_type   = function_association.value.event_type
        function_arn = function_association.value.function_arn
      }
    }
  }

  /*
  dynamic "custom_error_response" {
    for_each = var.cloudfront_custom_error_responses
    content {
      error_caching_min_ttl = custom_error_response.value.error_caching_min_ttl
      error_code            = custom_error_response.value.error_code
      response_code         = custom_error_response.value.response_code
      response_page_path    = custom_error_response.value.response_page_path
    }
  }
  */

  custom_error_response {
    error_caching_min_ttl = 86400
    error_code            = 404
    response_code         = 200
    response_page_path    = "/error.html"
  }

  custom_error_response {
    error_caching_min_ttl = 86400
    error_code            = 403
    response_code         = 200
    response_page_path    = "/error.html"
  }


  default_root_object = var.cloudfront_default_root_object
  enabled             = true
  is_ipv6_enabled     = var.is_ipv6_enabled
  http_version        = var.cloudfront_http_version

  logging_config {
    include_cookies = false
    bucket          = module.s3_logs_bucket.s3_bucket_domain_name
    prefix          = "cloudfront_website"
  }

  origin {
    domain_name = aws_s3_bucket.website.bucket_regional_domain_name
    #domain_name = "collinsorighose.com.s3-website.us-east-1.amazonaws.com"

    origin_id = local.website_bucket_name
    s3_origin_config {
      origin_access_identity = aws_cloudfront_origin_access_identity.cf_oai.cloudfront_access_identity_path
    }
  }

  price_class = var.cloudfront_price_class

  restrictions {
    geo_restriction {
      restriction_type = var.cloudfront_geo_restriction_type
      locations        = var.cloudfront_geo_restriction_locations
    }
  }

  tags = merge({
    Name = "${var.name_prefix}-website"
  }, var.tags)

  viewer_certificate {
    acm_certificate_arn            = var.create_acm_certificate ? aws_acm_certificate_validation.cert_validation[0].certificate_arn : var.acm_certificate_arn_to_use
    cloudfront_default_certificate = false
    minimum_protocol_version       = "TLSv1.2_2021"
    ssl_support_method             = "sni-only"
  }

  retain_on_delete    = var.cloudfront_website_retain_on_delete
  wait_for_deployment = var.cloudfront_website_wait_for_deployment
}


#------------------------------------------------------------------------------
# Cloudfront DNS Record (if CloudFront is enabled)
#------------------------------------------------------------------------------

resource "aws_route53_record" "website_cloudfront_record" {
  provider = aws.main

  count = var.create_route53_website_records ? 1 : 0

  #zone_id = var.create_route53_hosted_zone ? aws_route53_zone.hosted_zone[0].zone_id : var.route53_hosted_zone_id
  zone_id = data.aws_route53_zone.selected.zone_id
  name    = local.website_bucket_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}

data "aws_route53_zone" "selected" {
  name         = var.website_domain_name
  private_zone = false
}


resource "aws_route53_record" "www_website_record" {
  provider = aws.main

  zone_id = data.aws_route53_zone.selected.zone_id
  name    = "www.${data.aws_route53_zone.selected.name}"
  type    = "A"
  #ttl     = "300"
  alias {
    name                   = aws_cloudfront_distribution.website.domain_name
    zone_id                = aws_cloudfront_distribution.website.hosted_zone_id
    evaluate_target_health = false
  }
}