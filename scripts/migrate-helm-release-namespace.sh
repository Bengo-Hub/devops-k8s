#!/usr/bin/env bash
# Migrate Helm releases to infra namespace
# This script helps migrate existing Helm releases from old namespaces to infra namespace

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

# Function to migrate Helm release
migrate_helm_release() {
    local RELEASE_NAME=$1
    local SOURCE_NAMESPACE=$2
    local TARGET_NAMESPACE=$3
    local CHART_NAME=$4
    
    if [[ "$SOURCE_NAMESPACE" == "$TARGET_NAMESPACE" ]]; then
        log_info "${RELEASE_NAME} already in ${TARGET_NAMESPACE} namespace - skipping"
        return 0
    fi
    
    log_info "Migrating Helm release ${RELEASE_NAME} from ${SOURCE_NAMESPACE} to ${TARGET_NAMESPACE}..."
    
    # Get current values
    log_info "Exporting current Helm values..."
    helm get values "$RELEASE_NAME" -n "$SOURCE_NAMESPACE" -o yaml > /tmp/${RELEASE_NAME}-values.yaml || {
        log_error "Failed to export values for ${RELEASE_NAME}"
        return 1
    }
    
    # Create target namespace if it doesn't exist
    if ! kubectl get namespace "$TARGET_NAMESPACE" >/dev/null 2>&1; then
        log_info "Creating ${TARGET_NAMESPACE} namespace..."
        kubectl create namespace "$TARGET_NAMESPACE"
    fi
    
    # Get the chart version
    CHART_VERSION=$(helm list -n "$SOURCE_NAMESPACE" -o json | jq -r ".[] | select(.name==\"${RELEASE_NAME}\") | .chart" | cut -d- -f2- || echo "")
    
    log_warning "For stateful resources like PostgreSQL/Redis/RabbitMQ, migration requires:"
    echo "  1. Backup data first"
    echo "  2. Uninstall from old namespace"
    echo "  3. Reinstall in new namespace with same values"
    echo ""
    echo "To migrate ${RELEASE_NAME}:"
    echo "  # 1. Backup (example for PostgreSQL):"
    echo "  kubectl exec -n ${SOURCE_NAMESPACE} ${RELEASE_NAME}-0 -- pg_dumpall -U postgres > backup-${RELEASE_NAME}.sql"
    echo ""
    echo "  # 2. Uninstall from old namespace:"
    echo "  helm uninstall ${RELEASE_NAME} -n ${SOURCE_NAMESPACE}"
    echo ""
    echo "  # 3. Install in new namespace:"
    echo "  helm install ${RELEASE_NAME} ${CHART_NAME} \\"
    echo "    -n ${TARGET_NAMESPACE} \\"
    echo "    -f /tmp/${RELEASE_NAME}-values.yaml \\"
    echo "    --set global.defaultFips=false \\"
    echo "    --set fips.openssl=false"
    echo ""
    echo "  # 4. Restore data (if needed)"
    echo ""
    
    return 0
}

# Find PostgreSQL installations
log_info "Searching for PostgreSQL Helm releases..."
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
    if helm list -n "$ns" 2>/dev/null | grep -q "postgresql"; then
        PG_NS="$ns"
        log_warning "PostgreSQL found in namespace: ${PG_NS}"
        migrate_helm_release "postgresql" "$PG_NS" "$TARGET_NAMESPACE" "bitnami/postgresql"
    fi
done

# Find Redis installations
log_info "Searching for Redis Helm releases..."
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
    if helm list -n "$ns" 2>/dev/null | grep -q "redis"; then
        REDIS_NS="$ns"
        log_warning "Redis found in namespace: ${REDIS_NS}"
        migrate_helm_release "redis" "$REDIS_NS" "$TARGET_NAMESPACE" "bitnami/redis"
    fi
done

# Find RabbitMQ installations
log_info "Searching for RabbitMQ Helm releases..."
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
    if helm list -n "$ns" 2>/dev/null | grep -q "rabbitmq"; then
        RABBITMQ_NS="$ns"
        log_warning "RabbitMQ found in namespace: ${RABBITMQ_NS}"
        migrate_helm_release "rabbitmq" "$RABBITMQ_NS" "$TARGET_NAMESPACE" "bitnami/rabbitmq"
    fi
done

log_info "Migration guide complete. Helm values exported to /tmp/*-values.yaml"

