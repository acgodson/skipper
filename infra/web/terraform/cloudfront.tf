resource "aws_cloudfront_origin_access_control" "site" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_function" "fixup" {
  name    = "${local.name}-fixup"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = file("${path.module}/functions/fixup.js")
}

# Pages and /config.js. The objects are uploaded no-cache, so in practice CloudFront
# revalidates every time; these TTLs are the ceiling that stops a forgotten invalidation
# from serving an old page for longer than a few minutes.
resource "aws_cloudfront_cache_policy" "pages" {
  name        = "${local.name}-pages"
  min_ttl     = 0
  default_ttl = 60
  max_ttl     = var.html_max_ttl_seconds

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

# Anything under /assets/. The query string is in the cache key so that assets/styles.css?v=2
# is a different object from ?v=1 — the cache bust a site with no build step has instead of a
# content hash in the filename.
resource "aws_cloudfront_cache_policy" "assets" {
  name        = "${local.name}-assets"
  min_ttl     = 1
  default_ttl = var.asset_ttl_seconds
  max_ttl     = var.asset_ttl_seconds

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }
    headers_config {
      header_behavior = "none"
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }
}

resource "aws_cloudfront_response_headers_policy" "site" {
  name = local.name

  security_headers_config {
    # No preload. Preloading is close to irreversible and is the owner's decision to make
    # once, not a side effect of the first website deploy. includeSubDomains covers
    # api.<domain>, which is already HTTPS only; the TURN relay is not HTTP and is unaffected.
    strict_transport_security {
      override                   = true
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      preload                    = false
    }

    content_type_options {
      override = true
    }

    # Belt to the CSP's frame-ancestors braces, for anything that still reads only this.
    frame_options {
      override     = true
      frame_option = "DENY"
    }

    # The sign-in page's URL carries the app's nonce and the device's public key in its
    # query string. no-referrer is what keeps them out of Cognito's logs and out of any
    # other host the page ever reaches.
    referrer_policy {
      override        = true
      referrer_policy = "no-referrer"
    }

    content_security_policy {
      override                = true
      content_security_policy = local.content_security_policy
    }
  }

  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      override = true
      value    = "accelerometer=(), camera=(), display-capture=(), geolocation=(), gyroscope=(), microphone=(), payment=(), usb=()"
    }

    items {
      header   = "Cross-Origin-Opener-Policy"
      override = true
      value    = "same-origin"
    }
  }

  remove_headers_config {
    items {
      header = "Server"
    }
  }
}

resource "aws_cloudfront_distribution" "site" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = local.name
  default_root_object = "index.html"
  price_class         = var.price_class
  aliases             = [local.web_domain, local.www_domain]

  origin {
    origin_id                = local.site_bucket
    domain_name              = module.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  default_cache_behavior {
    target_origin_id           = local.site_bucket
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.pages.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.fixup.arn
    }
  }

  ordered_cache_behavior {
    path_pattern               = "/assets/*"
    target_origin_id           = local.site_bucket
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = aws_cloudfront_cache_policy.assets.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.fixup.arn
    }
  }

  # Only s3:GetObject is granted, never s3:ListBucket, so S3 answers a missing key with 403
  # rather than 404. Both have to land on the same page or a mistyped address shows XML.
  custom_error_response {
    error_code            = 403
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 30
  }

  custom_error_response {
    error_code            = 404
    response_code         = 404
    response_page_path    = "/404.html"
    error_caching_min_ttl = 30
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.site.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  http_version = "http2and3"

  tags = { Name = local.name }
}
