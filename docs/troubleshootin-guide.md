# Troubleshooting Guide

Common issues and solutions when using HCP Terraform with Azure DevOps pipelines.

## Pipeline Issues

### Pipeline Not Triggering

**Symptoms:**
- Pipeline doesn't run on PR creation
- No pipeline execution on main branch push

**Solutions:**

1. **Check Trigger Configuration**
   ```yaml
   # Ensure paths match your repository structure
   trigger:
     branches:
       include: [main]
     paths:
       include: 
         - terraform/**
         - '**/*.tf'  # Include all .tf files
   ```

2. **Verify Branch Policies**
   - Check if branch policies require specific conditions
   - Ensure pipeline is not disabled in branch policies

3. **Check Permissions**
   - Verify build service has repository permissions
   - Ensure pipeline YAML file is in correct location

### YAML Syntax Errors

**Common Issues:**

1. **Indentation Problems**
   ```yaml
   # Wrong - inconsistent indentation
   steps:
     - script: echo "test"
       displayName: Test
   
   # Correct - consistent 2-space indentation
   steps:
     - script: echo "test"
       displayName: 'Test'
   ```

2. **Parameter Type Mismatches**
   ```yaml
   # Wrong - boolean as string
   parameters:
     speculative: "true"
   
   # Correct - boolean as boolean
   parameters:
     speculative: true
   ```

3. **Missing Required Fields**
   ```yaml
   # Wrong - missing displayName
   - script: echo "test"
   
   # Correct - includes displayName
   - script: echo "test"
     displayName: 'Test Script'
   ```

## Variable and Secret Issues

### Variable Group Not Found

**Error Message:**
```
Variable group 'terraform-variables' could not be found
```

**Solutions:**

1. **Create Variable Group**
   - Navigate to Pipelines → Library
   - Create group named exactly `terraform-variables`
   - Ensure proper permissions

2. **Check Variable Group Permissions**
   - Verify pipeline has access to variable group
   - Add project to variable group permissions

3. **Verify Variable Group Link**
   ```yaml
   variables:
     - group: 'terraform-variables'  # Exact name match required
   ```

### Secret Variable Issues

**Symptoms:**
- `TF_API_TOKEN` not found or empty
- Authentication failures with HCP Terraform

**Solutions:**

1. **Verify Secret Configuration**
   - Check variable is marked as secret
   - Ensure no extra spaces in variable name
   - Verify token is valid and not expired

2. **Check Token Permissions**
   - Verify token has workspace access
   - Ensure token belongs to correct organization
   - Test token manually with tfci tool

3. **Debug Token Access**
   ```yaml
   - script: |
       # Don't output the actual token!
       if [ -z "$(TF_API_TOKEN)" ]; then
         echo "TF_API_TOKEN is empty"
       else
         echo "TF_API_TOKEN is set (length: ${#TF_API_TOKEN})"
       fi
     env:
       TF_API_TOKEN: $(TF_API_TOKEN)
   ```

## Docker and Container Issues

### Docker Service Connection Issues

**Error Messages:**
- `Service connection 'dockerhub' could not be found`
- `Docker login failed`

**Solutions:**

1. **Create Docker Service Connection**
   - Project Settings → Service connections
   - New service connection → Docker Registry
   - Choose Docker Hub, name it `dockerhub`

2. **For Public Images (Recommended)**
   - Leave authentication empty for public HashiCorp images
   - No credentials needed for `hashicorp/tfci:latest`

3. **Verify Service Connection**
   ```yaml
   - task: Docker@2
     inputs:
       containerRegistry: 'dockerhub'
       command: 'run'
       arguments: 'hello-world'
   ```

### Container Execution Issues

**Error Messages:**
- `docker: command not found`
- Container fails to start

**Solutions:**

1. **Use Script Task Instead of Docker Task**
   ```yaml
   # Use this approach
   - script: |
       docker run --rm hashicorp/tfci:latest tfci --version
     displayName: 'Test Docker'
   ```

2. **Check Agent Capabilities**
   - Verify agent pool has Docker capability
   - Use Microsoft-hosted agents (recommended)

3. **Container Resource Issues**
   ```yaml
   # Add resource limits if needed
   - script: |
       docker run --rm \
         --memory=1g \
         --cpus=1 \
         hashicorp/tfci:latest tfci --version
   ```

## HCP Terraform API Issues

### Authentication Failures

**Error Messages:**
- `401 Unauthorized`
- `Invalid API Token`

**Solutions:**

1. **Verify Token Format**
   ```bash
   # Token should start with specific prefix
   # User tokens: start with "..."
   # Team tokens: start with "..."
   # Check HCP Terraform documentation for current format
   ```

2. **Test Token Manually**
   ```bash
   curl -H "Authorization: Bearer $TF_API_TOKEN" \
        https://app.terraform.io/api/v2/account/details
   ```

3. **Check Token Scope**
   - Ensure token has workspace access
   - Verify organization membership
   - Check token expiration

### Workspace Issues

**Error Messages:**
- `Workspace not found`
- `Access denied to workspace`

**Solutions:**

1. **Verify Workspace Configuration**
   ```yaml
   variables:
     - name: TF_WORKSPACE
       value: 'exact-workspace-name'  # Case sensitive
     - name: TF_CLOUD_ORGANIZATION
       value: 'exact-org-name'       # Case sensitive
   ```

