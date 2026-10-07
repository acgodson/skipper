data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  name = "${var.project}-${var.environment}"

  bucket = var.state_bucket_name != "" ? var.state_bucket_name : "${local.name}-tfstate-${data.aws_caller_identity.current.account_id}"
  table  = var.lock_table_name != "" ? var.lock_table_name : "${local.name}-tfstate-lock"

  state_key = "${var.environment}/terraform.tfstate"
}
