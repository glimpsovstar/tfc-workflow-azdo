# Test Terraform Configuration

This directory contains a simple Terraform configuration for testing the Azure DevOps pipeline with HCP Terraform.

## Overview

This configuration creates simple random resources to validate the pipeline functionality without incurring any cloud costs.

## Resources Created

- `random_string.test` - A random string for testing
- `random_integer.test` - A random integer for testing  
- `random_id.test` - A random ID with prefix for unique naming

## Variables

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| environment | Environment name for resource tagging | string | "test" | no |
| project_name | Name of the project | string | "tfc-azdo-test" | no |
| random_string_length | Length of random string | number | 8 | no |
| random_integer_min | Minimum random integer | number | 1 | no |
| random_integer_max | Maximum random integer | number | 100 | no |
| tags | Common tags for resources | map(string) | see variables.tf | no |

## Usage

This configuration is designed to work with the Azure DevOps pipeline templates in this repository.

## Local Testing

```bash
# Format code
terraform fmt

# Validate configuration
terraform init
terraform validate

# Plan changes
terraform plan
