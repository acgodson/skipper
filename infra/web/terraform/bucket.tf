# Private bucket, reachable only through the distribution. Not a website-endpoint bucket:
# that endpoint is plain HTTP, it cannot be fronted by Origin Access Control, and it would
# serve the same files without any of the headers cloudfront.tf sets.
module "site" {
  source = "../../aws/terraform/modules/hardened-bucket"

  bucket   = local.site_bucket
  name_tag = local.name

  extra_policy_documents = [data.aws_iam_policy_document.cloudfront_read.json]
}

# Scoped by account rather than by the distribution's ARN, because the distribution names
# the bucket as its origin and a policy naming the distribution would close that loop. The
# account is the only principal that can create a distribution here, and the files are a
# public website in any case; what this policy is actually for is making CloudFront the only
# way in, so nothing can be fetched past the headers and the cache.
data "aws_iam_policy_document" "cloudfront_read" {
  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.site_bucket}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# The module versions every bucket it makes, which is right — a bad deploy is recoverable —
# but every `deploy.sh --delete` leaves a delete marker and every edit leaves a version, and
# a site deployed often would otherwise keep all of them for ever.
resource "aws_s3_bucket_lifecycle_configuration" "site" {
  bucket = module.site.id

  rule {
    id     = "expire-superseded-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    expiration {
      expired_object_delete_marker = true
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# The one file in the site that is configuration rather than content: it carries the sign-in
# origin, the app client id and the API domain. Terraform owns it so those three values have
# exactly one source, and deploy.sh excludes it from the sync for the same reason.
resource "aws_s3_object" "config" {
  bucket        = module.site.id
  key           = "config.js"
  content_type  = "application/javascript; charset=utf-8"
  cache_control = "no-cache"

  content = format("window.SKIPPER_CONFIG = %s;\n", jsonencode({
    cognitoDomain   = local.sign_in_origin
    cognitoClientId = data.terraform_remote_state.backend.outputs.cognito_app_client_id
    apiBase         = local.api_origin
  }))

  server_side_encryption = "AES256"
}
