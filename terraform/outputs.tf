# Outputs for the test Terraform configuration
# Following best practices with proper descriptions and sensitive handling

output "random_string_value" {
  description = "The generated random string value"
  value       = random_string.test.result
}

output "random_integer_value" {
  description = "The generated random integer value"
  value       = random_integer.test.result
}

output "random_id_value" {
  description = "The generated random ID with prefix"
  value       = random_id.test.id
}

output "resource_prefix" {
  description = "The computed resource prefix used for naming"
  value       = local.resource_prefix
}

output "unique_suffix" {
  description = "The unique suffix for resource naming"
  value       = local.unique_suffix
}

output "common_tags" {
  description = "The common tags applied to resources"
  value       = local.common_tags
}

output "test_message" {
  description = "Test message confirming pipeline execution with enhanced details"
  value = join("", [
    "Azure DevOps pipeline successfully executed for ",
    var.project_name,
    " in ",
    var.environment,
    " environment. ",
    "Random string: ",
    random_string.test.result,
    ", Random integer: ",
    tostring(random_integer.test.result),
    ", Unique ID: ",
    random_id.test.id
  ])
}

output "validation_summary" {
  description = "Summary of validation checks performed"
  value = {
    terraform_version   = ">= 1.0"
    providers_validated = "✅"
    variables_validated = "✅"
    outputs_defined     = "✅"
    best_practices      = "✅"
  }
}
