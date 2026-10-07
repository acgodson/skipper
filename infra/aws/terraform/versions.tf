terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # TODO: move state to S3 with DynamoDB locking the day a second person can deploy.
  # Local state is correct for exactly one operator: it cannot be locked, it cannot be
  # read by anyone else, and a lost laptop loses the only copy. See README "State".
  backend "local" {
    path = "terraform.tfstate"
  }
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
