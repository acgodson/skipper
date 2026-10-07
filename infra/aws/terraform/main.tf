data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

locals {
  name   = "${var.project}-${var.environment}"
  prefix = var.ssm_parameter_prefix != "" ? var.ssm_parameter_prefix : "/${var.project}/${var.environment}"

  backup_bucket = var.backup_bucket_name != "" ? var.backup_bucket_name : "${local.name}-backups-${data.aws_caller_identity.current.account_id}"

  log_group        = "/${var.project}/${var.environment}/app"
  metric_namespace = "${var.project}/${var.environment}"

  service_user = var.project
  app_dir      = "/opt/${var.project}"
  data_dir     = "/var/lib/${var.project}"
  config_dir   = "/etc/${var.project}"
  log_dir      = "/var/log/${var.project}"

  api_listen             = "127.0.0.1:18080"
  api_internal_listen    = "127.0.0.1:18081"
  signal_listen          = "127.0.0.1:8443"
  signal_internal_listen = "127.0.0.1:18444"

  # Caddy is the only hop in front of either Go process and it runs on this machine,
  # so the one address whose X-Forwarded-For may be believed is the loopback address.
  trusted_proxies = "127.0.0.1/32"

  secret_parameters = {
    turn-secret    = "coturn static-auth-secret; rc-signal mints HMAC-SHA1 credentials from it"
    internal-token = "shared bearer for both internal listeners"
    hardware-salt  = "server salt for the hardware hash"
    token-secret   = "hex HMAC secret for session tokens"
    id-cert-key    = "PEM PKCS#8 P-256 key that signs device-id certificates"
  }

  social_parameters = {
    apple-services-id    = "Sign in with Apple services id, used as the provider client id"
    apple-team-id        = "Apple team id"
    apple-key-id         = "Sign in with Apple key id"
    apple-private-key    = "Sign in with Apple .p8 private key"
    google-client-id     = "Google OAuth 2.0 web client id"
    google-client-secret = "Google OAuth 2.0 web client secret"
  }
}
