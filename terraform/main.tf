# Main Terraform configuration for testing Azure DevOps pipeline
# Following Terraform best practices

terraform {
  required_version = ">= 1.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.1"
    }
  }
}

# Generate a random string for testing
resource "random_string" "test" {
  length  = var.random_string_length
  special = false
  upper   = false

  # Use tags-like metadata for documentation
  lifecycle {
    create_before_destroy = true
  }
}

# Generate a random integer for testing
resource "random_integer" "test" {
  min = var.random_integer_min
  max = var.random_integer_max

  # Ensure integer changes when string changes
  keepers = {
    string_id = random_string.test.id
  }
}

# Generate a random ID for unique naming
resource "random_id" "test" {
  byte_length = 4
  prefix      = "${var.project_name}-${var.environment}-"

  # Keepers for dependencies
  keepers = {
    environment = var.environment
    project     = var.project_name
  }
}

# Local values for computed data
locals {
  # Common tags applied to all resources
  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    Workspace   = terraform.workspace
    Timestamp   = timestamp()
  })

  # Computed values
  resource_prefix = "${var.project_name}-${var.environment}"
  unique_suffix   = random_id.test.hex
}
