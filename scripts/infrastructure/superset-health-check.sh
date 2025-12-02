#!/usr/bin/env bash
set -euo pipefail

# Superset Deployment Health Check Script
# This script performs comprehensive health checks on Superset deployment

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
NAMESPACE=${SUPERSET_NAMESPACE:-default}
APP_NAME="superset"

log_section "Superset Deployment Health Check"

# Track overall health
HEALTH_STATUS=0

# Function to check component
check_component() {
    local component=$1
    local command=$2
    
    log_info "Checking ${component}..."
    if eval "${command}" >/dev/null 2>&1; then
        log_success "${component}: OK"
        return 0
    else
        log_error "${component}: FAILED"
        HEALTH_STATUS=1
        return 1
    fi
}

# 1. Check Prerequisites
log_section "1. Checking Prerequisites"

check_component "PostgreSQL" \
    "kubectl get pods -n infra -l app.kubernetes.io/name=postgresql --field-selector=status.phase=Running | grep -q Running"

check_component "Redis" \
    "kubectl get pods -n infra -l app.kubernetes.io/name=redis --field-selector=status.phase=Running | grep -q Running"

check_component "ArgoCD" \
    "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server --field-selector=status.phase=Running | grep -q Running"

# 2. Check Secrets
log_section "2. Checking Secrets"

if kubectl get secret superset-secrets -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_success "Secret 'superset-secrets' exists"
    
    # Check required keys
    REQUIRED_KEYS=("DATABASE_PASSWORD" "SECRET_KEY" "ADMIN_USERNAME" "ADMIN_PASSWORD")
    for key in "${REQUIRED_KEYS[@]}"; do
        if kubectl get secret superset-secrets -n "${NAMESPACE}" -o jsonpath="{.data.${key}}" >/dev/null 2>&1; then
            log_success "  Key '${key}': ✓"
        else
            log_error "  Key '${key}': ✗ (missing)"
            HEALTH_STATUS=1
        fi
    done
else
    log_error "Secret 'superset-secrets' not found"
    log_warn "Run: ./create-superset-secrets.sh"
    HEALTH_STATUS=1
fi

# 3. Check Database
log_section "3. Checking Database"

if kubectl get secret superset-secrets -n "${NAMESPACE}" >/dev/null 2>&1; then
    PG_POD=$(kubectl get pod -n infra -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}')
    
    if [ -n "${PG_POD}" ]; then
        log_info "Checking if Superset database exists..."
        if kubectl exec -n infra "${PG_POD}" -- psql -U postgres -lqt | cut -d \| -f 1 | grep -qw superset; then
            log_success "Database 'superset' exists"
        else
            log_error "Database 'superset' not found"
            log_warn "Run: ./create-superset-database.sh"
            HEALTH_STATUS=1
        fi
    else
        log_error "PostgreSQL pod not found"
        HEALTH_STATUS=1
    fi
fi

# 4. Check ArgoCD Application
log_section "4. Checking ArgoCD Application"

