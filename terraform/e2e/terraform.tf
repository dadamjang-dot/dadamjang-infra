terraform {
  required_version = ">= 1.10.0"

  backend "remote" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
