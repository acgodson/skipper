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
  source_policy_documents = [data.aws_iam_policy_document.kms_account_administration.json]

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

# Run Command, not Session Manager, is the path that is actually used: infra/aws/deploy.sh
# and scripts/publish-release.sh both call send-command, and CloudTrail records the call
# with "parameters":"HIDDEN_DUE_TO_SECURITY_REASONS", so the account's only record of what
# a command did was nothing at all.
#
# The session preferences document cannot cover it — its sessionType is Standard_Stream and
# Run Command is not a session — and there is no account setting that forces a caller to
# ask for output. What *was* missing is the half that makes asking work: SSM Agent writes
# Run Command output with the instance role, and that role's logs grant named only the app
# and sessions groups, so a caller who passed --cloud-watch-output-enabled would have been
# denied and the output would have gone nowhere. This group plus the grant in iam.tf closes
# that, and both callers now pass the flag.
#
# No CMK here, unlike the session group. Run Command output is the same class of material as
# the session transcript, but a key on this group would have to be readable by whoever reads
# a deploy's output, and the session-group key policy already explains why that is a way to
# lock the owner out of their own diagnostics. The group is encrypted at rest by CloudWatch
# Logs' own service key either way.
resource "aws_cloudwatch_log_group" "runcommand" {
  name              = local.runcommand_log_group
  retention_in_days = var.session_log_retention_days
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
