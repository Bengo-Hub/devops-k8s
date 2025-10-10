#!/bin/bash
set -euo pipefail

# Production-ready Database Installation
# Installs PostgreSQL and Redis with production configurations

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
NAMESPACE=${DB_NAMESPACE:-erp}
PG_DATABASE=${PG_DATABASE:-bengo_erp}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFESTS_DIR="$(dirname "$SCRIPT_DIR")/manifests"

echo -e "${GREEN}Installing ERP Databases (Production)...${NC}"
echo -e "${BLUE}Namespace: ${NAMESPACE}${NC}"
echo -e "${BLUE}PostgreSQL Database: ${PG_DATABASE}${NC}"

# Pre-flight checks
if ! command -v kubectl &> /dev/null; then
  echo -e "${RED}kubectl command not found. Aborting.${NC}"
  exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
  echo -e "${RED}Cannot connect to cluster. Ensure KUBECONFIG is set. Aborting.${NC}"
  exit 1
fi

echo -e "${GREEN}✓ kubectl configured and cluster reachable${NC}"

# Check for storage class (required for PVCs)
if ! kubectl get storageclass 2>/dev/null | grep -q "(default)"; then
  echo -e "${YELLOW}No default storage class found. Installing local-path provisioner...${NC}"
  "${SCRIPT_DIR}/install-storage-provisioner.sh"
else
  echo -e "${GREEN}✓ Default storage class available${NC}"
fi

# Check for Helm (install if missing)
if ! command -v helm &> /dev/null; then
  echo -e "${YELLOW}Helm not found. Installing via snap...${NC}"
  if command -v snap &> /dev/null; then
    sudo snap install helm --classic
  else
    echo -e "${YELLOW}snap not available. Installing Helm via script...${NC}"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
  echo -e "${GREEN}✓ Helm installed${NC}"
else
  echo -e "${GREEN}✓ Helm already installed${NC}"
fi

# Add Bitnami repository
echo -e "${YELLOW}Adding Bitnami Helm repository...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null 2>&1 || true
helm repo update

# Create namespace
if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
  echo -e "${GREEN}✓ Namespace '${NAMESPACE}' already exists${NC}"
else
  echo -e "${YELLOW}Creating namespace '${NAMESPACE}'...${NC}"
  kubectl create namespace "${NAMESPACE}"
  echo -e "${GREEN}✓ Namespace '${NAMESPACE}' created${NC}"
fi

# Update postgresql-values.yaml with dynamic database name
TEMP_PG_VALUES=/tmp/postgresql-values-prod.yaml
cp "${MANIFESTS_DIR}/databases/postgresql-values.yaml" "${TEMP_PG_VALUES}"
sed -i "s|database: \"bengo_erp\"|database: \"${PG_DATABASE}\"|g" "${TEMP_PG_VALUES}" 2>/dev/null || \
  sed -i '' "s|database: \"bengo_erp\"|database: \"${PG_DATABASE}\"|g" "${TEMP_PG_VALUES}" 2>/dev/null || true

# Install or upgrade PostgreSQL (idempotent)
echo -e "${YELLOW}Installing/upgrading PostgreSQL...${NC}"
echo -e "${BLUE}Starting in background. Watching pod status...${NC}"

helm upgrade --install postgresql bitnami/postgresql \
  -n "${NAMESPACE}" \
  -f "${TEMP_PG_VALUES}" \
  --timeout=10m --wait --debug &
HELM_PG_PID=$!

# Watch pods in real-time
WATCH_COUNT=0
while kill -0 $HELM_PG_PID 2>/dev/null; do
  echo -ne "\r${BLUE}PostgreSQL pods: ${NC}"
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | wc -l | tr -d '\n'
  echo -ne " | Status: "
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo -n "Creating"
  sleep 2
  WATCH_COUNT=$((WATCH_COUNT + 1))
  if [ $WATCH_COUNT -gt 300 ]; then break; fi
done
echo ""

