#!/usr/bin/env bash
# Pre-commit validation script for devops-k8s repository
# Prevents common deployment issues from reaching production

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }

ERRORS=0
WARNINGS=0

log_info "Running devops-k8s pre-commit validation..."

# =============================================================================
# Check 1: Verify all values.yaml have required fields
# =============================================================================
log_info "Checking for required fields in values.yaml files..."

for values_file in apps/*/values.yaml; do
    app_name=$(basename $(dirname "$values_file"))
    
    # Check for migrations field
    if ! yq e '.migrations' "$values_file" >/dev/null 2>&1; then
        log_error "$values_file: Missing 'migrations' section"
        log_error "  Add: migrations:"
        log_error "         enabled: false"
        ERRORS=$((ERRORS + 1))
    else
        log_success "$app_name: migrations section present"
    fi
    
    # Check for verticalPodAutoscaling field
    if ! yq e '.verticalPodAutoscaling' "$values_file" >/dev/null 2>&1; then
        log_warning "$values_file: Missing 'verticalPodAutoscaling' section"
        WARNINGS=$((WARNINGS + 1))
    fi
done

# =============================================================================
# Check 2: Validate Helm templates render without errors
# =============================================================================
log_info "Validating Helm template rendering..."

for app_dir in apps/*/; do
    app_name=$(basename "$app_dir")
    values_file="$app_dir/values.yaml"
    
    if [[ -f "$values_file" ]]; then
        log_info "  Testing $app_name..."
        if ! helm template ./charts/app \
            --name-template "$app_name" \
            --namespace test \
            --values "$values_file" \
            --debug > /dev/null 2>&1; then
            log_error "$app_name: Helm template rendering failed"
            log_error "  Run: helm template ./charts/app --name-template $app_name --namespace test --values $values_file --debug"
            ERRORS=$((ERRORS + 1))
        else
            log_success "$app_name: Template renders successfully"
        fi
    fi
done

# =============================================================================
# Check 3: Validate resource limits are reasonable
# =============================================================================
log_info "Checking resource allocations..."

for values_file in apps/*/values.yaml; do
    app_name=$(basename $(dirname "$values_file"))
    
    # Check CPU requests
    cpu_req=$(yq e '.resources.requests.cpu' "$values_file" 2>/dev/null || echo "")
    cpu_limit=$(yq e '.resources.limits.cpu' "$values_file" 2>/dev/null || echo "")
    
    # Check memory requests
    mem_req=$(yq e '.resources.requests.memory' "$values_file" 2>/dev/null || echo "")
    mem_limit=$(yq e '.resources.limits.memory' "$values_file" 2>/dev/null || echo "")
    
    if [[ -z "$cpu_req" ]] || [[ "$cpu_req" == "null" ]]; then
        log_warning "$app_name: No CPU request defined"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    if [[ -z "$mem_req" ]] || [[ "$mem_req" == "null" ]]; then
        log_warning "$app_name: No memory request defined"
        WARNINGS=$((WARNINGS + 1))
    fi
    
    # Check max replicas
    max_replicas=$(yq e '.autoscaling.maxReplicas' "$values_file" 2>/dev/null || echo "1")
    if [[ "$max_replicas" != "null" ]] && [[ "$max_replicas" -gt 5 ]]; then
        log_warning "$app_name: High maxReplicas ($max_replicas) - may cause pod limit issues"
        WARNINGS=$((WARNINGS + 1))
    fi
done

# =============================================================================
# Check 4: Detect potential duplicate resources
# =============================================================================
log_info "Checking for potential duplicate deployments..."

# Check for multiple apps with same label patterns
declare -A app_labels
for values_file in apps/*/values.yaml; do
    app_name=$(basename $(dirname "$values_file"))
    image_repo=$(yq e '.image.repository' "$values_file" 2>/dev/null || echo "")
    
    if [[ -n "$image_repo" ]] && [[ "$image_repo" != "null" ]]; then
        base_image=$(basename "$image_repo")
        if [[ -v app_labels["$base_image"] ]]; then
            log_warning "Potential duplicate: $app_name and ${app_labels[$base_image]} use similar image: $base_image"
            WARNINGS=$((WARNINGS + 1))
        else
            app_labels["$base_image"]="$app_name"
        fi
    fi
