Pipelines
---------

This repo provides multiple deployment approaches for different use cases:

## 1. Application-Specific Deployment (Recommended)

For applications that need full control over their deployment process, use the `build.sh` approach where each application manages its own deployment logic.

### Features
- **Self-contained**: Each application controls its deployment process
- **Highly flexible**: Easy to customize per application requirements
- **Comprehensive logging**: Detailed colored output and error handling
- **Dynamic secrets**: Automatic generation of secure passwords and tokens
- **Database automation**: Automatic setup and configuration
- **Multi-environment support**: Configurable for different deployment scenarios

### Setup Requirements
Each application needs:
- `build.sh` - Main deployment script
- `kubeSecrets/devENV.yaml` - Kubernetes secrets configuration
- `.github/workflows/deploy.yml` - Simple CI trigger

### Example Application Structure
```
your-app/
├── build.sh                    # Main deployment script
├── kubeSecrets/
│   └── devENV.yaml            # Dynamic secrets (no hardcoded values)
├── .github/workflows/
│   └── deploy.yml             # Simple CI trigger
└── Dockerfile
```

## 2. Centralized Reusable Workflow (Legacy)

The `reusable-build-deploy.yml` provides a centralized approach for applications that prefer shared deployment logic.

### Inputs
- app_name: logical app identifier
- registry_server: container registry server (default docker.io)
- registry_namespace: registry namespace/user (default codevertex)
- docker_context: build context (default `.`)
- dockerfile: path to Dockerfile (default `Dockerfile`)
- image_repository: optional full image repo override (e.g. `docker.io/codevertex/erp-api`)
- deploy: boolean to push image and update values
- values_file_path: path to values file in this repo (e.g. `apps/erp-api/values.yaml`)
- chart_repo_path: path to chart (default `charts/app`)
- namespace: k8s namespace
- ssh_deploy: true to deploy via SSH to VPS (Contabo, on-prem)
- ssh_host, ssh_user, ssh_port, ssh_deploy_command: SSH deployment parameters
- setup_databases: true to install DBs (PostgreSQL/Redis/Mongo/MySQL)
- db_types: comma-separated list (default: postgres,redis)
- env_secret_name: Secret name to write DB URLs into (default: app-env)

### Secrets
- REGISTRY_USERNAME, REGISTRY_PASSWORD: optional for private registry
- KUBE_CONFIG: base64 kubeconfig (optional)
- SSH_PRIVATE_KEY / DOCKER_SSH_KEY: optional for private git/registry
- POSTGRES_PASSWORD, REDIS_PASSWORD, MONGO_PASSWORD, MYSQL_PASSWORD: optional; auto-generated if omitted

### Behavior
1. Trivy scans source and image.
2. Builds Docker image with short SHA tag.
3. Optionally pushes image, updates `values.yaml` with the new tag, commits to `main`.
4. Optionally applies `kubeSecrets/devENV.yaml` if provided with KUBE_CONFIG.
5. Optionally installs databases and writes connection URLs into a Kubernetes Secret.
6. Argo CD detects changes and syncs.

## Deployment Options

### Option A: Application-Specific (build.sh)

**Recommended for new applications and those needing customization.**

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy ERP API

on:
  push:
    branches: [ main, master ]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      contents: write
      id-token: write

    steps:
    - name: Checkout code
      uses: actions/checkout@v4

    - name: Set up Docker Buildx
      uses: docker/setup-buildx-action@v3

    - name: Install DevOps Tools
      uses: Bengo-Hub/devops-k8s/.github/actions/install-devops-tools@main

    - name: Set deployment variables
      run: |
        echo "DEPLOY=true" >> $GITHUB_ENV
        echo "SETUP_DATABASES=true" >> $GITHUB_ENV
        echo "DB_TYPES=postgres,redis" >> $GITHUB_ENV
        echo "NAMESPACE=erp" >> $GITHUB_ENV
        echo "ENV_SECRET_NAME=erp-api-env" >> $GITHUB_ENV
        echo "REGISTRY_SERVER=docker.io" >> $GITHUB_ENV
        echo "REGISTRY_NAMESPACE=codevertex" >> $GITHUB_ENV

    - name: Run production deployment
      env:
        DOCKER_SSH_KEY: ${{ secrets.DOCKER_SSH_KEY }}
        KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
        REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
        REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
        GITHUB_SHA: ${{ github.sha }}
        # All variables from above
      run: |
        chmod +x build.sh
        ./build.sh
```

### Option B: Centralized Reusable Workflow

**For applications that prefer shared deployment logic.**

```yaml
# .github/workflows/deploy.yml
name: Build and Deploy

on:
  push:
    branches: [ main ]

jobs:
  deploy:
    uses: Bengo-Hub/devops-k8s/.github/workflows/reusable-build-deploy.yml@main
    with:
      app_name: erp-api
      registry_server: docker.io
      registry_namespace: codevertex
      values_file_path: apps/erp-api/values.yaml
      deploy: true
      namespace: erp
      setup_databases: true
      db_types: postgres,redis
      env_secret_name: erp-api-env
    secrets:
      REGISTRY_USERNAME: ${{ secrets.REGISTRY_USERNAME }}
      REGISTRY_PASSWORD: ${{ secrets.REGISTRY_PASSWORD }}
      KUBE_CONFIG: ${{ secrets.KUBE_CONFIG }}
      DOCKER_SSH_KEY: ${{ secrets.DOCKER_SSH_KEY }}
```

## Environment Variables

### For build.sh Approach

| Variable | Purpose | Default |
|----------|---------|---------|
| `DEPLOY` | Enable/disable deployment phase | `false` |
| `SETUP_DATABASES` | Enable/disable database setup | `true` (API), `false` (UI) |
| `DB_TYPES` | Comma-separated database list | `postgres,redis` |
| `NAMESPACE` | Kubernetes namespace | `erp` |
| `ENV_SECRET_NAME` | Kubernetes secret name | `app-env` |
| `REGISTRY_SERVER` | Container registry | `docker.io` |
| `REGISTRY_NAMESPACE` | Registry namespace | `codevertex` |
| `DOCKER_SSH_KEY` | SSH key for private repos | *From secret* |
| `KUBE_CONFIG` | Base64 kubeconfig | *From secret* |

### For Reusable Workflow Approach

See the reusable workflow inputs and secrets documented above.

## Security Best Practices

### Dynamic Secret Generation
- **build.sh approach**: Automatically generates secure passwords and tokens
- **devENV.yaml**: Use placeholder values like `__DYNAMIC_PASSWORD__` that get replaced during deployment
- **Never commit**: Hardcoded secrets to version control

### Secret Management
- Store sensitive values in GitHub repository secrets
- Use different secrets for different environments
- Rotate secrets regularly
- Use strong, randomly generated passwords

## Migration Guide

### From Reusable Workflow to build.sh

1. **Create build.sh** in your application root
2. **Update kubeSecrets/devENV.yaml** to use dynamic placeholders
3. **Replace deploy.yml** with the application-specific workflow above
4. **Test thoroughly** in a staging environment
5. **Update secrets** to use the new naming convention

### Benefits of Migration
- ✅ **More control** over deployment process
- ✅ **Better customization** per application
- ✅ **Comprehensive logging** and error handling
- ✅ **Dynamic secret generation**
- ✅ **Easier debugging** and troubleshooting
