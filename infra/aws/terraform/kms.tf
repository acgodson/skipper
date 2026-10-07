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

# Administration without use. Every customer-managed key in this stack starts from this
# statement and then grants exactly one principal exactly the operations it needs, so a
# key administrator cannot sign a certificate or read a session transcript.
#
# kms:ScheduleKeyDeletion and kms:Delete* are deliberately **not** here, by the same logic
# that already omits kms:Sign: an administrator who wants to destroy the root of Device-ID
# ownership must first grant themselves the action with PutKeyPolicy, which is a second
# call, a CloudTrail event, and the id-cert-key-at-risk alarm in audit.tf. It does not stop
# them — nothing in this account can — it makes the first irreversible step arrive as mail.
#
# kms:Put* stays, and must: KMS refuses a key policy that leaves no principal able to
# PutKeyPolicy, so removing it would make the key unmanageable. CancelKeyDeletion stays
# because it is the recovery action, and kms:Delete* was only ever reachable as
# DeleteAlias and DeleteImportedKeyMaterial — neither applies to a key whose material KMS
# generated, so dropping it costs nothing. DeleteAlias is restored explicitly so Terraform
# can still manage the aliases.
data "aws_iam_policy_document" "kms_account_administration" {
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
      "kms:DeleteAlias",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

data "aws_iam_policy_document" "id_cert_key" {
  source_policy_documents = [data.aws_iam_policy_document.kms_account_administration.json]

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