if wait $HELM_PG_PID; then
  echo -e "${GREEN}✓ PostgreSQL ready${NC}"
else
  echo -e "${RED}PostgreSQL installation failed. Checking status...${NC}"
  kubectl get pods -n "${NAMESPACE}"
  exit 1
fi

# Install or upgrade Redis (idempotent)
echo -e "${YELLOW}Installing/upgrading Redis...${NC}"
echo -e "${BLUE}Starting in background. Watching pod status...${NC}"

helm upgrade --install redis bitnami/redis \
  -n "${NAMESPACE}" \
  -f "${MANIFESTS_DIR}/databases/redis-values.yaml" \
  --timeout=10m --wait --debug &
HELM_REDIS_PID=$!

# Watch pods in real-time
WATCH_COUNT=0
while kill -0 $HELM_REDIS_PID 2>/dev/null; do
  echo -ne "\r${BLUE}Redis pods: ${NC}"
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis --no-headers 2>/dev/null | wc -l | tr -d '\n'
  echo -ne " | Status: "
  kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=redis -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo -n "Creating"
  sleep 2
  WATCH_COUNT=$((WATCH_COUNT + 1))
  if [ $WATCH_COUNT -gt 300 ]; then break; fi
done
echo ""

if wait $HELM_REDIS_PID; then
  echo -e "${GREEN}✓ Redis ready${NC}"
else
  echo -e "${RED}Redis installation failed. Checking status...${NC}"
  kubectl get pods -n "${NAMESPACE}"
  exit 1
fi

# Retrieve credentials
echo ""
echo -e "${GREEN}=== Database Installation Complete ===${NC}"
echo ""
echo -e "${YELLOW}Retrieving credentials...${NC}"

# Get PostgreSQL password
echo ""
echo -e "${BLUE}PostgreSQL Credentials:${NC}"
POSTGRES_PASSWORD=$(kubectl get secret postgresql -n "${NAMESPACE}" -o jsonpath="{.data.postgres-password}" 2>/dev/null | base64 -d || echo "")
if [ -n "$POSTGRES_PASSWORD" ]; then
  echo "  Host: postgresql.${NAMESPACE}.svc.cluster.local"
  echo "  Port: 5432"
  echo "  Database: ${PG_DATABASE}"
  echo "  User: postgres"
  echo "  Password: $POSTGRES_PASSWORD"
  echo ""
  echo "  Connection String:"
  echo "  postgresql://postgres:$POSTGRES_PASSWORD@postgresql.${NAMESPACE}.svc.cluster.local:5432/${PG_DATABASE}"
else
  echo -e "${RED}  Failed to retrieve PostgreSQL password${NC}"
fi

# Get Redis password
echo ""
echo -e "${BLUE}Redis Credentials:${NC}"
REDIS_PASSWORD=$(kubectl get secret redis -n "${NAMESPACE}" -o jsonpath="{.data.redis-password}" 2>/dev/null | base64 -d || echo "")
if [ -n "$REDIS_PASSWORD" ]; then
  echo "  Host: redis-master.${NAMESPACE}.svc.cluster.local"
  echo "  Port: 6379"
  echo "  Password: $REDIS_PASSWORD"
  echo ""
  echo "  Connection String (Cache - DB 0):"
  echo "  redis://:$REDIS_PASSWORD@redis-master.${NAMESPACE}.svc.cluster.local:6379/0"
  echo ""
  echo "  Connection String (Celery - DB 1):"
  echo "  redis://:$REDIS_PASSWORD@redis-master.${NAMESPACE}.svc.cluster.local:6379/1"
else
  echo -e "${RED}  Failed to retrieve Redis password${NC}"
fi

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Update BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml with these credentials"
echo "2. Apply the secret: kubectl apply -f BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml"
echo "3. Run database initialization: kubectl apply -f manifests/databases/erp-db-init-job.yaml"
echo "4. Deploy ERP API via Argo CD"
echo ""
echo -e "${GREEN}Done!${NC}"
