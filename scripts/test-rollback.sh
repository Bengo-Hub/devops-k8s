#!/bin/bash

# =============================================================================
# BengoERP Rollback Testing Script
# =============================================================================
# This script tests automated rollback functionality by simulating failures
# and verifying that the system can recover properly.
#
# Features:
# - Simulate various failure scenarios
# - Test automated rollback triggers
# - Verify rollback success
# - Generate rollback testing reports
# =============================================================================

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-erp}"
APP_NAME="${APP_NAME:-erp-api}"
TEST_DURATION="${TEST_DURATION:-300}"
FAILURE_SCENARIOS="${FAILURE_SCENARIOS:-pod_crash,resource_exhaustion,config_error}"
BACKUP_ENABLED="${BACKUP_ENABLED:-true}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_critical() { echo -e "${RED}[CRITICAL]${NC} $1"; }

# Test result tracking
TEST_RESULTS=()
FAILED_TESTS=()
PASSED_TESTS=()

# Record test result
record_test_result() {
    local test_name=$1
    local status=$2
    local details=$3

    TEST_RESULTS+=("$test_name: $status - $details")

    if [[ "$status" == "PASSED" ]]; then
        PASSED_TESTS+=("$test_name")
        log_success "✓ $test_name: $details"
    else
        FAILED_TESTS+=("$test_name")
        log_error "✗ $test_name: $details"
    fi
}

# Backup current state
backup_current_state() {
    if [[ "$BACKUP_ENABLED" != "true" ]]; then
        return 0
    fi

    log_info "Creating backup of current state..."

    local backup_dir="/tmp/rollback-test-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"

    # Backup deployment configurations
    kubectl get deployment "$APP_NAME" -n "$NAMESPACE" -o yaml > "$backup_dir/deployment.yaml" 2>/dev/null || true

    # Backup application configurations
    kubectl get application "$APP_NAME" -n argocd -o yaml > "$backup_dir/application.yaml" 2>/dev/null || true

    # Backup current metrics
    ./scripts/deployment-metrics.sh collect > "$backup_dir/metrics.json" 2>/dev/null || true

    log_success "Backup created at $backup_dir"
    echo "$backup_dir"
}

# Restore from backup
restore_from_backup() {
    local backup_dir=$1

    if [[ ! -d "$backup_dir" ]]; then
        log_error "Backup directory $backup_dir not found"
        return 1
    fi

    log_info "Restoring from backup $backup_dir..."

    # Restore deployment if backup exists
    if [[ -f "$backup_dir/deployment.yaml" ]]; then
        kubectl apply -f "$backup_dir/deployment.yaml"
    fi

    # Restore application configuration if backup exists
    if [[ -f "$backup_dir/application.yaml" ]]; then
        kubectl apply -f "$backup_dir/application.yaml"
    fi

    log_success "Restore completed"
}

# Wait for deployment to stabilize
wait_for_deployment_ready() {
    local app_name=$1
    local namespace=$2
    local timeout=${3:-300}

    log_info "Waiting for $app_name deployment to be ready..."

    if kubectl wait --for=condition=available --timeout="${timeout}s" deployment/"$app_name" -n "$namespace"; then
        log_success "$app_name deployment is ready"
        return 0
    else
        log_error "$app_name deployment failed to become ready within ${timeout}s"
        return 1
    fi
}

