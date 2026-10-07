# The audit trail, and the one alarm that watches the signing key.
#
# Its own bucket rather than a prefix of the backup bucket: the instance role can write
# to that one, and this trail exists to catch someone holding the instance role.
# infra/aws/README.md "The audit trail" has the reasoning and the costs.

data "aws_iam_policy_document" "audit_bucket" {
  statement {
    sid       = "CloudTrailCheckAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.audit_bucket}"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }

  # Scoped to this account's own log path, and to this one trail. Without the SourceArn
  # condition any CloudTrail trail in any account could be pointed at this bucket.
  statement {
    sid       = "CloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.audit_bucket}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

module "audit" {
  source = "./modules/hardened-bucket"

  bucket                 = local.audit_bucket
  name_tag               = "${local.name}-audit"
  extra_policy_documents = [data.aws_iam_policy_document.audit_bucket.json]
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = module.audit.id

  rule {
    id     = "trail-logs"
    status = "Enabled"

    filter {
      prefix = "AWSLogs/"
    }

    transition {
      days          = var.backup_ia_transition_days
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = var.audit_log_expiration_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.audit_log_expiration_days
    }
  }

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [module.audit]
}

resource "aws_cloudwatch_log_group" "audit" {
  name              = local.audit_log_group
  retention_in_days = var.audit_log_retention_days
}

data "aws_iam_policy_document" "assume_cloudtrail" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_iam_role" "cloudtrail_logs" {
  name               = "${local.name}-cloudtrail-logs"
  assume_role_policy = data.aws_iam_policy_document.assume_cloudtrail.json
}

data "aws_iam_policy_document" "cloudtrail_logs" {
  statement {
    sid       = "DeliverTrailToLogGroup"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.audit.arn}:*"]
  }
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name   = "${local.name}-cloudtrail-logs"
  role   = aws_iam_role.cloudtrail_logs.id
  policy = data.aws_iam_policy_document.cloudtrail_logs.json
}

# Management events only, which is the copy AWS delivers free. No data_resource block:
# data events are billed per event, the 15-minute backup PutObject would make that a
# standing bill, and they would record more than API.md §9 allows.
resource "aws_cloudtrail" "management" {
  name                          = local.trail_name
  s3_bucket_name                = module.audit.id
  include_global_service_events = true
  is_multi_region_trail         = var.cloudtrail_multi_region
  enable_log_file_validation    = true
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.audit.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.cloudtrail_logs.arn

  # read_write_type must be All, not WriteOnly. kms:Sign is logged with
  # "readOnly": true, so a write-only trail records no signature at all and the alarm
  # below would sit at zero forever while certificates were minted.
  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  tags = { Name = local.trail_name }

  depends_on = [module.audit, aws_iam_role_policy.cloudtrail_logs]
}

# resources[0].ARN rather than requestParameters.keyId: rc-api is handed the key as
# -id-cert-kms-key-id, which may be an id, an alias or an ARN, and CloudTrail echoes
# back whatever the caller passed. The resources entry is the ARN CloudTrail resolved.
resource "aws_cloudwatch_log_metric_filter" "id_cert_signs" {
  name           = "${local.name}-id-cert-signs"
  log_group_name = aws_cloudwatch_log_group.audit.name
  pattern        = "{ ($.eventSource = \"kms.amazonaws.com\") && ($.eventName = \"Sign\") && ($.resources[0].ARN = \"${aws_kms_key.id_cert.arn}\") }"

  metric_transformation {
    name          = "IdCertSignatures"
    namespace     = local.metric_namespace
    value         = "1"
    unit          = "Count"
    default_value = 0
  }
}

# Volume, not existence: registry.Local.Certify re-signs on every authenticated hello
# (server/internal/hub/handle.go), so this tracks reconnections rather than new devices
# and a healthy fleet signs constantly. The README has the threshold arithmetic.
resource "aws_cloudwatch_metric_alarm" "id_cert_signs" {
  alarm_name          = "${local.name}-id-cert-signs"
  alarm_description   = "More than ${var.id_cert_sign_threshold} device-id certificates were signed in five minutes, which is more reconnections than this fleet can produce"
  namespace           = local.metric_namespace
  metric_name         = aws_cloudwatch_log_metric_filter.id_cert_signs.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.id_cert_sign_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}
