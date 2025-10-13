Pipelines
---------

This repo provides multiple deployment approaches for different use cases:

## 1. Application-Specific Deployment (Recommended)

For applications that need full control over their deployment process, use the **deploy.yml approach** where each application manages its own build and deployment logic.

### Features
- **Self-contained**: Each application controls its build and deployment process
- **Highly flexible**: Easy to customize per application requirements
- **Comprehensive logging**: Detailed colored output and error handling
- **Security scanning**: Built-in Trivy filesystem and image scanning
- **Multi-environment support**: Configurable for different deployment scenarios
- **Database automation**: Automatic setup and configuration

### Setup Requirements
Each application needs:
- `.github/workflows/deploy.yml` - Complete CI/CD pipeline with build and deployment logic
- `kubeSecrets/devENV.yaml` - Kubernetes secrets configuration

### Example Application Structure
```
your-app/
├── .github/workflows/
│   └── deploy.yml             # Complete build and deployment pipeline
├── kubeSecrets/
│   └── devENV.yaml            # Dynamic secrets (no hardcoded values)
└── Dockerfile
```

### Deployment Flow
1. **Build Phase**: Security scanning, Docker build with SSH support, container vulnerability scanning
2. **Deploy Phase**: Calls reusable workflow for shared deployment logic (database setup, Helm updates, etc.)
3. **Post-Deploy**: Database migrations (for applicable apps)

### Example Workflow Structure
```yaml
# .github/workflows/deploy.yml
name: Build and Deploy MyApp

on:
  push:
    branches: [ main, master ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - name: Checkout code
      uses: actions/checkout@v4
    - name: Trivy FS scan
      uses: aquasecurity/trivy-action@0.24.0
      with:
        scan-type: fs
        exit-code: '0'
    - name: Build and scan image
      # Build logic here
    - name: Push image
      # Push logic here

  deploy:
    needs: build
    uses: Bengo-Hub/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: myapp
      # deployment parameters
```

## Environment Variables

### For Application-Specific Deployment (deploy.yml)

| Variable | Purpose | Default |
|----------|---------|---------|
| `DEPLOY` | Enable/disable deployment phase | `true` |
| `SETUP_DATABASES` | Enable/disable database setup | `true` (API), `false` (UI) |
| `DB_TYPES` | Comma-separated database list | `postgres,redis` |
| `NAMESPACE` | Kubernetes namespace | `erp` |
| `ENV_SECRET_NAME` | Kubernetes secret name | `app-env` |
| `REGISTRY_SERVER` | Container registry | `docker.io` |
| `REGISTRY_NAMESPACE` | Registry namespace | `codevertex` |

### For Centralized Reusable Workflow

See the reusable workflow inputs documented in the workflow definition.

## Security Best Practices

### Dynamic Secret Generation
- **Application approach**: Secrets are managed through GitHub repository secrets
- **devENV.yaml**: Use placeholder values like `__DYNAMIC_PASSWORD__` that get replaced during deployment
- **Never commit**: Hardcoded secrets to version control

### Secret Management
- Store sensitive values in GitHub repository secrets
- Use different secrets for different environments
- Rotate secrets regularly
- Use strong, randomly generated passwords

## Migration Guide

### From build.sh to deploy.yml (Recommended)

1. **Extract build logic** from `build.sh` into deploy.yml build job
2. **Move deployment parameters** to reusable workflow inputs
3. **Remove build.sh file** and update documentation
4. **Test thoroughly** in a staging environment
5. **Update team processes** to reflect new workflow structure

### Benefits of New Approach
- ✅ **GitHub-native**: Full integration with GitHub Actions ecosystem
- ✅ **Better maintainability**: YAML-based configuration vs shell scripts
- ✅ **Improved debugging**: Better error reporting and step visibility
- ✅ **Version control friendly**: Workflow changes tracked in git
- ✅ **Reusable components**: Shared deployment logic in reusable workflows
