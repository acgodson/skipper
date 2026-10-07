data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# Read, not copied. The website needs three values the backend stack owns — the sign-in
# origin, the app client id and the API domain — and every one of them is already an output
# there. A variable would mean three strings maintained in two places, and a wrong one fails
# as a sign-in that will not complete rather than as a plan error.
#
# What the coupling costs, plainly: this module cannot plan at all until the backend stack
# has been applied once, and it needs read access to that state object and its KMS key. It
# is a read of an S3 object, so it neither locks nor refreshes anything the backend stack
# manages — which is the separation the split was for. If the backend stack ever renames one
# of these outputs, this plan breaks; that is the trade for not duplicating them.
data "terraform_remote_state" "backend" {
  backend = "s3"

  config = {
    bucket = var.backend_state_bucket
    key    = var.backend_state_key
    region = var.aws_region
  }
}

locals {
  name = "${var.project}-${var.environment}-web"

  site_bucket = var.site_bucket_name != "" ? var.site_bucket_name : "${local.name}-${data.aws_caller_identity.current.account_id}"

  web_domain     = data.terraform_remote_state.backend.outputs.web_domain
  www_domain     = "www.${local.web_domain}"
  api_origin     = "https://${data.terraform_remote_state.backend.outputs.api_domain}"
  sign_in_origin = data.terraform_remote_state.backend.outputs.cognito_sign_in_base_url

  # Everything the page is allowed to reach. The page loads no font, no analytics and no
  # third-party script, so every fetch directive but these two is 'none' by inheritance from
  # default-src, and the two that are listed are the sign-in origin and our own API. A
  # 'self' in connect-src would be dead permission: the page never calls back to itself.
  content_security_policy = join("; ", [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self'",
    "connect-src ${local.api_origin} ${local.sign_in_origin}",
    "form-action 'none'",
    "frame-ancestors 'none'",
    "base-uri 'none'",
    "object-src 'none'",
  ])
}
