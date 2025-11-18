#!/usr/bin/env bash
# Find existing shared infrastructure installations
# Helps identify where PostgreSQL, Redis, and RabbitMQ are currently installed

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

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}Finding Existing Shared Infrastructure Installations${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# Check for PostgreSQL
log_info "Searching for PostgreSQL installations..."
PG_FOUND=false
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
    if kubectl get statefulset postgresql -n "$ns" >/dev/null 2>&1; then
        PG_FOUND=true
        PG_NS="$ns"
        log_warning "PostgreSQL found in namespace: ${PG_NS}"
        kubectl get statefulset postgresql -n "$ns" -o wide
        echo ""
    fi
done

if [[ "$PG_FOUND" == "false" ]]; then
    log_info "PostgreSQL not found in any namespace"
fi

# Check for Redis
log_info "Searching for Redis installations..."
REDIS_FOUND=false
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
    if kubectl get statefulset redis-master -n "$ns" >/dev/null 2>&1 || kubectl get statefulset redis -n "$ns" >/dev/null 2>&1; then
        REDIS_FOUND=true
        REDIS_NS="$ns"
        log_warning "Redis found in namespace: ${REDIS_NS}"
        kubectl get statefulset redis-master redis -n "$ns" -o wide 2>/dev/null || true
        echo ""
    fi
done

if [[ "$REDIS_FOUND" == "false" ]]; then
    log_info "Redis not found in any namespace"
fi

# Check for RabbitMQ
log_info "Searching for RabbitMQ installations..."
RABBITMQ_FOUND=false
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
    if kubectl get statefulset rabbitmq -n "$ns" >/dev/null 2>&1; then
        RABBITMQ_FOUND=true
        RABBITMQ_NS="$ns"
        log_warning "RabbitMQ found in namespace: ${RABBITMQ_NS}"
        kubectl get statefulset rabbitmq -n "$ns" -o wide
        echo ""
    fi
done

if [[ "$RABBITMQ_FOUND" == "false" ]]; then
    log_info "RabbitMQ not found in any namespace"
fi

# Check for Helm releases
log_info "Searching for Helm releases..."
echo ""
for ns in $(kubectl get namespaces -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo ""); do
    if helm list -n "$ns" 2>/dev/null | grep -q "postgresql\|redis\|rabbitmq"; then
        log_info "Helm releases in namespace ${ns}:"
        helm list -n "$ns" | grep -E "postgresql|redis|rabbitmq" || true
        echo ""
    fi
done

echo -e "${BLUE}================================================================${NC}"
echo -e "${GREEN}Summary${NC}"
echo -e "${BLUE}================================================================${NC}"

if [[ "$PG_FOUND" == "true" ]]; then
    echo "PostgreSQL: Found in ${PG_NS} namespace"
    if [[ "$PG_NS" != "infra" ]]; then
        echo "  ⚠️  Needs migration to infra namespace"
    else
        echo "  ✅ Already in infra namespace"
    fi
fi

if [[ "$REDIS_FOUND" == "true" ]]; then
    echo "Redis: Found in ${REDIS_NS} namespace"
    if [[ "$REDIS_NS" != "infra" ]]; then
        echo "  ⚠️  Needs migration to infra namespace"
    else
        echo "  ✅ Already in infra namespace"
    fi
fi

if [[ "$RABBITMQ_FOUND" == "true" ]]; then
    echo "RabbitMQ: Found in ${RABBITMQ_NS} namespace"
    if [[ "$RABBITMQ_NS" != "infra" ]]; then
        echo "  ⚠️  Needs migration to infra namespace"
    else
        echo "  ✅ Already in infra namespace"
    fi
fi

echo ""
echo "To migrate resources, you can:"
echo "1. Use Helm upgrade to change namespace (recommended for stateful resources)"
echo "2. Delete old installation and let ArgoCD recreate in infra namespace"
echo "3. Manual migration with data backup (see migrate-to-infra-namespace.sh)"

