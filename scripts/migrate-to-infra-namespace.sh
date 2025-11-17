#!/usr/bin/env bash
# Migrate shared infrastructure resources to infra namespace
# This script finds existing PostgreSQL, Redis, and RabbitMQ installations
# and migrates them to the infra namespace

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

TARGET_NAMESPACE="infra"

# Find existing installations
log_info "Searching for existing shared infrastructure installations..."

# Check all namespaces for PostgreSQL
PG_NAMESPACES=$(kubectl get statefulset -A -o json | jq -r '.items[] | select(.metadata.name=="postgresql") | .metadata.namespace' 2>/dev/null || echo "")

# Check all namespaces for Redis
REDIS_NAMESPACES=$(kubectl get statefulset -A -o json | jq -r '.items[] | select(.metadata.name=="redis-master" or .metadata.name=="redis") | .metadata.namespace' 2>/dev/null || echo "")

# Check all namespaces for RabbitMQ
RABBITMQ_NAMESPACES=$(kubectl get statefulset -A -o json | jq -r '.items[] | select(.metadata.name=="rabbitmq") | .metadata.namespace' 2>/dev/null || echo "")

log_info "Found PostgreSQL in namespaces: ${PG_NAMESPACES:-none}"
log_info "Found Redis in namespaces: ${REDIS_NAMESPACES:-none}"
log_info "Found RabbitMQ in namespaces: ${RABBITMQ_NAMESPACES:-none}"

# Create infra namespace if it doesn't exist
if ! kubectl get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1; then
    log_info "Creating ${TARGET_NAMESPACE} namespace..."
    kubectl create namespace "$TARGET_NAMESPACE"
    log_success "Created ${TARGET_NAMESPACE} namespace"
else
    log_info "Namespace ${TARGET_NAMESPACE} already exists"
fi

# Function to migrate resources
migrate_resource() {
    local RESOURCE_TYPE=$1
    local RESOURCE_NAME=$2
    local SOURCE_NAMESPACE=$3
    local TARGET_NAMESPACE=$4
    
    if [[ "$SOURCE_NAMESPACE" == "$TARGET_NAMESPACE" ]]; then
        log_info "${RESOURCE_TYPE}/${RESOURCE_NAME} already in ${TARGET_NAMESPACE} namespace - skipping"
        return 0
    fi
    
    log_info "Migrating ${RESOURCE_TYPE}/${RESOURCE_NAME} from ${SOURCE_NAMESPACE} to ${TARGET_NAMESPACE}..."
    
    # Export resource
    kubectl get "$RESOURCE_TYPE" "$RESOURCE_NAME" -n "$SOURCE_NAMESPACE" -o yaml > /tmp/${RESOURCE_NAME}.yaml 2>/dev/null || {
        log_warning "Could not export ${RESOURCE_TYPE}/${RESOURCE_NAME} from ${SOURCE_NAMESPACE}"
        return 1
    }
    
    # Update namespace in YAML
    sed -i "s/namespace: ${SOURCE_NAMESPACE}/namespace: ${TARGET_NAMESPACE}/g" /tmp/${RESOURCE_NAME}.yaml 2>/dev/null || \
    sed -i '' "s/namespace: ${SOURCE_NAMESPACE}/namespace: ${TARGET_NAMESPACE}/g" /tmp/${RESOURCE_NAME}.yaml 2>/dev/null || true
    
    # Remove metadata that shouldn't be copied
    yq eval 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.selfLink, .status)' -i /tmp/${RESOURCE_NAME}.yaml 2>/dev/null || true
    
    # Apply to target namespace
    kubectl apply -f /tmp/${RESOURCE_NAME}.yaml -n "$TARGET_NAMESPACE" || {
        log_error "Failed to apply ${RESOURCE_TYPE}/${RESOURCE_NAME} to ${TARGET_NAMESPACE}"
        return 1
    }
    
    log_success "Migrated ${RESOURCE_TYPE}/${RESOURCE_NAME} to ${TARGET_NAMESPACE}"
}

# Migrate PostgreSQL
if [[ -n "$PG_NAMESPACES" ]]; then
    for ns in $PG_NAMESPACES; do
        if [[ "$ns" != "$TARGET_NAMESPACE" ]]; then
            log_warning "PostgreSQL found in ${ns} namespace. Migration requires manual steps:"
            echo "  1. Backup data: kubectl exec -n ${ns} postgresql-0 -- pg_dumpall -U postgres > backup.sql"
            echo "  2. Scale down: kubectl scale statefulset postgresql -n ${ns} --replicas=0"
            echo "  3. Export PVC: kubectl get pvc -n ${ns} -l app.kubernetes.io/name=postgresql -o yaml"
            echo "  4. Recreate in infra namespace using ArgoCD or Helm"
            echo ""
            echo "  OR use Helm upgrade to move:"
            echo "  helm upgrade postgresql bitnami/postgresql -n ${TARGET_NAMESPACE} --reuse-values"
        fi
    done
fi

# Migrate Redis
if [[ -n "$REDIS_NAMESPACES" ]]; then
    for ns in $REDIS_NAMESPACES; do
        if [[ "$ns" != "$TARGET_NAMESPACE" ]]; then
            log_warning "Redis found in ${ns} namespace. Migration requires manual steps:"
            echo "  1. Backup data: kubectl exec -n ${ns} redis-master-0 -- redis-cli --rdb /tmp/dump.rdb"
            echo "  2. Scale down: kubectl scale statefulset redis-master -n ${ns} --replicas=0"
            echo "  3. Export PVC: kubectl get pvc -n ${ns} -l app.kubernetes.io/name=redis -o yaml"
            echo "  4. Recreate in infra namespace using ArgoCD or Helm"
        fi
    done
fi

# Migrate RabbitMQ
if [[ -n "$RABBITMQ_NAMESPACES" ]]; then
    for ns in $RABBITMQ_NAMESPACES; do
        if [[ "$ns" != "$TARGET_NAMESPACE" ]]; then
            log_warning "RabbitMQ found in ${ns} namespace. Migration requires manual steps:"
            echo "  1. Export definitions: kubectl exec -n ${ns} rabbitmq-0 -- rabbitmqctl export_definitions /tmp/definitions.json"
            echo "  2. Scale down: kubectl scale statefulset rabbitmq -n ${ns} --replicas=0"
            echo "  3. Export PVC: kubectl get pvc -n ${ns} -l app.kubernetes.io/name=rabbitmq -o yaml"
            echo "  4. Recreate in infra namespace using ArgoCD or Helm"
        fi
    done
fi

log_info "Migration check complete. For stateful resources, manual migration is recommended."
log_info "Alternatively, you can delete old installations and let ArgoCD recreate them in infra namespace."

