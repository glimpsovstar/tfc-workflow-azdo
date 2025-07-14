# Simple Terraform configuration for testing Azure DevOps pipeline
terraform {
  required_version = ">= 1.0"
  
  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Simple random string resource for testing
resource "random_string" "test" {
  length  = 8
  special = false
  upper   = false
}

resource "random_integer" "test" {
  min = 1
  max = 100
}