# Simulate pod crash failure
test_pod_crash_failure() {
    local test_name="pod_crash_failure"
    log_info "Testing $test_name scenario..."

    local backup_dir
    backup_dir=$(backup_current_state)

    # Simulate pod crash by deleting pods
    local pod_count
    pod_count=$(kubectl get pods -l app="$APP_NAME" -n "$NAMESPACE" --no-headers | wc -l)

    if [[ $pod_count -eq 0 ]]; then
        record_test_result "$test_name" "SKIPPED" "No pods found to crash"
        return 0
    fi

    log_info "Crashing $pod_count pods for $APP_NAME..."

    # Delete all pods to simulate crash
    kubectl delete pods -l app="$APP_NAME" -n "$NAMESPACE" --force --grace-period=0

    # Wait for pods to be recreated
    sleep 30

    # Check if deployment recovers
    if wait_for_deployment_ready "$APP_NAME" "$NAMESPACE" 120; then
        # Verify rollback didn't trigger (pods should recover automatically)
        local ready_pods
        ready_pods=$(kubectl get deployment "$APP_NAME" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

        if [[ $ready_pods -gt 0 ]]; then
            record_test_result "$test_name" "PASSED" "Pods recovered successfully without rollback"
        else
            record_test_result "$test_name" "FAILED" "Pods failed to recover"
        fi
    else
        # If auto-recovery fails, test rollback
        log_info "Auto-recovery failed, testing rollback..."

        if ./scripts/deployment-metrics.sh rollback "$APP_NAME"; then
            if wait_for_deployment_ready "$APP_NAME" "$NAMESPACE" 180; then
                record_test_result "$test_name" "PASSED" "Rollback triggered successfully and deployment recovered"
            else
                record_test_result "$test_name" "FAILED" "Rollback failed to recover deployment"
            fi
        else
            record_test_result "$test_name" "FAILED" "Rollback script failed"
        fi
    fi

    # Restore from backup
    restore_from_backup "$backup_dir"
}

# Simulate resource exhaustion
test_resource_exhaustion() {
    local test_name="resource_exhaustion"
    log_info "Testing $test_name scenario..."

    local backup_dir
    backup_dir=$(backup_current_state)

    # Temporarily set very low resource limits to cause OOM
    log_info "Setting low resource limits to simulate exhaustion..."

    # Patch deployment with minimal resources
    kubectl patch deployment "$APP_NAME" -n "$NAMESPACE" -p '{"spec":{"template":{"spec":{"containers":[{"name":"'$APP_NAME'","resources":{"limits":{"memory":"50Mi"}}}]}}}}}'

    # Wait for OOM events
    sleep 60

    # Check if OOM occurred
    local oom_count
    oom_count=$(kubectl get events -n "$NAMESPACE" --field-selector reason=OOMKilling | grep -c "$APP_NAME" || echo "0")

    if [[ $oom_count -gt 0 ]]; then
        log_info "OOM events detected, checking recovery..."

        # Restore normal resource limits
        kubectl patch deployment "$APP_NAME" -n "$NAMESPACE" -p '{"spec":{"template":{"spec":{"containers":[{"name":"'$APP_NAME'","resources":{"limits":{"memory":"1Gi"}}}]}}}}}'

        # Wait for recovery
        if wait_for_deployment_ready "$APP_NAME" "$NAMESPACE" 120; then
            record_test_result "$test_name" "PASSED" "Resource exhaustion simulated and recovery successful"
        else
            record_test_result "$test_name" "FAILED" "Failed to recover from resource exhaustion"
        fi
    else
        log_warning "No OOM events detected, may need to adjust test parameters"
        record_test_result "$test_name" "SKIPPED" "No OOM events detected"
    fi

    # Restore from backup
    restore_from_backup "$backup_dir"
}

# Simulate configuration error
test_config_error() {
    local test_name="config_error"
    log_info "Testing $test_name scenario..."

    local backup_dir
    backup_dir=$(backup_current_state)

    # Simulate configuration error by updating values with invalid data
    log_info "Introducing configuration error..."

    # Create a temporary invalid values file
    local temp_values="/tmp/invalid-values.yaml"
    cat > "$temp_values" << EOF
# Intentionally invalid configuration
invalid:
  yaml: syntax: [
    unclosed
  array

# Missing required fields
image:
  repository: invalid/repo
  # Missing tag

# Invalid resource configuration
resources:
  limits:
    cpu: invalid-cpu-format
EOF

    # Try to apply invalid configuration (this should fail)
    if ! kubectl apply -f "$temp_values" 2>/dev/null; then
        log_info "Invalid configuration rejected as expected"

        # Test rollback capability
        if ./scripts/deployment-metrics.sh rollback "$APP_NAME"; then
            if wait_for_deployment_ready "$APP_NAME" "$NAMESPACE" 120; then
                record_test_result "$test_name" "PASSED" "Configuration error detected and rollback successful"
            else
                record_test_result "$test_name" "FAILED" "Configuration error detected but rollback failed"
            fi
        else
            record_test_result "$test_name" "FAILED" "Configuration error detected but rollback script failed"
        fi
    else
        log_warning "Invalid configuration was accepted unexpectedly"
        record_test_result "$test_name" "SKIPPED" "Invalid configuration was not rejected"
    fi

    # Clean up
    rm -f "$temp_values"

    # Restore from backup
    restore_from_backup "$backup_dir"
}

# Test ArgoCD sync failure
test_argocd_sync_failure() {
    local test_name="argocd_sync_failure"
    log_info "Testing $test_name scenario..."

    local backup_dir
    backup_dir=$(backup_current_state)

    # Simulate ArgoCD sync failure by breaking git access temporarily
    log_info "Simulating ArgoCD sync failure..."

    # This would require temporarily breaking git access or repo connectivity
    # For safety, we'll simulate by checking current sync status

    local sync_status
    sync_status=$(kubectl get application "$APP_NAME" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")

    if [[ "$sync_status" == "Synced" ]]; then
        log_info "ArgoCD sync is healthy, cannot simulate failure easily"
        record_test_result "$test_name" "SKIPPED" "ArgoCD sync is currently healthy"
    else
        log_warning "ArgoCD sync status: $sync_status"

        # Try to trigger manual sync to test recovery
        if kubectl exec deployment/argocd-server -n argocd -- argocd app sync "$APP_NAME"; then
            if wait_for_deployment_ready "$APP_NAME" "$NAMESPACE" 120; then
                record_test_result "$test_name" "PASSED" "ArgoCD sync issue resolved successfully"
            else
                record_test_result "$test_name" "FAILED" "Failed to resolve ArgoCD sync issue"
            fi
        else
            record_test_result "$test_name" "FAILED" "ArgoCD sync command failed"
        fi
    fi

    # Restore from backup
    restore_from_backup "$backup_dir"
}

# Generate test report
generate_test_report() {
    local report_file="/tmp/rollback-test-report-$(date +%Y%m%d_%H%M%S).md"

    cat > "$report_file" << EOF
# BengoERP Rollback Testing Report

**Test Date**: $(date)
**Application**: $APP_NAME
**Namespace**: $NAMESPACE
**Test Duration**: $TEST_DURATION seconds

## Test Summary

- **Total Tests**: ${#TEST_RESULTS[@]}
- **Passed**: ${#PASSED_TESTS[@]}
- **Failed**: ${#FAILED_TESTS[@]}
- **Skipped**: $((${#TEST_RESULTS[@]} - ${#PASSED_TESTS[@]} - ${#FAILED_TESTS[@]}))

## Test Results

EOF

    for result in "${TEST_RESULTS[@]}"; do
        echo "- $result" >> "$report_file"
    done

    cat >> "$report_file" << EOF

## Recommendations

EOF

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        cat >> "$report_file" << EOF
**Critical Issues Found:**
- Review failed test scenarios
- Implement fixes for rollback mechanisms
- Update monitoring thresholds if needed
EOF
    else
        cat >> "$report_file" << EOF
**All Tests Passed:**
- Rollback mechanisms are functioning correctly
- No immediate action required
- Consider scheduling regular rollback testing
EOF
    fi

    log_success "Test report generated: $report_file"
    echo "$report_file"
}

# Main test execution
main() {
    log_info "Starting BengoERP rollback testing for $APP_NAME..."

    # Parse failure scenarios
    IFS=',' read -ra SCENARIOS <<< "$FAILURE_SCENARIOS"

    for scenario in "${SCENARIOS[@]}"; do
        case "$scenario" in
            "pod_crash")
                test_pod_crash_failure
                ;;
            "resource_exhaustion")
                test_resource_exhaustion
                ;;
            "config_error")
                test_config_error
                ;;
            "argocd_sync_failure")
                test_argocd_sync_failure
                ;;
            *)
                log_warning "Unknown test scenario: $scenario"
                ;;
        esac

        # Brief pause between tests
        sleep 10
    done

    # Generate report
    generate_test_report

    # Summary
    echo ""
    log_info "Rollback testing completed:"
    echo "  ✓ Passed: ${#PASSED_TESTS[@]}"
    echo "  ✗ Failed: ${#FAILED_TESTS[@]}"
    echo "  ○ Skipped: $((${#TEST_RESULTS[@]} - ${#PASSED_TESTS[@]} - ${#FAILED_TESTS[@]}))"

    if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
        log_error "Some tests failed. Review the test report for details."
        exit 1
    else
        log_success "All rollback tests passed successfully!"
        exit 0
    fi
}

# Run main function with all arguments
main "$@"