2. **Check Workspace Type**
   - Ensure workspace is configured for API-driven workflow
   - CLI-driven workflows won't work with these pipelines

3. **Verify Organization Access**
   - Check user/token has organization access
   - Verify workspace permissions

### Upload and Run Issues

**Error Messages:**
- `Configuration upload failed`
- `Run creation failed`

**Solutions:**

1. **Check Directory Structure**
   ```yaml
   # Ensure CONFIG_DIRECTORY points to correct location
   - name: CONFIG_DIRECTORY
     value: 'terraform'  # Directory containing .tf files
   ```

2. **Verify File Permissions**
   ```yaml
   - script: |
       ls -la $(Build.SourcesDirectory)/$(CONFIG_DIRECTORY)
       echo "Checking .tf files:"
       find $(Build.SourcesDirectory)/$(CONFIG_DIRECTORY) -name "*.tf"
   ```

3. **Volume Mount Issues**
   ```yaml
   # Ensure proper volume mounting
   -v "$(Build.SourcesDirectory)/$(CONFIG_DIRECTORY):/tfci/workspace"
   ```

## Performance Issues

### Slow Pipeline Execution

**Symptoms:**
- Pipelines take longer than expected
- Timeouts during operations

**Solutions:**

1. **Optimize Docker Image Pulling**
   ```yaml
   # Pull image once per pipeline
   - script: docker pull hashicorp/tfci:latest
     displayName: 'Pull Docker Image'
   ```

2. **Adjust Timeouts**
   ```yaml
   variables:
     - name: TF_MAX_TIMEOUT
       value: '45m'  # Increase from default 30m
   ```

3. **Use Parallel Jobs**
   ```yaml
   # For multiple workspaces
   strategy:
     parallel: 3
     matrix:
       workspace1: { TF_WORKSPACE: 'ws1' }
       workspace2: { TF_WORKSPACE: 'ws2' }
       workspace3: { TF_WORKSPACE: 'ws3' }
   ```

### Memory Issues

**Error Messages:**
- `Out of memory`
- Container killed

**Solutions:**

1. **Increase Agent Resources**
   ```yaml
   pool:
     vmImage: 'ubuntu-latest'
     # Consider using self-hosted agents for large configs
   ```

2. **Optimize Terraform Configuration**
   - Reduce number of resources per plan
   - Use smaller state files
   - Consider workspace splitting

## Debugging Techniques

### Enable Debug Logging

```yaml
variables:
  - name: TF_LOG
    value: 'DEBUG'  # Enable verbose logging
```

### Capture Detailed Output

```yaml
- script: |
    set -x  # Enable bash debugging
    docker run --rm \
      -e "TF_LOG=DEBUG" \
      -e "TF_API_TOKEN=$(TF_API_TOKEN)" \
      -e "TF_CLOUD_ORGANIZATION=$(TF_CLOUD_ORGANIZATION)" \
      hashicorp/tfci:latest \
      tfci run show --run="$RUN_ID" --format=json | jq '.'
  displayName: 'Debug Run Details'
```

### Test Components Individually

```yaml
# Test authentication
- script: |
    docker run --rm \
      -e "TF_API_TOKEN=$(TF_API_TOKEN)" \
      -e "TF_CLOUD_ORGANIZATION=$(TF_CLOUD_ORGANIZATION)" \
      hashicorp/tfci:latest \
      tfci workspace list
  displayName: 'Test Authentication'

# Test file access
- script: |
    ls -la $(Build.SourcesDirectory)/$(CONFIG_DIRECTORY)
    cat $(Build.SourcesDirectory)/$(CONFIG_DIRECTORY)/*.tf
  displayName: 'Test File Access'
```

## Getting Additional Help

### Log Analysis

1. **Pipeline Logs**
   - Check each step's output
   - Look for error messages and stack traces
   - Note timing of failures

2. **HCP Terraform Logs**
   - Check workspace run logs
   - Review plan and apply output
   - Verify resource creation/updates

3. **Azure DevOps Diagnostics**
   - Enable system diagnostics
   - Check agent capabilities
   - Review service connection logs

### Resources

1. **HCP Terraform Documentation**
   - API documentation
   - Workspace configuration guides
   - Troubleshooting guides

2. **Azure DevOps Documentation**
   - Pipeline YAML schema
   - Variable group configuration
   - Service connection setup

3. **Community Support**
   - HashiCorp Community Forum
   - Azure DevOps Community
   - Stack Overflow tags: `terraform`, `azure-devops`

### Creating Support Cases

When creating support requests, include:

1. **Pipeline YAML** (with secrets redacted)
2. **Error messages** (complete stack traces)
3. **Pipeline logs** (relevant sections)
4. **HCP Terraform workspace details**
5. **Steps to reproduce** the issue

### Prevention

1. **Test in Non-Production**
   - Use test workspaces
   - Validate with simple configurations
   - Test all pipeline variations

2. **Monitor Regularly**
   - Set up pipeline failure notifications
   - Monitor HCP Terraform workspace health
   - Track performance metrics

3. **Keep Updated**
   - Update pipeline templates regularly
   - Monitor HashiCorp tfci image updates
   - Stay current with Azure DevOps features

---

Most issues can be resolved by carefully checking configuration, permissions, and following the debugging techniques outlined above. Start with the most common issues and work systematically through the troubleshooting steps.
