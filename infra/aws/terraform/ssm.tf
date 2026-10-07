# Every parameter is created holding a placeholder and never read back by Terraform
# unless a provider needs it. The real values are written out of band:
#   aws ssm put-parameter --profile <p> --name <n> --type SecureString --overwrite --value ...
# lifecycle.ignore_changes is what keeps the next apply from overwriting them again.
resource "aws_ssm_parameter" "secret" {
  for_each = local.secret_parameters

  name        = "${local.prefix}/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = "placeholder-set-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "social" {
  for_each = local.social_parameters

  name        = "${local.prefix}/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = "placeholder-set-out-of-band"

  lifecycle {
    ignore_changes = [value]
  }
}

# Reading these is the one place a real secret enters Terraform state: the Cognito
# provider resources take the Apple key and the Google secret as literal arguments,
# so there is no way to create them without the value passing through.
data "aws_ssm_parameter" "social" {
  for_each = var.enable_social_idp ? local.social_parameters : {}

  name = aws_ssm_parameter.social[each.key].name
}
