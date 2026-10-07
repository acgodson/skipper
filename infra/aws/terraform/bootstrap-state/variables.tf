variable "aws_region" {
  description = "Region the state bucket, the lock table and the state key live in. The same region as the stack, so a regional outage does not separate the state from what it describes."
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Common tag value and name prefix. Must match the root module's."
  type        = string
  default     = "skipperdesk"
}

variable "environment" {
  description = "Deployment name. Must match the root module's: it is part of every name here."
  type        = string
  default     = "prod"
}

variable "state_bucket_name" {
  description = "State bucket name. Empty means <project>-<environment>-tfstate-<account id>, which is how the account id stays out of the repository."
  type        = string
  default     = ""
}

variable "lock_table_name" {
  description = "DynamoDB table name for state locking. Empty means <project>-<environment>-tfstate-lock."
  type        = string
  default     = ""
}

variable "kms_deletion_window_days" {
  description = "Waiting period on a scheduled deletion of the state key. Deleting it makes every stored state version unreadable, so the window is the long one."
  type        = number
  default     = 30
}

variable "state_noncurrent_version_days" {
  description = "Days an superseded state version is kept before it expires. Long enough to recover from a bad apply, short enough that secrets in old state do not accumulate forever."
  type        = number
  default     = 90
}
