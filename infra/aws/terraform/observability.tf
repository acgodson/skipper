resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

resource "aws_sns_topic" "alarms" {
  name = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# rc-api logs one JSON object per request with msg and status (apisrv/server.go serve).
resource "aws_cloudwatch_log_metric_filter" "api_5xx" {
  name           = "${local.name}-api-5xx"
  log_group_name = aws_cloudwatch_log_group.app.name
  pattern        = "{ $.msg = \"request\" && $.status >= 500 }"

  metric_transformation {
    name          = "ApiServerErrors"
    namespace     = local.metric_namespace
    value         = "1"
    unit          = "Count"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.name}-api-5xx"
  alarm_description   = "rc-api answered 500 or above more than ${var.api_5xx_threshold} times in five minutes"
  namespace           = local.metric_namespace
  metric_name         = aws_cloudwatch_log_metric_filter.api_5xx.metric_transformation[0].name
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.api_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# Probes https://<api domain>/signal/healthz from outside AWS, which is the only way to
# learn that Caddy, its certificate and rc-signal are all serving. It needs the A record,
# so it stays off until the registrar step is done.
resource "aws_route53_health_check" "signal" {
  count = var.enable_endpoint_health_check ? 1 : 0

  type                            = "HTTPS"
  fqdn                            = var.api_domain
  port                            = 443
  resource_path                   = "/signal/healthz"
  request_interval                = 30
  failure_threshold               = 3
  enable_sni                      = true
  measure_latency                 = false
  cloudwatch_alarm_region         = var.aws_region
  insufficient_data_health_status = "LastKnownStatus"

  tags = { Name = "${local.name}-signal" }
}

resource "aws_sns_topic" "alarms_us_east_1" {
  count = var.enable_endpoint_health_check ? 1 : 0

  provider = aws.us_east_1
  name     = "${local.name}-alarms"
}

resource "aws_sns_topic_subscription" "alarms_us_east_1_email" {
  count = var.enable_endpoint_health_check && var.alarm_email != "" ? 1 : 0

  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.alarms_us_east_1[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

resource "aws_cloudwatch_metric_alarm" "signal_healthz" {
  count = var.enable_endpoint_health_check ? 1 : 0

  provider            = aws.us_east_1
  alarm_name          = "${local.name}-signal-healthz"
  alarm_description   = "rc-signal stopped answering /healthz through Caddy on ${var.api_domain}"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms_us_east_1[0].arn]
  ok_actions          = [aws_sns_topic.alarms_us_east_1[0].arn]

  dimensions = {
    HealthCheckId = aws_route53_health_check.signal[0].id
  }
}

# coturn has no health endpoint reachable from a prober, so the host itself is the signal:
# the relay is down whenever the instance is.
resource "aws_cloudwatch_metric_alarm" "host_unreachable" {
  alarm_name          = "${local.name}-host-unreachable"
  alarm_description   = "The box carrying coturn failed an EC2 status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  dimensions = {
    InstanceId = aws_instance.app.id
  }
}

resource "aws_cloudwatch_metric_alarm" "disk_used" {
  alarm_name          = "${local.name}-disk-used"
  alarm_description   = "The gp3 root volume holding both SQLite files is over ${var.disk_used_percent_threshold}% full"
  namespace           = local.metric_namespace
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = var.disk_used_percent_threshold
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  dimensions = {
    InstanceId = aws_instance.app.id
    path       = "/"
    fstype     = var.root_filesystem_type
  }
}

# The alarm that protects the owner rather than the service. PHASE5 §4 step 3 also sets a
# budget in the management account; this one is scoped to this account and is in code.
resource "aws_budgets_budget" "monthly" {
  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_sns_topic_arns  = [aws_sns_topic.alarms.arn]
    subscriber_email_addresses = var.alarm_email != "" ? [var.alarm_email] : []
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alarms.arn]
    subscriber_email_addresses = var.alarm_email != "" ? [var.alarm_email] : []
  }
}

data "aws_iam_policy_document" "alarms_topic" {
  statement {
    sid       = "AllowCloudWatchAndBudgets"
    effect    = "Allow"
    actions   = ["SNS:Publish"]
    resources = [aws_sns_topic.alarms.arn]

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com", "budgets.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic.json
}
