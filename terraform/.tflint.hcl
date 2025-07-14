TFLint configuration for Terraform best practices
plugin "terraform" {
enabled = true
preset  = "recommended"
}
rule "terraform_required_version" {
enabled = true
}
rule "terraform_required_providers" {
enabled = true
}
rule "terraform_naming_convention" {
enabled = true
format  = "snake_case"
}
rule "terraform_typed_variables" {
enabled = true
}
rule "terraform_unused_declarations" {
enabled = true
}
rule "terraform_documented_outputs" {
enabled = true
}
rule "terraform_documented_variables" {
enabled = true
}
