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
  description = "gp3 root volume size. The two SQLite files and the claims database live on it."
  type        = number
  default     = 20
}

variable "root_filesystem_type" {
  description = "Filesystem of the root volume. It is a dimension of the disk metric the CloudWatch agent publishes, so the alarm has to name it."
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

variable "cognito_callback_urls" {
  description = "Redirect targets the public app client may use. Our own sign-in page calls the Cognito API directly, so this matters only to the social providers."
  type        = list(string)
  default     = ["https://skipperdesk.app/sign-in"]
}

variable "cognito_logout_urls" {
  description = "Sign-out redirect targets for the public app client."
  type        = list(string)
  default     = ["https://skipperdesk.app/"]
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
