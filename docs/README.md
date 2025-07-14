# HCP Terraform Azure DevOps Workflows

This repository provides Azure DevOps pipeline templates for integrating with HCP Terraform, serving as the Azure DevOps equivalent of [hashicorp/tfc-workflows-github](https://github.com/hashicorp/tfc-workflows-github).

## Repository Structure

```
├── pipeline-templates/          # Starter pipeline templates
│   ├── hcp-terraform.speculative-run.yml    # PR pipeline template
│   └── hcp-terraform.apply-run.yml          # Main branch pipeline template
├── tasks/                      # Reusable task templates
│   ├── display-info.yml        # Display pipeline information
│   ├── upload-configuration.yml # Upload Terraform config to HCP Terraform
│   ├── create-run.yml          # Create a run in HCP Terraform
│   ├── plan-output.yml         # Get plan output
│   ├── wait-for-plan.yml       # Wait for plan completion
│   ├── apply-run.yml           # Apply a run
│   ├── wait-for-apply.yml      # Wait for apply completion
│   └── run-summary.yml         # Display run summary
├── examples/                   # Example configurations
└── docs/                      # Documentation
    └── setup-guide.md         # Detailed setup instructions
```

## Quick Start

1. **Copy Pipeline Templates**: Copy the desired pipeline template from `pipeline-templates/` to your repository
2. **Set Up Variables**: Create a variable group named `terraform-variables` in Azure DevOps
3. **Configure HCP Terraform**: Set up your workspace and API token
4. **Test**: Create a PR to test the speculative run pipeline

## Available Pipeline Templates

### Speculative Run Pipeline (`hcp-terraform.speculative-run.yml`)
- Triggers on Pull Requests
- Performs plan-only runs in HCP Terraform
- Provides plan output for review
- Equivalent to GitHub Actions speculative run workflow

### Apply Run Pipeline (`hcp-terraform.apply-run.yml`)
- Triggers on pushes to main branch
- Performs plan and apply in HCP Terraform
- Uses deployment environments for additional security
- Equivalent to GitHub Actions apply run workflow

## Task Templates

The `tasks/` directory contains reusable task templates that mirror the functionality of the GitHub Actions in the original repository:

- **upload-configuration**: Equivalent to `hashicorp/tfc-workflows-github/actions/upload-configuration`
- **create-run**: Equivalent to `hashicorp/tfc-workflows-github/actions/create-run`
- **apply-run**: Equivalent to `hashicorp/tfc-workflows-github/actions/apply-run`
- **plan-output**: Equivalent to `hashicorp/tfc-workflows-github/actions/plan-output`

## Documentation

- [Setup Guide](setup-guide.md) - Complete setup instructions
- [Migration Guide](migration-guide.md) - Migrating from GitHub Actions
- [Troubleshooting](troubleshooting.md) - Common issues and solutions

## Comparison with GitHub Actions

| GitHub Actions | Azure DevOps Equivalent |
|----------------|-------------------------|
| `workflow-templates/` | `pipeline-templates/` |
| `actions/` | `tasks/` |
| Custom GitHub Actions | Docker container tasks |
| Workflow files | Pipeline YAML files |
| `secrets.VARIABLE` | `$(VARIABLE)` |
| `env:` | `variables:` |

## Requirements

- Azure DevOps project with pipeline permissions
- HCP Terraform account with API token
- Docker Hub service connection (for public HashiCorp images)
- Variable group configured with required secrets

## Contributing

1. Fork this repository
2. Create a feature branch
3. Test your changes
4. Submit a pull request

This project follows the same patterns and best practices as HashiCorp's official GitHub Actions workflows, adapted for Azure DevOps.
