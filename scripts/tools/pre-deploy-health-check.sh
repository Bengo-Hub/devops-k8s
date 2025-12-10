#!/bin/bash
# Pre-deployment health check script
# Validates application readiness before allowing deployment to proceed
# Exit code 0 = healthy, 1 = fail deployment

set -euo pipefail

APP_NAME="${1:-}"
NAMESPACE="${2:-}"
CHECK_TYPE="${3:-full}" # full, quick, or skip

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "[INFO] $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

if [[ -z "$APP_NAME" || -z "$NAMESPACE" ]]; then
    log_error "Usage: $0 <app-name> <namespace> [check-type]"
    exit 1
fi

log_info "Running pre-deployment health checks for $APP_NAME in namespace $NAMESPACE..."

# Skip checks if requested (for emergency deploys)
if [[ "$CHECK_TYPE" == "skip" ]]; then
    log_warning "Health checks skipped - proceeding with deployment"
    exit 0
fi

HEALTH_SCORE=0
REQUIRED_SCORE=80 # Must score 80% to pass

# =============================================================================
# Check 1: Verify namespace exists and has capacity (20 points)
# =============================================================================
log_info "Checking namespace capacity..."

if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
    log_error "Namespace $NAMESPACE does not exist"
    exit 1
fi

# Check pod count in namespace
POD_COUNT=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l)
if [[ $POD_COUNT -gt 20 ]]; then
    log_warning "Namespace $NAMESPACE has $POD_COUNT pods (high density)"
else
    log_success "Namespace capacity OK ($POD_COUNT pods)"
    HEALTH_SCORE=$((HEALTH_SCORE + 20))
fi

# =============================================================================
# Check 2: Check cluster-wide pod limit (20 points)
# =============================================================================
log_info "Checking cluster pod capacity..."

TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l)
RUNNING_PODS=$(kubectl get pods --all-namespaces --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
POD_LIMIT=110

if [[ $RUNNING_PODS -ge $POD_LIMIT ]]; then
    log_error "Cluster at pod limit: $RUNNING_PODS/$POD_LIMIT running pods"
    log_error "Run cleanup script: ./scripts/tools/cleanup-failed-pods.sh"
    exit 1
elif [[ $RUNNING_PODS -ge 100 ]]; then
    log_warning "Cluster near pod limit: $RUNNING_PODS/$POD_LIMIT"
    HEALTH_SCORE=$((HEALTH_SCORE + 10))
else
    log_success "Cluster pod capacity OK ($RUNNING_PODS/$POD_LIMIT)"
    HEALTH_SCORE=$((HEALTH_SCORE + 20))
fi

# =============================================================================
# Check 3: Verify no existing failed/pending pods for this app (20 points)
# =============================================================================
log_info "Checking for existing failed pods..."

FAILED_PODS=$(kubectl get pods -n "$NAMESPACE" -l "app=$APP_NAME" \
    --field-selector=status.phase!=Running,status.phase!=Succeeded \
    --no-headers 2>/dev/null | wc -l)

if [[ $FAILED_PODS -gt 0 ]]; then
    log_warning "Found $FAILED_PODS failed/pending pods for $APP_NAME"
    log_info "Cleaning up failed pods..."
    kubectl delete pods -n "$NAMESPACE" -l "app=$APP_NAME" \
        --field-selector=status.phase!=Running,status.phase!=Succeeded \
        --grace-period=0 --force 2>/dev/null || true
    sleep 5
    HEALTH_SCORE=$((HEALTH_SCORE + 10))
else
    log_success "No failed pods found for $APP_NAME"
    HEALTH_SCORE=$((HEALTH_SCORE + 20))
fi

# =============================================================================
# Check 4: Verify database connectivity (if applicable) (20 points)
# =============================================================================
if [[ "$CHECK_TYPE" == "full" ]]; then
    log_info "Checking database connectivity..."
    
    # Check if PostgreSQL is healthy
    if kubectl get pod -n infra postgresql-0 &>/dev/null; then
        PG_READY=$(kubectl get pod -n infra postgresql-0 -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null || echo "false")
        
        if [[ "$PG_READY" == "true" ]]; then
            log_success "PostgreSQL is healthy"
            HEALTH_SCORE=$((HEALTH_SCORE + 20))
        else
            log_warning "PostgreSQL is not ready"
            HEALTH_SCORE=$((HEALTH_SCORE + 10))
        fi
    else
        log_info "PostgreSQL not found - skipping check"
        HEALTH_SCORE=$((HEALTH_SCORE + 20))
    fi
else
    # Quick check - assume DB is OK
    HEALTH_SCORE=$((HEALTH_SCORE + 20))
fi

# =============================================================================
# Check 5: Verify required secrets exist (20 points)
# =============================================================================
log_info "Checking for required secrets..."

SECRET_NAME="${APP_NAME}-secrets"
if kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
    log_success "Secret $SECRET_NAME exists"
    HEALTH_SCORE=$((HEALTH_SCORE + 20))
elif kubectl get secret -n "$NAMESPACE" "${APP_NAME}-env" &>/dev/null; then
    log_success "Secret ${APP_NAME}-env exists"
    HEALTH_SCORE=$((HEALTH_SCORE + 20))
else
    log_warning "No secrets found for $APP_NAME (may not be required)"
    HEALTH_SCORE=$((HEALTH_SCORE + 15))
fi

# =============================================================================
# Final Score Evaluation
# =============================================================================
log_info "Health Check Score: $HEALTH_SCORE/100"

if [[ $HEALTH_SCORE -ge $REQUIRED_SCORE ]]; then
    log_success "✓ Pre-deployment health checks PASSED ($HEALTH_SCORE/100)"
    log_success "Proceeding with deployment of $APP_NAME"
    exit 0
else
    log_error "✗ Pre-deployment health checks FAILED ($HEALTH_SCORE/100, required: $REQUIRED_SCORE)"
    log_error "Deployment blocked - please fix issues and retry"
    exit 1
fi
