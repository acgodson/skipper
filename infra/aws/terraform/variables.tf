variable "aws_region" {
  description = "Region everything but the Route 53 health-check alarm lives in."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Common tag value and name prefix."
  type        = string
  default     = "skipperdesk"
}

variable "environment" {
  description = "Deployment name; part of every resource name and of the SSM parameter prefix."
  type        = string
  default     = "prod"
}

variable "api_domain" {
  description = "The one value the client is configured with. Caddy requests a certificate for it over HTTP-01."
  type        = string
  default     = "api.skipperdesk.app"
}

variable "turn_domain" {
  description = "Name the TURN relay is advertised under; also coturn's realm."
  type        = string
  default     = "turn.skipperdesk.app"
}

variable "web_base_url" {
  description = "The website this API belongs to (rc-api -web-base-url)."
  type        = string
  default     = "https://skipperdesk.app"
}

variable "acme_email" {
  description = "Address Let's Encrypt sends expiry warnings to. Required: Caddy will not start without it."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR of the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR of the one public subnet."
  type        = string
  default     = "10.20.1.0/24"
}

variable "availability_zone" {
  description = "AZ the subnet and the instance live in. One AZ is the accepted single point of failure."
  type        = string
  default     = "eu-west-2a"
}

variable "instance_type" {
  description = "Graviton instance type for the app box."
  type        = string
  default     = "t4g.small"
}

