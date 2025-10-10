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

# Install or upgrade PostgreSQL
if helm -n "${NAMESPACE}" status postgresql >/dev/null 2>&1; then
  echo -e "${YELLOW}PostgreSQL already installed. Skipping re-install.${NC}"
else
  echo -e "${YELLOW}Installing PostgreSQL...${NC}"
  helm install postgresql bitnami/postgresql \
    -n "${NAMESPACE}" \
    -f "${TEMP_PG_VALUES}" \
    --wait
fi
echo -e "${GREEN}✓ PostgreSQL ready${NC}"

# Install or upgrade Redis
if helm -n "${NAMESPACE}" status redis >/dev/null 2>&1; then
  echo -e "${YELLOW}Redis already installed. Skipping re-install.${NC}"
else
  echo -e "${YELLOW}Installing Redis...${NC}"
  helm install redis bitnami/redis \
    -n "${NAMESPACE}" \
    -f "${MANIFESTS_DIR}/databases/redis-values.yaml" \
    --wait
fi
echo -e "${GREEN}✓ Redis ready${NC}"

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
