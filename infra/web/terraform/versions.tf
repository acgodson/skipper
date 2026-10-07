terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # The same bucket, lock table and KMS key as the backend stack, under a different key.
  # Sharing the bucket keeps one thing to back up and one key policy to audit; the separate
  # key is the point — a plan here locks and refreshes only the website's own resources, so
  # shipping a landing page can never roll, replace or even read the box that runs sessions.
  #
  # A partial configuration, for the same reason as infra/aws/terraform: the bucket name and
  # the key ARN both carry the account id. infra/web/README.md "State" has the two commands.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
      component   = "web"
      managedBy   = "terraform"
    }
  }
}

# CloudFront reads its viewer certificate only from us-east-1, wherever the distribution
# and the bucket live.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
      component   = "web"
      managedBy   = "terraform"
    }
  }
}
