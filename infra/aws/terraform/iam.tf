data "aws_iam_policy_document" "assume_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "app" {
  name               = "${local.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json
}

# Session Manager instead of an inbound SSH rule. The agent dials out; nothing dials in.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "app" {
  statement {
    sid       = "ReadOwnParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = ["${local.parameter_arn_prefix}/*"]
  }

  # Resource stays "*" because the AWS-managed alias/aws/ssm key's ARN carries a key id
  # this configuration cannot name. Both conditions are load-bearing, and the second one
  # is what keeps the grant off every other SecureString in the region. Plain StringLike:
  # an IfExists or a set operator would allow a Decrypt carrying no encryption context,
  # which is the hole being closed. infra/aws/README.md "Secrets" holds the verification.
  statement {
    sid       = "DecryptOwnParameters"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = ["${local.parameter_arn_prefix}/*"]
    }
  }

  statement {
    sid       = "SignDeviceIdCertificates"
    effect    = "Allow"
    actions   = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
    resources = [aws_kms_key.id_cert.arn]
  }

  statement {
    sid       = "WriteBackups"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${module.backups.arn}/db/*", "${module.backups.arn}/claims/*"]
  }

  statement {
    sid       = "ReadReleasesAndConfig"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.backups.arn}/releases/*", "${module.backups.arn}/config/*"]
  }

  statement {
    sid       = "ListOwnPrefixes"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [module.backups.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["db/*", "claims/*", "releases/*", "config/*"]
    }
  }

  # Three writers, the same three actions: the CloudWatch agent into the app group, SSM
  # Agent streaming a session transcript into the session group, and SSM Agent writing Run
  # Command output into the runcommand group. No kms action belongs here — CloudWatch Logs
  # encrypts on the writer's behalf under the key policy in session_logging.tf, so the role
  # never touches the key.
  #
  # The runcommand group is why this list grew. Run Command output is written by the agent
  # under this role, so without it a caller passing --cloud-watch-output-enabled is denied
  # and the output silently goes nowhere — session_logging.tf has the rest of that.
  statement {
    sid     = "ShipOwnLogs"
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = [
      "${aws_cloudwatch_log_group.app.arn}:*",
      "${aws_cloudwatch_log_group.sessions.arn}:*",
      "${aws_cloudwatch_log_group.runcommand.arn}:*",
    ]
  }

  # The one action session logging needs that cannot be scoped: a resource-scoped grant
  # makes SSM Agent's unfiltered DescribeLogGroups fail rather than return a filtered
  # list, which leaves session logging silently not writing. Group names, no content.
  statement {
    sid       = "DiscoverLogGroupsForSessionLogging"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "PublishDiskMetric"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.metric_namespace]
    }
  }
}

resource "aws_iam_role_policy" "app" {
  name   = "${local.name}-instance"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.app.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name}-instance"
  role = aws_iam_role.app.name
}
