# Outputs for the test Terraform configuration

output "random_string_value" {
  description = "The generated random string"
  value       = random_string.test.result
}

output "random_integer_value" {
  description = "The generated random integer"
  value       = random_integer.test.result
}

output "test_message" {
  description = "Test message confirming pipeline execution"
  value       = "Azure DevOps pipeline successfully executed for ${var.project_name} in ${var.environment} environment"
}
