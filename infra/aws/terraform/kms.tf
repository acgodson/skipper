# The root of Device-ID ownership (API.md §6.1, PHASE5 §1.2). The private half never
# leaves KMS, so it cannot be copied off the box, and every signature is a CloudTrail event.
#
# Rotation is deliberately not automated: KMS cannot rotate an asymmetric key, and the
# contract has no verifier that accepts two signing keys at once (PHASE5 §1.2).
# TODO: specify dual-key verification in protocol/API.md, then rotate by creating a second
# key, signing new certificates with it, and retiring this one after the certificate lifetime.
resource "aws_kms_key" "id_cert" {
  description              = "${local.name} device-id certificate signing key"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = var.kms_deletion_window_days
  enable_key_rotation      = false
  policy                   = data.aws_iam_policy_document.id_cert_key.json

  tags = { Name = "${local.name}-id-cert" }
}

resource "aws_kms_alias" "id_cert" {
  name          = "alias/${local.name}-id-cert"
  target_key_id = aws_kms_key.id_cert.key_id
}

data "aws_iam_policy_document" "id_cert_key" {
  statement {
    sid    = "AccountAdministration"
    effect = "Allow"
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid       = "SignOnlyFromTheApplicationRole"
    effect    = "Allow"
    actions   = ["kms:Sign", "kms:Verify", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.app.arn]
    }
  }
}