done

# =============================================================================
# Check 5: VPA configuration safety
# =============================================================================
log_info "Validating VPA configurations..."

for values_file in apps/*/values.yaml; do
    app_name=$(basename $(dirname "$values_file"))
    
    vpa_enabled=$(yq e '.verticalPodAutoscaling.enabled' "$values_file" 2>/dev/null || echo "false")
    vpa_mode=$(yq e '.verticalPodAutoscaling.updateMode' "$values_file" 2>/dev/null || echo "Off")
    
    if [[ "$vpa_enabled" == "true" ]] && [[ "$vpa_mode" != "Off" ]]; then
        log_warning "$app_name: VPA enabled with updateMode '$vpa_mode'"
        log_warning "  Ensure metrics-server is running before deploying"
        log_warning "  Disable if metrics-server is unstable"
        WARNINGS=$((WARNINGS + 1))
    fi
done

# =============================================================================
# Check 6: Validate database configuration patterns
# =============================================================================
log_info "Checking database configurations..."

for values_file in apps/*/values.yaml; do
    app_name=$(basename $(dirname "$values_file"))
    env_secret=$(yq e '.envFromSecret' "$values_file" 2>/dev/null || echo "")
    
    if [[ -n "$env_secret" ]] && [[ "$env_secret" != "null" ]]; then
        log_success "$app_name: Uses secret '$env_secret' for environment"
        
        # Check if migrations are enabled but secret name doesn't match pattern
        migrations_enabled=$(yq e '.migrations.enabled' "$values_file" 2>/dev/null || echo "false")
        if [[ "$migrations_enabled" == "true" ]] && [[ ! "$env_secret" =~ -env$ ]]; then
            log_warning "$app_name: migrations enabled but secret name doesn't follow '*-env' pattern"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
done

# =============================================================================
# Check 7: Ingress TLS configuration
# =============================================================================
log_info "Validating ingress configurations..."

for values_file in apps/*/values.yaml; do
    app_name=$(basename $(dirname "$values_file"))
    
    ingress_enabled=$(yq e '.ingress.enabled' "$values_file" 2>/dev/null || echo "false")
    
    if [[ "$ingress_enabled" == "true" ]]; then
        tls_config=$(yq e '.ingress.tls' "$values_file" 2>/dev/null || echo "")
        cert_issuer=$(yq e '.ingress.annotations."cert-manager.io/cluster-issuer"' "$values_file" 2>/dev/null || echo "")
        
        if [[ -z "$tls_config" ]] || [[ "$tls_config" == "null" ]]; then
            log_warning "$app_name: Ingress enabled but no TLS configuration"
            WARNINGS=$((WARNINGS + 1))
        fi
        
        if [[ "$cert_issuer" != "letsencrypt-prod" ]]; then
            log_warning "$app_name: Not using 'letsencrypt-prod' issuer"
            WARNINGS=$((WARNINGS + 1))
        fi
    fi
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=========================================="
echo "Validation Summary"
echo "=========================================="

if [[ $ERRORS -eq 0 ]] && [[ $WARNINGS -eq 0 ]]; then
    log_success "All checks passed! ✓"
    exit 0
elif [[ $ERRORS -eq 0 ]]; then
    log_warning "Validation passed with $WARNINGS warning(s)"
    log_warning "Review warnings before deploying to production"
    exit 0
else
    log_error "Validation failed with $ERRORS error(s) and $WARNINGS warning(s)"
    log_error "Fix errors before committing"
    exit 1
fi
