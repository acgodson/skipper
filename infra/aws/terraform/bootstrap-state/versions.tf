terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Local state, and it stays local. This module exists because a configuration cannot
  # create the bucket it stores its own state in, so something has to hold the first
  # turtle. What it creates is three resources that are named, not discovered: if this
  # state file is lost, `terraform import` recovers it from the bucket name, the table
  # name and the key alias. It holds no secret — that is the whole point of the split.
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
