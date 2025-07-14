# Migration Guide: GitHub Actions to Azure DevOps

This guide helps you migrate from HashiCorp's GitHub Actions workflows to Azure DevOps pipelines.

## Repository Structure Mapping

| GitHub Actions | Azure DevOps | Purpose |
|----------------|---------------|---------|
| `.github/workflows/` | `pipeline-templates/` | Workflow/pipeline definitions |
| `actions/` | `tasks/` | Reusable components |
| Individual action files | Task template YAML files | Modular functionality |

## Syntax Differences

### Triggers

**GitHub Actions:**
```yaml
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
```

**Azure DevOps:**
```yaml
trigger:
  branches:
    include: [main]
pr:
  branches:
    include: [main]
```

### Variables and Secrets

**GitHub Actions:**
```yaml
env:
  TF_API_TOKEN: ${{ secrets.TF_API_TOKEN }}
  TF_WORKSPACE: "my-workspace"
```

**Azure DevOps:**
```yaml
variables:
  - group: 'terraform-variables'
  - name: TF_WORKSPACE
    value: 'my-workspace'
# TF_API_TOKEN accessed as $(TF_API_TOKEN)
```

### Job Structure

**GitHub Actions:**
```yaml
jobs:
  terraform:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: hashicorp/tfc-workflows-github/actions/upload-configuration@v1.3.2
```

**Azure DevOps:**
```yaml
stages:
  - stage: Terraform
    jobs:
      - job: TerraformJob
        pool:
          vmImage: 'ubuntu-latest'
        steps:
          - checkout: self
          - template: tasks/upload-configuration.yml
```

## Action to Task Mapping

### upload-configuration

**GitHub Actions:**
```yaml
- uses: hashicorp/tfc-workflows-github/actions/upload-configuration@v1.3.2
  id: upload
  with:
    workspace: ${{ env.TF_WORKSPACE }}
    directory: ${{ env.CONFIG_DIRECTORY }}
    speculative: true
```

**Azure DevOps:**
```yaml
- template: tasks/upload-configuration.yml
  parameters:
    speculative: true
```

### create-run

**GitHub Actions:**
```yaml
- uses: hashicorp/tfc-workflows-github/actions/create-run@v1.3.2
  id: run
  with:
    workspace: ${{ env.TF_WORKSPACE }}
    configuration_version: ${{ steps.upload.outputs.configuration_version_id }}
    plan_only: true
```

**Azure DevOps:**
```yaml
- template: tasks/create-run.yml
  parameters:
    planOnly: true
    message: 'Run from Azure DevOps'
```

### apply-run

**GitHub Actions:**
```yaml
- uses: hashicorp/tfc-workflows-github/actions/apply-run@v1.3.2
  id: apply
  with:
    run: ${{ steps.run.outputs.run_id }}
    comment: "Applied from GitHub Actions"
```

**Azure DevOps:**
```yaml
- template: tasks/apply-run.yml
  parameters:
    runId: $(create_run.RUN_ID)
    comment: 'Applied from Azure DevOps'
```

## Migration Steps

### 1. Repository Setup

1. **Create new repository** or clean existing one
2. **Run the restructure script** to create the proper directory structure
3. **Copy your Terraform configuration** to the `terraform/` directory

### 2. Pipeline Migration

1. **Choose template**: Copy the appropriate pipeline template
   - `hcp-terraform.speculative-run.yml` for PR workflows
   - `hcp-terraform.apply-run.yml` for main branch workflows

2. **Update variables**: Replace GitHub secrets with Azure DevOps variable groups

3. **Customize paths**: Update trigger paths to match your repository structure

### 3. Variable Configuration

**Create Variable Group in Azure DevOps:**

1. Navigate to **Pipelines** → **Library**
2. Create group named `terraform-variables`
3. Add these variables:

| Variable | Type | GitHub Equivalent |
|----------|------|-------------------|
| `TF_API_TOKEN` | Secret | `secrets.TF_API_TOKEN` |
| `TF_CLOUD_ORGANIZATION` | Variable | `env.TF_CLOUD_ORGANIZATION` |
| `TF_WORKSPACE` | Variable | `env.TF_WORKSPACE` |
| `CONFIG_DIRECTORY` | Variable | `env.CONFIG_DIRECTORY` |

