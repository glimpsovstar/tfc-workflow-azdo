# Testing Examples

This directory contains example pipelines for testing the HCP Terraform + Azure DevOps framework in a progressive manner.

## 🧪 Testing Progression

### **Step 1: Simple Test** (`simple-test.yml`)
**Purpose**: Verify basic Azure DevOps setup without HCP Terraform integration
**Time**: ~2 minutes
**Tests**:
- ✅ Azure DevOps pipeline execution
- ✅ Variable group access
- ✅ Repository structure validation
- ✅ Agent capabilities

**Run this first** to ensure your Azure DevOps environment is configured correctly.

### **Step 2: Connectivity Test** (`connectivity-test.yml`)
**Purpose**: Full HCP Terraform integration validation
**Time**: ~5 minutes
**Tests**:
- ✅ Docker functionality
- ✅ HashiCorp TFCI container access
- ✅ HCP Terraform API authentication
- ✅ Workspace access permissions
- ✅ Terraform configuration validation
- ✅ Configuration upload to HCP Terraform
- ✅ Speculative run creation

**Run this after** simple-test.yml passes successfully.

## 📋 How to Use These Tests

### **Prerequisites**
- [ ] Azure DevOps parallelism grant approved
- [ ] Variable group `terraform-variables` created with required variables
- [ ] HCP Terraform workspace configured with API-driven workflow
- [ ] Team permissions set up in HCP Terraform

### **Running the Tests**

#### **Option A: Copy to Repository Root (Recommended)**
```bash
# Copy test files to your repository root for easy access
cp examples/simple-test.yml .
cp examples/connectivity-test.yml .

git add simple-test.yml connectivity-test.yml
git commit -m "Add testing pipelines"
git push origin main
```

#### **Option B: Reference from Examples Directory**
```bash
# Create pipelines pointing to examples directory
# Azure DevOps → Pipelines → New pipeline → Existing YAML file
# Path: /examples/simple-test.yml
```

### **Test Execution Order**

#### **1. Run Simple Test**
- **Azure DevOps** → **Pipelines** → **New pipeline**
- **Existing Azure Pipelines YAML file** → `/simple-test.yml`
- **Save and run**
- **Expected result**: All steps pass, confirming basic setup

#### **2. Run Connectivity Test**
- **Only run after simple test passes**
- **Azure DevOps** → **Pipelines** → **New pipeline**
- **Existing Azure Pipelines YAML file** → `/connectivity-test.yml`
- **Save and run**
- **Expected result**: Full HCP Terraform integration working

## 🔍 Troubleshooting

### **Simple Test Failures**

| Issue | Likely Cause | Solution |
|-------|--------------|----------|
| Variable group not found | Variable group name mismatch | Ensure exact name: `terraform-variables` |
| TF_API_TOKEN empty | Variable not marked as secret | Check variable group configuration |
| Repository structure missing | Framework not imported correctly | Re-import from GitHub repository |

### **Connectivity Test Failures**

| Issue | Likely Cause | Solution |
|-------|--------------|----------|
| Docker pull fails | Network/firewall issues | Check Azure DevOps agent network access |
| HCP Terraform API 401 | Invalid API token | Regenerate token, update variable group |
| Workspace not found | Incorrect workspace name | Verify exact workspace name in HCP Terraform |
| Upload fails | Insufficient permissions | Check team permissions in workspace |

## ✅ Success Criteria

### **Simple Test Success**
```
✅ Azure DevOps pipeline execution: SUCCESS
✅ Variable group access: SUCCESS  
✅ Repository structure: SUCCESS
🚀 Ready for HCP Terraform connectivity testing!
```

### **Connectivity Test Success**
```
✅ Docker functionality: WORKING
✅ TFCI container: WORKING
✅ HCP Terraform API: CONNECTED
✅ Workspace access: CONFIRMED
✅ Terraform validation: PASSED
✅ Configuration upload: SUCCESSFUL
✅ Speculative run: CREATED
🚀 Your environment is ready for full CI/CD pipeline testing!
```

## 🚀 After Tests Pass

Once both tests are successful, you're ready to:

1. **Copy pipeline templates** to repository root:
   ```bash
   cp pipeline-templates/hcp-terraform.speculative-run.yml azure-pipelines-pr.yml
   cp pipeline-templates/hcp-terraform.apply-run.yml azure-pipelines-main.yml
   ```

2. **Set up PR pipeline** with pull request triggers

3. **Set up main branch pipeline** with deployment to production environment

4. **Test complete workflow** by creating a PR with Terraform changes

## 📞 Need Help?

If tests fail or you encounter issues:

1. **Check the troubleshooting table** above
2. **Review pipeline logs** for specific error messages
3. **Verify prerequisites** are correctly configured
4. **Contact HashiCorp support** with specific error details

These test files are designed to catch configuration issues early and provide clear feedback on what needs to be fixed.
