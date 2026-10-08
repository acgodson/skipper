resource "aws_cognito_user_pool" "this" {
  name                     = local.name
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OPTIONAL"
  deletion_protection      = "ACTIVE"

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_uppercase                = true
    require_symbols                  = false
    temporary_password_validity_days = 1
  }

  software_token_mfa_configuration {
    enabled = true
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  user_attribute_update_settings {
    attributes_require_verification_before_update = ["email"]
  }

  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 5
      max_length = 254
    }
  }
}

# Cognito's own hosted sign-in, on the free prefix domain. No ACM certificate and no DNS
# from the owner, which is the whole reason it is not auth.<domain> yet.
#
# TODO: move to the custom domain auth.${local.web_domain} with the Apple work. That needs
# an ACM certificate in us-east-1, a CNAME at the registrar, and aws_cognito_user_pool_domain
# replaced by its certificate_arn form — see infra/aws/README.md "Sign-in".
resource "aws_cognito_user_pool_domain" "this" {
  domain                = local.cognito_domain_prefix
  user_pool_id          = aws_cognito_user_pool.this.id
  managed_login_version = var.cognito_managed_login_version
}

# Brand for the classic hosted UI, which is what managed_login_version = 1 serves. The
# mechanism is a logo image plus CSS restricted to the *-customizable classes and the
# per-class property list in the AWS classic-branding reference — not the managed-login
# branding editor, which exists only at version 2. Set pool-wide, so it covers the web
# client and any client added later. Omitted entirely at version 2, where it would have
# no effect and aws_cognito_managed_login_branding is the resource instead.
#
# The grey page surround, the 350px card, the card's own border and the Arial body font
# come from Cognito's stylesheet on selectors that are not in the allow-list, so they are
# not reachable from here — infra/aws/README.md "Sign-in" records what that costs.
resource "aws_cognito_user_pool_ui_customization" "hosted_ui" {
  count = var.cognito_managed_login_version == 1 ? 1 : 0

  user_pool_id = aws_cognito_user_pool.this.id
  css          = file("${path.module}/branding/cognito-hosted-ui.css")
  image_file   = filebase64("${path.module}/branding/cognito-hosted-ui-logo.png")

  depends_on = [aws_cognito_user_pool_domain.this]
}

# Public client: no secret, because the page that drives the sign-in is static and served
# from a bucket. A secret in a page is not a secret, so the authorization code is bound to
# the browser with PKCE instead (protocol/API.md §1.1, infra/web/README.md).
#
# ALLOW_USER_SRP_AUTH is deliberately absent. Hosted sign-in does not use the InitiateAuth
# flows, so leaving it on would publish a password-guessing surface on a client that has no
# password form of its own.
resource "aws_cognito_user_pool_client" "web" {
  name            = "${local.name}-web"
  user_pool_id    = aws_cognito_user_pool.this.id
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  supported_identity_providers = concat(
    ["COGNITO"],
    var.enable_social_idp ? ["SignInWithApple", "Google"] : [],
  )

  callback_urls                        = local.cognito_callback_urls
  logout_urls                          = local.cognito_logout_urls
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  depends_on = [
    aws_cognito_identity_provider.apple,
    aws_cognito_identity_provider.google,
  ]
}

resource "aws_cognito_identity_provider" "apple" {
  count = var.enable_social_idp ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = "SignInWithApple"
  provider_type = "SignInWithApple"

  provider_details = {
    client_id        = data.aws_ssm_parameter.social["apple-services-id"].value
    team_id          = data.aws_ssm_parameter.social["apple-team-id"].value
    key_id           = data.aws_ssm_parameter.social["apple-key-id"].value
    private_key      = data.aws_ssm_parameter.social["apple-private-key"].value
    authorize_scopes = "email name"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
  }
}

resource "aws_cognito_identity_provider" "google" {
  count = var.enable_social_idp ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = data.aws_ssm_parameter.social["google-client-id"].value
    client_secret    = data.aws_ssm_parameter.social["google-client-secret"].value
    authorize_scopes = "openid email profile"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
  }
}
