#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}Installing ERP Databases (PostgreSQL + Redis)...${NC}"

# Add Bitnami repository
echo -e "${YELLOW}Adding Bitnami Helm repository...${NC}"
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create namespace
echo -e "${YELLOW}Creating erp namespace...${NC}"
kubectl create namespace erp --dry-run=client -o yaml | kubectl apply -f -

# Install PostgreSQL
echo -e "${BLUE}Installing PostgreSQL...${NC}"
helm install postgresql bitnami/postgresql \
  -n erp \
  -f manifests/databases/postgresql-values.yaml \
  --wait

# Install Redis
echo -e "${BLUE}Installing Redis...${NC}"
helm install redis bitnami/redis \
  -n erp \
  -f manifests/databases/redis-values.yaml \
  --wait

echo -e "${GREEN}Databases installed successfully!${NC}"
echo ""
echo -e "${YELLOW}Retrieving credentials...${NC}"

# Get PostgreSQL password
echo ""
echo -e "${BLUE}PostgreSQL Credentials:${NC}"
export POSTGRES_PASSWORD=$(kubectl get secret postgresql \
  -n erp \
  -o jsonpath="{.data.postgres-password}" | base64 -d)
echo "  Host: postgresql.erp.svc.cluster.local"
echo "  Port: 5432"
echo "  Database: bengo_erp"
echo "  User: postgres"
echo "  Password: $POSTGRES_PASSWORD"
echo ""
echo "  Connection String:"
echo "  postgresql://postgres:$POSTGRES_PASSWORD@postgresql.erp.svc.cluster.local:5432/bengo_erp"

# Get Redis password
echo ""
echo -e "${BLUE}Redis Credentials:${NC}"
export REDIS_PASSWORD=$(kubectl get secret redis \
  -n erp \
  -o jsonpath="{.data.redis-password}" | base64 -d)
echo "  Host: redis-master.erp.svc.cluster.local"
echo "  Port: 6379"
echo "  Password: $REDIS_PASSWORD"
echo ""
echo "  Connection String (Cache - DB 0):"
echo "  redis://:$REDIS_PASSWORD@redis-master.erp.svc.cluster.local:6379/0"
echo ""
echo "  Connection String (Celery - DB 1):"
echo "  redis://:$REDIS_PASSWORD@redis-master.erp.svc.cluster.local:6379/1"

echo ""
echo -e "${YELLOW}Next Steps:${NC}"
echo "1. Update BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml with these credentials"
echo "2. Apply the secret: kubectl apply -f BengoERP/bengobox-erp-api/kubeSecrets/devENV.yaml"
echo "3. Run database initialization: kubectl apply -f manifests/databases/erp-db-init-job.yaml"
echo "4. Deploy ERP API: kubectl apply -f apps/erp-api/app.yaml"
echo ""
echo -e "${GREEN}Done!${NC}"