if kubectl get application superset -n argocd >/dev/null 2>&1; then
    log_success "ArgoCD Application 'superset' exists"
    
    # Check sync status
    SYNC_STATUS=$(kubectl get application superset -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS_APP=$(kubectl get application superset -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
    
    log_info "  Sync Status: ${SYNC_STATUS}"
    log_info "  Health Status: ${HEALTH_STATUS_APP}"
    
    if [ "${SYNC_STATUS}" != "Synced" ]; then
        log_warn "  Application is not synced"
    fi
    
    if [ "${HEALTH_STATUS_APP}" != "Healthy" ]; then
        log_warn "  Application is not healthy"
    fi
else
    log_error "ArgoCD Application 'superset' not found"
    HEALTH_STATUS=1
fi

# 5. Check Deployments
log_section "5. Checking Deployments"

DEPLOYMENTS=("superset" "superset-worker" "superset-beat")

for deployment in "${DEPLOYMENTS[@]}"; do
    if kubectl get deployment "${deployment}" -n "${NAMESPACE}" >/dev/null 2>&1; then
        READY=$(kubectl get deployment "${deployment}" -n "${NAMESPACE}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
        DESIRED=$(kubectl get deployment "${deployment}" -n "${NAMESPACE}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
        
        if [ "${READY}" = "${DESIRED}" ] && [ "${READY}" != "0" ]; then
            log_success "Deployment '${deployment}': ${READY}/${DESIRED} ready"
        else
            log_error "Deployment '${deployment}': ${READY}/${DESIRED} ready"
            HEALTH_STATUS=1
        fi
    else
        log_error "Deployment '${deployment}' not found"
        HEALTH_STATUS=1
    fi
done

# 6. Check Pods
log_section "6. Checking Pods"

POD_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l app="${APP_NAME}" --field-selector=status.phase=Running 2>/dev/null | grep -c Running || echo "0")

if [ "${POD_COUNT}" -gt 0 ]; then
    log_success "Found ${POD_COUNT} running Superset pod(s)"
    
    # List pods
    kubectl get pods -n "${NAMESPACE}" -l app="${APP_NAME}" -o wide
    
    # Check for restarts
    log_info "Checking for pod restarts..."
    RESTART_COUNT=$(kubectl get pods -n "${NAMESPACE}" -l app="${APP_NAME}" -o jsonpath='{range .items[*]}{.status.containerStatuses[*].restartCount}{"\n"}{end}' 2>/dev/null | awk '{sum+=$1} END {print sum+0}')
    
    if [ "${RESTART_COUNT}" -gt 0 ]; then
        log_warn "Total restarts across all pods: ${RESTART_COUNT}"
    else
        log_success "No pod restarts detected"
    fi
else
    log_error "No running Superset pods found"
    HEALTH_STATUS=1
fi

# 7. Check Services
log_section "7. Checking Services"

if kubectl get service "${APP_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    CLUSTER_IP=$(kubectl get service "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.clusterIP}')
    PORT=$(kubectl get service "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.ports[0].port}')
    log_success "Service '${APP_NAME}': ${CLUSTER_IP}:${PORT}"
else
    log_error "Service '${APP_NAME}' not found"
    HEALTH_STATUS=1
fi

# 8. Check Ingress
log_section "8. Checking Ingress"

if kubectl get ingress "${APP_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    HOSTS=$(kubectl get ingress "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.rules[*].host}')
    log_success "Ingress '${APP_NAME}': ${HOSTS}"
    
    # Check TLS
    TLS_HOSTS=$(kubectl get ingress "${APP_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.tls[*].hosts[*]}' 2>/dev/null || echo "")
    if [ -n "${TLS_HOSTS}" ]; then
        log_success "  TLS enabled for: ${TLS_HOSTS}"
    else
        log_warn "  TLS not configured"
    fi
else
    log_error "Ingress '${APP_NAME}' not found"
    HEALTH_STATUS=1
fi

# 9. Check HPA
log_section "9. Checking Horizontal Pod Autoscaler"

if kubectl get hpa -n "${NAMESPACE}" | grep -q "${APP_NAME}"; then
    log_success "HPA configured for Superset"
    kubectl get hpa -n "${NAMESPACE}" | grep "${APP_NAME}"
else
    log_warn "No HPA found (may not be enabled)"
fi

# 10. Check Recent Events
log_section "10. Recent Events"

log_info "Last 10 events for Superset:"
kubectl get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | grep -i superset | tail -10 || log_info "No recent events"

# 11. Resource Usage
log_section "11. Resource Usage"

log_info "Pod resource usage:"
kubectl top pods -n "${NAMESPACE}" -l app="${APP_NAME}" 2>/dev/null || log_warn "Metrics server not available"

# 12. Connectivity Tests
log_section "12. Connectivity Tests"

log_info "Testing database connectivity..."
if kubectl get pods -n "${NAMESPACE}" -l app="${APP_NAME}" --field-selector=status.phase=Running | grep -q Running; then
    POD=$(kubectl get pods -n "${NAMESPACE}" -l app="${APP_NAME}" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
    
    if kubectl exec -n "${NAMESPACE}" "${POD}" -- timeout 5 nc -zv postgresql.infra.svc.cluster.local 5432 >/dev/null 2>&1; then
        log_success "Database connectivity: OK"
    else
        log_error "Database connectivity: FAILED"
        HEALTH_STATUS=1
    fi
    
    log_info "Testing Redis connectivity..."
    if kubectl exec -n "${NAMESPACE}" "${POD}" -- timeout 5 nc -zv redis-master.infra.svc.cluster.local 6379 >/dev/null 2>&1; then
        log_success "Redis connectivity: OK"
    else
        log_error "Redis connectivity: FAILED"
        HEALTH_STATUS=1
    fi
fi

# Summary
log_section "Health Check Summary"

if [ ${HEALTH_STATUS} -eq 0 ]; then
    log_success "All checks passed! Superset deployment is healthy."
else
    log_error "Some checks failed. Please review the output above."
    echo ""
    log_info "Common troubleshooting steps:"
    echo "  1. Check pod logs: kubectl logs -n ${NAMESPACE} -l app=${APP_NAME} --tail=100"
    echo "  2. Describe pod: kubectl describe pod -n ${NAMESPACE} <pod-name>"
    echo "  3. Check events: kubectl get events -n ${NAMESPACE} --sort-by='.lastTimestamp'"
    echo "  4. Restart deployment: kubectl rollout restart deployment ${APP_NAME} -n ${NAMESPACE}"
    echo "  5. Review documentation: devops-k8s/docs/superset-deployment.md"
fi

exit ${HEALTH_STATUS}