### 4. Service Connections

Create Docker Hub service connection for accessing HashiCorp's tfci container:

1. **Project Settings** → **Service connections**
2. **New service connection** → **Docker Registry**
3. **Docker Hub** → Name: `dockerhub`

### 5. Environment Setup

For apply pipelines, create production environment:

1. **Pipelines** → **Environments**
2. **New environment** → Name: `production`
3. Configure approval gates as needed

## Feature Comparison

| Feature | GitHub Actions | Azure DevOps | Notes |
|---------|----------------|---------------|-------|
| **Conditional execution** | `if:` conditions | `condition:` expressions | Similar functionality |
| **Output variables** | `outputs:` | `isOutput=true` | Different syntax |
| **Matrix builds** | `strategy.matrix` | `strategy.matrix` | Nearly identical |
| **Environments** | GitHub Environments | Azure DevOps Environments | Similar approval gates |
| **Secrets** | Repository/Organization secrets | Variable groups | Centralized in Azure DevOps |

## Common Migration Issues

### 1. Output Variables

**GitHub Actions:**
```yaml
- id: upload
  # outputs available as steps.upload.outputs.configuration_version_id
```

**Azure DevOps:**
```yaml
- name: upload
  script: |
    echo "##vso[task.setvariable variable=CONFIG_VERSION;isOutput=true]$VERSION"
  # accessed as $(upload.CONFIG_VERSION)
```

### 2. Conditional Execution

**GitHub Actions:**
```yaml
if: github.event_name == 'pull_request'
```

**Azure DevOps:**
```yaml
condition: eq(variables['Build.Reason'], 'PullRequest')
```

### 3. File Paths

**GitHub Actions:**
```yaml
working-directory: ${{ github.workspace }}
```

**Azure DevOps:**
```yaml
workingDirectory: $(Build.SourcesDirectory)
```

## Testing Your Migration

### 1. Validate Pipeline Syntax
- Create PR with pipeline changes
- Check for YAML syntax errors
- Verify variable group access

### 2. Test Speculative Run
- Create feature branch with Terraform changes
- Open Pull Request
- Verify plan runs successfully

### 3. Test Apply Run
- Merge PR to main branch
- Verify apply pipeline executes
- Check HCP Terraform workspace

## Best Practices

### 1. Use Templates
- Leverage the task templates for consistency
- Customize parameters rather than copying code
- Keep templates in separate repository for reuse

### 2. Variable Management
- Use variable groups for secrets
- Environment-specific variable groups
- Avoid hardcoding values in pipelines

### 3. Security
- Enable branch protection policies
- Require PR reviews
- Use deployment environments for production

### 4. Monitoring
- Enable pipeline notifications
- Monitor HCP Terraform workspace
- Set up alerts for failed runs

## Troubleshooting

### Pipeline Not Triggering
- Check trigger paths in YAML
- Verify branch protection policies
- Ensure proper permissions

### Variable Group Access
- Verify variable group permissions
- Check variable group linking
- Confirm variable names match

### Docker Issues
- Verify Docker Hub service connection
- Check container permissions
- Ensure jq is available in pipeline

## Advanced Features

### Multiple Workspaces
Use matrix strategy for multiple environments:

```yaml
strategy:
  matrix:
    dev:
      TF_WORKSPACE: 'myapp-dev'
      ENVIRONMENT: 'development'
    prod:
      TF_WORKSPACE: 'myapp-prod'
      ENVIRONMENT: 'production'
```

### Custom Docker Images
For Enterprise Terraform or custom certificates:

```yaml
variables:
  - name: DOCKER_IMAGE
    value: 'your-registry/custom-tfci:latest'
```

## Getting Help

1. **Check documentation** in the `docs/` directory
2. **Review examples** in the `examples/` directory
3. **Compare with GitHub Actions** using the original repository
4. **Test incrementally** - start with simple configurations

---

Successfully migrating from GitHub Actions to Azure DevOps requires understanding the syntax differences and properly configuring the Azure DevOps environment. This guide provides the foundation for a smooth transition while maintaining the same functionality and best practices.