variable "ami_ssm_parameter" {
  description = "Public SSM parameter naming the AMI. Ubuntu LTS carries both caddy and coturn in its own archive, so no third-party apt repository is added."
  type        = string
  default     = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

variable "root_volume_gb" {
  description = "gp3 root volume size. It carries the operating system, the two binaries and the log files — no database: those are on the separate data volume."
  type        = number
  default     = 20
}

variable "filesystem_type" {
  description = "Filesystem of both volumes. It is a dimension of the disk metric the CloudWatch agent publishes, so the alarms have to name it."
  type        = string
  default     = "ext4"
}

variable "root_volume_iops" {
  description = "gp3 baseline IOPS; 3000 is included in the per-GB price."
  type        = number
  default     = 3000
}

variable "root_volume_throughput" {
  description = "gp3 baseline MiB/s; 125 is included in the per-GB price."
  type        = number
  default     = 125
}

variable "data_volume_gb" {
  description = "gp3 size of the volume mounted at /var/lib/<project>. rc-api.db and rc-api-claims.db live only here; it survives the instance."
  type        = number
  default     = 20
}

variable "data_volume_iops" {
  description = "gp3 baseline IOPS on the data volume; 3000 is included in the per-GB price."
  type        = number
  default     = 3000
}

variable "data_volume_throughput" {
  description = "gp3 baseline MiB/s on the data volume; 125 is included in the per-GB price."
  type        = number
  default     = 125
}

variable "data_volume_device_name" {
  description = "Attachment name asked of EC2. On Nitro the kernel renames it to an unstable /dev/nvme*, which is why the bootstrap finds the disk by its volume id and mounts it by filesystem UUID."
  type        = string
  default     = "/dev/sdf"
}

variable "turn_listen_port" {
  description = "coturn listening port, tcp and udp."
  type        = number
  default     = 3478
}

variable "turn_relay_min_port" {
  description = "Low end of the relay range."
  type        = number
  default     = 49160
}

variable "turn_relay_max_port" {
  description = "High end of the relay range."
  type        = number
  default     = 49200
}

variable "turn_user_quota" {
  description = "Concurrent allocations one TURN username may hold. The 1:1 launch value was 6."
  type        = number
  default     = 12
}

variable "turn_total_quota" {
  description = "Concurrent allocations the server will hold in total."
  type        = number
  default     = 200
}

variable "turn_max_bps" {
  description = "Per-allocation relay ceiling, in BYTES per second, with coturn counting the input and output streams separately — so this is one relayed direction. 1222600 B/s is 9.78 Mbps: the 8 Mbps the shipped client requests in every quality mode including `auto` (QualityProfile.swift burstBitrateBps, and PLAN.md §5's 8 Mbps burst line), plus 0.1 Mbps of ctrl/hi data channel, times 1.05 for RTP/SRTP/UDP/IP/ChannelData framing and RTCP, times 1.15 of queueing margin. Sized so it cannot clip a legitimate session at the quality ceiling; real sessions measure 383-391 kbps (VERIFY.md), 4% of this. See infra/aws/README.md \"Relay bandwidth\"."
  type        = number
  default     = 1222600
}

variable "turn_bps_capacity" {
  description = "Box-wide relay ceiling, in BYTES per second per direction. 7200000 B/s is 57.6 Mbps, which is 90% of the t4g.small 0.128 Gbps sustained network baseline split across the two directions coturn meters separately, leaving a tenth of the NIC for Caddy, both Go services, the 15-minute backup upload and the agents. That is 5 concurrent sessions at the full 8 Mbps ceiling, against PHASE5 §3's 4-6 concurrent relayed sessions at peak for this shape, or about 147 concurrent at the measured bitrate. It is not a cost control: 57.6 Mbps sustained is still $56/day, which is why the NetworkOut alarm below exists."
  type        = number
  default     = 7200000
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention for both services."
  type        = number
  default     = 30
}

variable "backup_bucket_name" {
  description = "Backup bucket name. Empty means <project>-<environment>-backups-<account id>."
  type        = string
  default     = ""
}

variable "backup_ia_transition_days" {
  description = "Days before a main-database snapshot moves to Standard-IA."
  type        = number
  default     = 30
}

variable "backup_expiration_days" {
  description = "Days before a main-database snapshot is deleted. The claims prefix is exempt and never expires."
  type        = number
  default     = 365
}

variable "audit_bucket_name" {
  description = "CloudTrail bucket name. Empty means <project>-<environment>-audit-<account id>. Its own bucket, not a prefix of the backup bucket: the instance role can write to that one, and this trail exists to catch someone holding the instance role."
  type        = string
  default     = ""
}

variable "cloudtrail_multi_region" {
  description = "Record every region, not only the one this stack is in. The first copy of management events is free either way, and activity in a region we never use is itself the signal."
  type        = bool
  default     = true
}

variable "audit_log_retention_days" {
  description = "CloudWatch Logs retention for the CloudTrail copy. The S3 copy is the archive and keeps audit_log_expiration_days; this copy only has to outlive an investigation."
  type        = number
  default     = 90
}

variable "audit_log_expiration_days" {
  description = "Days before a CloudTrail object in S3 is deleted."
  type        = number
  default     = 365
}

variable "id_cert_sign_threshold" {
  description = "Device-id certificate signatures, in five minutes, that raise the minting alarm. Signs track reconnections rather than new devices, so this is sized on fleet size: roughly 6 x expected hosts, floor 60. See infra/aws/README.md \"Alarms\"."
  type        = number
  default     = 60
}

variable "session_log_retention_days" {
  description = "CloudWatch Logs retention for Session Manager transcripts."
  type        = number
  default     = 90
}

variable "enable_session_log_cmk" {
  description = "Encrypt the session-transcript log group with a customer-managed key and require it in the session preferences. Adds $1/month. Off means the group keeps CloudWatch's own default encryption and CloudWatchEncryptionEnabled goes false with it — the two are driven from this one variable because a mismatch stops session logging rather than downgrading it."
  type        = bool
  default     = true
}

variable "session_idle_timeout_minutes" {
  description = "Minutes an idle Session Manager session is held open before it is closed. AWS accepts 1 to 60."
  type        = number
  default     = 20
}

variable "kms_deletion_window_days" {
  description = "Waiting period on a scheduled deletion of the id-cert signing key."
  type        = number
  default     = 30
}

variable "ssm_parameter_prefix" {
  description = "Prefix of every parameter this stack reads. Empty means /<project>/<environment>."
  type        = string
  default     = ""
}

variable "cognito_domain_prefix" {
  description = "Label of the free Cognito sign-in domain, <prefix>.auth.<region>.amazoncognito.com. Empty means <project>. It must be unique across the region, so an apply that fails on it needs a different value here, not a retry."
  type        = string
  default     = ""
}

variable "cognito_managed_login_version" {
  description = "1 is the classic hosted UI, which needs no branding resource. 2 is managed login, which renders from the branding designer and so needs an aws_cognito_managed_login_branding alongside it."
  type        = number
  default     = 1

  validation {
    condition     = contains([1, 2], var.cognito_managed_login_version)
    error_message = "cognito_managed_login_version must be 1 or 2."
  }
}

variable "extra_cognito_callback_urls" {
  description = "Redirect targets beyond https://<web domain>/link. For a local origin while the sign-in page is being worked on; empty in production."
  type        = list(string)
  default     = []
}

variable "extra_cognito_logout_urls" {
  description = "Sign-out redirect targets beyond https://<web domain>/."
  type        = list(string)
  default     = []
}

variable "enable_social_idp" {
  description = "Wire the Apple and Google providers. Leave false until both secrets hold real values in SSM: Terraform must read them to create the providers, which puts them in state (README \"Secrets\")."
  type        = bool
  default     = false
}

variable "enable_endpoint_health_check" {
  description = "Create the Route 53 health check that probes the public endpoint. It needs the A records to exist first, so turn it on after the DNS step."
  type        = bool
  default     = false
}

variable "alarm_email" {
  description = "Address the alarm topic and the budget notify. Empty creates no subscription, and the alarms then have nowhere to go."
  type        = string
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Monthly cost budget for this account."
  type        = number
  default     = 50
}

variable "disk_used_percent_threshold" {
  description = "Root-volume usage that raises the disk alarm."
  type        = number
  default     = 80
}

variable "api_5xx_threshold" {
  description = "rc-api responses of 500 or above, in five minutes, that raise the error alarm."
  type        = number
  default     = 10
}

variable "network_out_alarm_bytes" {
  description = "AWS/EC2 NetworkOut bytes in one five-minute period that raise the egress alarm. 1241200000 is the rate which, sustained for 24 hours, would consume the entire monthly egress allowance a $50 budget affords: $50 less $26.83 of fixed cost (PHASE5 §3.2's ten-host column, $26.13, plus $0.70 for the seven alarms this review adds) leaves $23.17, which buys 257 GB at $0.09/GB on top of the 100 GB free tier, so 357 GB; 357.4e9 bytes over 24 hours is 1.2412e9 per five-minute period. That is about 3.5x PHASE5 §3's 4-6 concurrent peak for this shape, so legitimate load cannot reach it, and 57% of what bps-capacity now permits, so it fires before the cap saturates and long before the budget email, which lags up to 24 hours and only sends at 80%."
  type        = number
  default     = 1241200000
}

variable "network_out_alarm_periods" {
  description = "Consecutive five-minute periods above network_out_alarm_bytes before the egress alarm fires. Two means ten sustained minutes, which a backup upload or one legitimate spike cannot produce."
  type        = number
  default     = 2
}

variable "backup_stale_alarm_hours" {
  description = "Hours without a confirmed snapshot in a backup prefix before the backup-stale alarm fires. Both timers run every 15 minutes, so the default of 1 allows four consecutive failures - enough to ride out a transient S3 error or a boot whose first attempt precedes rc-api opening the databases, and short enough that the claims prefix can never again go a day unwritten unnoticed. See infra/aws/README.md \"Backups\"."
  type        = number
  default     = 1
}
