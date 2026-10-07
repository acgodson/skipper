# Session Manager is the whole administrative path to this box — there is no inbound SSH
# rule — so an unlogged session is an unrecorded root shell.
#
# One variable drives both the log group's key and the document's
# CloudWatchEncryptionEnabled, because the preference means "refuse to log unless the
# group is KMS-encrypted": set against a group with no CMK it stops logging rather than
# downgrading it. infra/aws/README.md has the rest of the choices here.

resource "aws_kms_key" "session_logs" {
  count = var.enable_session_log_cmk ? 1 : 0

  description             = "${local.name} Session Manager transcript encryption"
  deletion_window_in_days = var.kms_deletion_window_days
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.session_logs_key.json

  tags = { Name = "${local.name}-session-logs" }
}

resource "aws_kms_alias" "session_logs" {
  count = var.enable_session_log_cmk ? 1 : 0

  name          = "alias/${local.name}-session-logs"
  target_key_id = aws_kms_key.session_logs[0].key_id
}

data "aws_iam_policy_document" "session_logs_key" {
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

  # CloudWatch Logs encrypts and decrypts on the writer's behalf, which is why the
  # instance role needs no kms action for this. Scoped to the one log group by the
  # encryption context CloudWatch Logs supplies, so the grant is not a general one.
  statement {
    sid    = "CloudWatchLogsOnlyForTheSessionGroup"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.session_log_group_arn]
    }
  }
}

resource "aws_cloudwatch_log_group" "sessions" {
  name              = local.session_log_group
  retention_in_days = var.session_log_retention_days
  kms_key_id        = var.enable_session_log_cmk ? aws_kms_key.session_logs[0].arn : null
}

# The name is fixed by AWS: a document called anything else is never consulted, which is
# the quiet way this feature fails. No s3BucketName (a second copy for a second bill) and
# no kmsKeyId (that one encrypts the live stream and would require every operator to hold
# permissions on the key — a way to lock the owner out of the only shell this box has).
resource "aws_ssm_document" "session_preferences" {
  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "${local.name} session preferences: every session is streamed to CloudWatch Logs"
    sessionType   = "Standard_Stream"
    inputs = {
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.sessions.name
      cloudWatchEncryptionEnabled = var.enable_session_log_cmk

      # Streamed as it happens, not uploaded at the end: a session that is killed, or
      # that kills the agent, still leaves behind everything it did up to that point.
      cloudWatchStreamingEnabled = true

      idleSessionTimeout = tostring(var.session_idle_timeout_minutes)
      runAsEnabled       = false
    }
  })

  tags = { Name = "${local.name}-session-preferences" }
}
