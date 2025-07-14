# Azure DevOps Setup Guide for HCP Terraform Workflows

> **Repository**: https://github.com/glimpsovstar/tfc-workflow-azdo

## Prerequisites

1. **HCP Terraform Account**: You need an active HCP Terraform (formerly Terraform Cloud) account
2. **Azure DevOps Project**: A project where you'll create the pipelines
3. **Terraform Configuration**: Your Terraform code in a repository

## Setup Steps

### 1. Create Variable Group in Azure DevOps

1. Go to your Azure DevOps project
2. Navigate to **Pipelines** > **Library**
3. Click **+ Variable group**
4. Name it `terraform-variables`
5. Add the following variables:

   | Variable Name | Value | Secret |
   |---------------|-------|--------|
   | `TF_API_TOKEN` | Your HCP Terraform API token | ✅ Yes |
   | `TF_CLOUD_ORGANIZATION` | Your HCP Terraform organization name | ❌ No |
   | `TF_WORKSPACE` | Your HCP Terraform workspace name | ❌ No |
   | `CONFIG_DIRECTORY` | Directory containing Terraform files (e.g., `terraform`) | ❌ No |

### 2. Create Docker Hub Service Connection

1. Go to **Project Settings** > **Service connections**
2. Click **New service connection**
3. Select **Docker Registry**
4. Choose **Docker Hub**
5. Name it `dockerhub`
6. Use your Docker Hub credentials (or leave empty for public images)

### 3. Create Environment for Production Deployments

1. Go to **Pipelines** > **Environments**
2. Click **New environment**
3. Name it `production`
4. Add any required approvals/checks for production deployments

### 4. Get Your HCP Terraform API Token

1. Log into HCP Terraform
2. Go to **User Settings** > **Tokens**
3. Click **Create an API token**
4. Copy the token and add it to your variable group as `TF_API_TOKEN`

### 5. Set Up Your Terraform Workspace

1. Create a workspace in HCP Terraform
2. Configure it for **API-driven workflow**
3. Set up any required variables in the workspace
4. Note the workspace name for your pipeline variables

## Testing Your Setup

1. **Commit and push** your changes
2. **Create a feature branch** and make changes to terraform files
3. **Create a Pull Request** to test the speculative run pipeline
4. **Merge to main** to test the apply pipeline

## Troubleshooting

- Enable debug logging by setting `TF_LOG: DEBUG` 
- Check HCP Terraform workspace for run details
- Verify all variables are correctly set in the variable group
- Ensure Docker Hub service connection is working
