# Scripts Directory Organization

This directory contains all provisioning, maintenance, and diagnostic scripts organized by function.

## Directory Structure

```
scripts/
├── cluster/          # Cluster lifecycle management
├── infrastructure/   # Infrastructure component installation
├── monitoring/       # Monitoring stack installation
├── tools/           # Utility and helper scripts
└── diagnostics/     # Diagnostic and troubleshooting scripts
```

## Script Categories

### `cluster/` - Cluster Lifecycle Management

Scripts for setting up, cleaning, and managing the Kubernetes cluster itself.

- **`setup-vps.sh`** - Initial VPS setup (system packages, kernel modules, firewall)
- **`setup-containerd.sh`** - Container runtime installation (containerd)
- **`setup-kubernetes.sh`** - Kubernetes cluster initialization (kubeadm)
- **`cluster/cleanup-cluster.sh`** - Complete cluster cleanup (namespaces, runtimes, data)
- **`reprovision-cluster.sh`** - Full reprovisioning (cleanup + reinstall)
- **`fix-etcd-space.sh`** - Fix etcd database space issues

### `infrastructure/` - Infrastructure Components

Scripts for installing and configuring infrastructure components.

- **`install-storage-provisioner.sh`** - Local path storage provisioner
- **`install-databases.sh`** - PostgreSQL & Redis installation
- **`install-rabbitmq.sh`** - RabbitMQ message queue
- **`configure-ingress-controller.sh`** - NGINX Ingress Controller
- **`install-cert-manager.sh`** - cert-manager for TLS certificates
- **`install-argocd.sh`** - ArgoCD GitOps tool
- **`install-vpa.sh`** - Vertical Pod Autoscaler
- **`create-service-database.sh`** - Create per-service databases
- **`verify-db-credentials.sh`** - Verify database credentials

### `monitoring/` - Monitoring Stack

Scripts for installing and managing the monitoring stack.

- **`install-monitoring.sh`** - Prometheus + Grafana installation
- **`fix-stuck-helm-monitoring.sh`** - Fix stuck Helm operations for monitoring

### `tools/` - Utility Scripts

Helper scripts and utilities used by other scripts.

- **`common.sh`** - Common functions and utilities (sourced by other scripts)
- **`check-services.sh`** - Check service health
- **`deployment-metrics.sh`** - Deployment metrics collection
- **`deployment-rollback.sh`** - Rollback deployments
- **`find-existing-infra.sh`** - Find existing infrastructure
- **`vps-verification-script.sh`** - VPS verification

### `diagnostics/` - Diagnostic Scripts

Scripts for diagnosing and troubleshooting issues.

- **`diagnose-pending-pods.sh`** - Diagnose why pods are Pending

## Usage

### Complete Cluster Setup (From Scratch)

```bash
# On VPS (as root)
cd /path/to/devops-k8s/scripts/cluster
./setup-vps.sh
./setup-containerd.sh
./setup-kubernetes.sh  # This will output kubeconfig - save it!
```

### Infrastructure Provisioning

```bash
# With kubectl configured
cd /path/to/devops-k8s/scripts
./infrastructure/install-storage-provisioner.sh
./infrastructure/install-databases.sh
# ... etc
```

### Complete Reprovisioning

```bash
# Clean and reprovision everything
cd /path/to/devops-k8s/scripts/cluster
./reprovision-cluster.sh
```

### Cleanup Only

```bash
cd /path/to/devops-k8s/scripts/cluster
export ENABLE_CLEANUP=true
export FORCE_CLEANUP=true
./cluster/cleanup-cluster.sh
```

## Script Dependencies

Most infrastructure scripts depend on `tools/common.sh`:

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"
```

## GitHub Actions Workflow

The `.github/workflows/provision.yml` workflow orchestrates all these scripts in the correct order:

1. **VPS Setup** (if `setup_cluster=true`)
   - `cluster/setup-vps.sh`
   - `cluster/setup-containerd.sh`
   - `cluster/setup-kubernetes.sh`

2. **Cleanup** (if `enable_cleanup=true`)
   - `cluster/cleanup-cluster.sh`

3. **Infrastructure Installation**
   - `infrastructure/install-storage-provisioner.sh`
   - `infrastructure/install-databases.sh`
   - `infrastructure/install-rabbitmq.sh`
   - `infrastructure/configure-ingress-controller.sh`
   - `infrastructure/install-cert-manager.sh`
   - `infrastructure/install-argocd.sh`
   - `monitoring/install-monitoring.sh`
   - `infrastructure/install-vpa.sh`

## Environment Variables

Common environment variables used across scripts:

- `CLUSTER_NAME` - Cluster name (default: `mss-prod`)
- `VPS_IP` - VPS public IP address
- `DB_NAMESPACE` - Database namespace (default: `infra`)
- `MONITORING_NAMESPACE` - Monitoring namespace (default: `infra`)
- `ENABLE_CLEANUP` - Enable cleanup mode (default: `true`)
- `FORCE_CLEANUP` - Skip confirmation prompts (default: `true`)
- `POSTGRES_PASSWORD` - PostgreSQL password
- `POSTGRES_ADMIN_PASSWORD` - PostgreSQL admin user password
- `REDIS_PASSWORD` - Redis password
- `RABBITMQ_PASSWORD` - RabbitMQ password
- `ARGOCD_DOMAIN` - ArgoCD domain
- `GRAFANA_DOMAIN` - Grafana domain

## Notes

- All scripts are idempotent (safe to run multiple times)
- Scripts check for existing resources before creating new ones
- Most scripts support `ENABLE_CLEANUP` mode for fresh installations
- Scripts output base64-encoded keys/configs for GitHub secrets

