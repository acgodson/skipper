output "elastic_ip" {
  description = "The address the owner points api.<domain> and turn.<domain> at, by hand, at the registrar. This stack creates no DNS."
  value       = aws_eip.this.public_ip
}

output "dns_records_to_create" {
  description = "Exactly what to add at the registrar."
  value = [
    "A  ${split(".", var.api_domain)[0]}  ${aws_eip.this.public_ip}",
    "A  ${split(".", var.turn_domain)[0]}  ${aws_eip.this.public_ip}",
  ]
}

output "api_domain" {
  description = "What deploy.sh probes afterwards, and the client's one config value."
  value       = var.api_domain
}

output "aws_region" {
  value = var.aws_region
}

output "instance_id" {
  description = "Target for deploy.sh and for aws ssm start-session."
  value       = aws_instance.app.id
}

output "data_volume_id" {
  description = "The volume holding rc-api.db and rc-api-claims.db. It outlives the instance, and prevent_destroy keeps Terraform from removing it."
  value       = aws_ebs_volume.data.id
}

output "backup_bucket" {
  description = "Snapshots under db/ and claims/, binaries under releases/, instance configuration under config/."
  value       = module.backups.id
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.this.id
}

output "cognito_issuer" {
  description = "rc-api -cognito-issuer."
  value       = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "cognito_app_client_id" {
  description = "rc-api -cognito-audience, and the client id the sign-in page uses. Public by design: no secret."
  value       = aws_cognito_user_pool_client.web.id
}

output "id_cert_kms_key_arn" {
  description = "The device-id certificate signing key. rc-api signs with it directly: this ARN is what rc-api.service passes as -id-cert-kms-key-id, and the private half never leaves KMS."
  value       = aws_kms_key.id_cert.arn
}

output "ssm_parameter_prefix" {
  description = "Where every secret this stack reads must be written, out of band."
  value       = local.prefix
}

output "log_group" {
  value = aws_cloudwatch_log_group.app.name
}

output "audit_bucket" {
  description = "Where CloudTrail delivers management events. Separate from the backup bucket on purpose: the instance role can write to that one."
  value       = module.audit.id
}

output "audit_log_group" {
  description = "The CloudWatch Logs copy of the trail. The kms:Sign metric filter reads this group."
  value       = aws_cloudwatch_log_group.audit.name
}

output "session_log_group" {
  description = "Session Manager transcripts. With no inbound SSH rule this is the record of every administrative shell on the box."
  value       = aws_cloudwatch_log_group.sessions.name
}

output "alarm_topic_arn" {
  value = aws_sns_topic.alarms.arn
}

output "aws_account_id" {
  description = "The account this stack is in. deploy.sh asserts the profile it was given resolves to it."
  value       = data.aws_caller_identity.current.account_id
}
