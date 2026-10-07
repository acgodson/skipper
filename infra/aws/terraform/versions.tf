terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # State is remote and encrypted before anything is applied, because this state holds
  # secrets: aws_cognito_identity_provider takes the Apple .p8 and the Google client
  # secret as literal arguments, so the first apply with enable_social_idp on writes both
  # into state in the clear.
  #
  # A partial configuration: a backend block cannot interpolate, and the bucket name and
  # the key ARN both carry the account id, which is not hardcoded anywhere in this repo.
  # The rest comes from backend.hcl, which bootstrap-state prints —
  # infra/aws/README.md "State" has the exact two-step first run.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
      managedBy   = "terraform"
    }
  }
}

# Route 53 health-check metrics are published only in us-east-1, so the alarm that
# watches them has to be created there.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      project     = var.project
      environment = var.environment
      managedBy   = "terraform"
    }
  }
}
