locals {
  unit_vars = {
    service_user           = local.service_user
    app_dir                = local.app_dir
    data_dir               = local.data_dir
    config_dir             = local.config_dir
    log_dir                = local.log_dir
    api_listen             = local.api_listen
    api_internal_listen    = local.api_internal_listen
    signal_listen          = local.signal_listen
    signal_internal_listen = local.signal_internal_listen
    trusted_proxies        = local.trusted_proxies
    web_base_url           = var.web_base_url
    cognito_issuer         = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
    cognito_audience       = aws_cognito_user_pool_client.web.id
    turn_urls              = "turn:${var.turn_domain}:${var.turn_listen_port}?transport=udp,turn:${var.turn_domain}:${var.turn_listen_port}?transport=tcp"
    stun_urls              = "stun:${var.turn_domain}:${var.turn_listen_port}"

    # The key ARN, never the alias. An alias can be retargeted at a different key, which
    # would invalidate every certificate ever issued without changing a line of config,
    # and iam.tf scopes kms:Sign to this ARN.
    id_cert_kms_key_id = aws_kms_key.id_cert.arn
  }

  config_objects = {
    "Caddyfile"                       = file("${path.module}/../Caddyfile")
    "caddy.service.d/override.conf"   = file("${path.module}/../systemd/caddy.service.d/override.conf")
    "coturn.service.d/override.conf"  = file("${path.module}/../systemd/coturn.service.d/override.conf")
    "backup.sh"                       = file("${path.module}/../cloud-init/backup.sh")
    "skipperdesk-backup-db.timer"     = file("${path.module}/../systemd/skipperdesk-backup-db.timer")
    "skipperdesk-backup-claims.timer" = file("${path.module}/../systemd/skipperdesk-backup-claims.timer")
    "rc-api.service"                  = templatefile("${path.module}/../systemd/rc-api.service", local.unit_vars)
    "rc-api.service.d/mount.conf"     = templatefile("${path.module}/../systemd/rc-api.service.d/mount.conf", local.unit_vars)
    "rc-signal.service"               = templatefile("${path.module}/../systemd/rc-signal.service", local.unit_vars)
    "skipperdesk-backup@.service"     = templatefile("${path.module}/../systemd/skipperdesk-backup@.service", local.unit_vars)
    "cloudwatch-agent.json" = templatefile("${path.module}/../cloud-init/cloudwatch-agent.json", {
      aws_region       = var.aws_region
      metric_namespace = local.metric_namespace
      log_group        = local.log_group
      log_dir          = local.log_dir
      data_dir         = local.data_dir
    })
    "logrotate/coturn" = file("${path.module}/../logrotate/coturn")
    "turnserver.conf" = templatefile("${path.module}/../coturn/turnserver.conf", {
      turn_listen_port    = var.turn_listen_port
      turn_relay_min_port = var.turn_relay_min_port
      turn_relay_max_port = var.turn_relay_max_port
      turn_realm          = var.turn_domain
      external_ip         = aws_eip.this.public_ip
      turn_user_quota     = var.turn_user_quota
      turn_total_quota    = var.turn_total_quota
      turn_max_bps        = var.turn_max_bps
      turn_bps_capacity   = var.turn_bps_capacity
    })
  }
}

# The instance reads its configuration from here instead of carrying it in user data,
# which is capped at 16 KB and is visible to anything that can reach the metadata service.
resource "aws_s3_object" "config" {
  for_each = local.config_objects

  bucket       = module.backups.id
  key          = "config/${each.key}"
  content      = each.value
  content_type = "text/plain"

  server_side_encryption = "AES256"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  monitoring                  = false

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    iops                  = var.root_volume_iops
    throughput            = var.root_volume_throughput
    encrypted             = true
    delete_on_termination = true

    tags = { Name = "${local.name}-root" }
  }

  # Deliberately false: a changed bootstrap must never silently replace this box. The
  # databases would survive it now that they are on their own volume, but the ACME
  # certificate and the release directories would not — infra/aws/README.md
  # "Changing the bootstrap".
  user_data_replace_on_change = false
  user_data = templatefile("${path.module}/../cloud-init/bootstrap.sh", {
    project            = var.project
    aws_region         = var.aws_region
    backup_bucket      = module.backups.id
    ssm_prefix         = local.prefix
    service_user       = local.service_user
    app_dir            = local.app_dir
    data_dir           = local.data_dir
    config_dir         = local.config_dir
    log_dir            = local.log_dir
    acme_email         = var.acme_email
    api_domain         = var.api_domain
    api_listen         = local.api_listen
    signal_listen      = local.signal_listen
    external_ip        = aws_eip.this.public_ip
    filesystem_type    = var.filesystem_type
    data_volume_serial = replace(aws_ebs_volume.data.id, "-", "")
  })

  tags = { Name = local.name }

  depends_on = [
    aws_s3_object.config,
    aws_iam_role_policy.app,
    aws_ssm_parameter.secret,
    aws_route_table_association.public,
  ]

  lifecycle {
    ignore_changes = [ami]
  }
}
