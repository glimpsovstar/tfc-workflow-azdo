# Variables for the test Terraform configuration
# Following best practices with proper descriptions

variable "environment" {
  description = "Environment name for resource tagging and naming"
  type        = string
  default     = "test"

  validation {
    condition     = contains(["dev", "test", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, test, staging, prod."
  }
}

variable "project_name" {
  description = "Name of the project for resource naming and tagging"
  type        = string
  default     = "tfc-azdo-test"

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.project_name))
    error_message = "Project name must contain only alphanumeric characters and hyphens."
  }
}

variable "random_string_length" {
  description = "Length of the random string to generate"
  type        = number
  default     = 8

  validation {
    condition     = var.random_string_length >= 4 && var.random_string_length <= 32
    error_message = "Random string length must be between 4 and 32 characters."
  }
}

variable "random_integer_min" {
  description = "Minimum value for the random integer"
  type        = number
  default     = 1
}

variable "random_integer_max" {
  description = "Maximum value for the random integer"
  type        = number
  default     = 100

  validation {
    condition     = var.random_integer_max > var.random_integer_min
    error_message = "Maximum value must be greater than minimum value."
  }
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default = {
    ManagedBy = "Terraform"
    Source    = "Azure-DevOps"
  }
}
