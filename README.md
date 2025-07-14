# HCP Terraform Azure DevOps Workflows

> **Azure DevOps equivalent of [hashicorp/tfc-workflows-github](https://github.com/hashicorp/tfc-workflows-github)**

This repository provides Azure DevOps pipeline templates and reusable tasks for integrating with HCP Terraform (formerly Terraform Cloud). These templates implement the same best practices as HashiCorp's GitHub Actions workflows, adapted for Azure DevOps.

## 🚀 Quick Start

1. **Copy a pipeline template** from `pipeline-templates/` to your repository
2. **Create variable group** `terraform-variables` in Azure DevOps Library  
3. **Set up HCP Terraform** workspace with API token
4. **Test** by creating a Pull Request

## 📁 Repository Structure

```
├── pipeline-templates/          # 📋 Starter pipeline templates
│   ├── hcp-terraform.speculative-run.yml    # PR pipeline
│   └── hcp-terraform.apply-run.yml          # Main branch pipeline
├── tasks/                      # 🔧 Reusable task templates  
│   ├── upload-configuration.yml # Upload config to HCP Terraform
│   ├── create-run.yml          # Create runs
│   ├── apply-run.yml           # Apply runs
│   └── ...                     # Other task templates
├── terraform/                  # 🧪 Example Terraform configuration
├── examples/                   # 📚 Example setups
└── docs/                       # 📖 Documentation
```

## 🔄 Available Pipeline Templates

### Speculative Run (Pull Request)
**File**: `pipeline-templates/hcp-terraform.speculative-run.yml`
- ✅ Triggers on Pull Requests
- ✅ Plan-only runs (no apply)
- ✅ Shows proposed changes for review
- ✅ Comments results (when configured)

### Apply Run (Main Branch)  
**File**: `pipeline-templates/hcp-terraform.apply-run.yml`
- ✅ Triggers on main branch pushes
- ✅ Plan and apply infrastructure changes
- ✅ Uses deployment environments for approvals
- ✅ Automatic rollback on failures

## 🔧 Task Templates

Reusable tasks that mirror HashiCorp's GitHub Actions:

| Azure DevOps Task | GitHub Action Equivalent |
|-------------------|-------------------------|
| `tasks/upload-configuration.yml` | `hashicorp/tfc-workflows-github/actions/upload-configuration` |
| `tasks/create-run.yml` | `hashicorp/tfc-workflows-github/actions/create-run` |
| `tasks/apply-run.yml` | `hashicorp/tfc-workflows-github/actions/apply-run` |
| `tasks/plan-output.yml` | `hashicorp/tfc-workflows-github/actions/plan-output` |

## ⚙️ Setup Requirements

1. **Variable Group**: Create `terraform-variables` in Azure DevOps Library
   - `TF_API_TOKEN` (secret) - HCP Terraform API token
   - `TF_CLOUD_ORGANIZATION` - Your organization name  
   - `TF_WORKSPACE` - Target workspace name
   - `CONFIG_DIRECTORY` - Terraform config directory

2. **Service Connection**: Docker Hub connection named `dockerhub`

3. **Environment**: Create `production` environment for apply approvals

## 📖 Documentation

- [📋 Setup Guide](docs/setup-guide.md) - Complete configuration walkthrough
- [🔀 Migration Guide](docs/migration-guide.md) - Moving from GitHub Actions  
- [🐛 Troubleshooting](docs/troubleshooting.md) - Common issues and solutions
- [📚 Examples](examples/) - Example configurations and setups

## 🔄 GitHub Actions Comparison

| Concept | GitHub Actions | Azure DevOps |
|---------|----------------|---------------|
| **Workflows** | `.github/workflows/` | `pipeline-templates/` |
| **Actions** | `actions/` | `tasks/` |
| **Secrets** | `${{ secrets.NAME }}` | `$(NAME)` |
| **Variables** | `env:` | `variables:` |
| **Triggers** | `on:` | `trigger:` / `pr:` |

## 🧪 Testing

This repository includes a simple Terraform configuration for testing:
- Random string and integer resources
- No real infrastructure costs
- Perfect for validating your pipeline setup

## 🤝 Contributing

1. Fork this repository
2. Create a feature branch  
3. Test your changes with the example configuration
4. Submit a pull request

## 📄 License

MIT License - see [LICENSE](LICENSE) file for details.

---

**Built with ❤️ for the Azure DevOps and Terraform community**

> Based on HashiCorp's excellent [tfc-workflows-github](https://github.com/hashicorp/tfc-workflows-github) repository
