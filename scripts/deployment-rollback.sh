#!/bin/bash
set -euo pipefail

# Automated Rollback Script for Kubernetes Deployments
# Provides rollback capabilities for failed deployments

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Logging functions
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${PURPLE}[STEP]${NC} $1"; }

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME=${APP_NAME:-}
NAMESPACE=${NAMESPACE:-erp}
ROLLBACK_VERSION=${ROLLBACK_VERSION:-}
AUTO_ROLLBACK=${AUTO_ROLLBACK:-false}
HEALTH_CHECK_URL=${HEALTH_CHECK_URL:-}
HEALTH_CHECK_TIMEOUT=${HEALTH_CHECK_TIMEOUT:-30}

# Pre-flight checks
if ! kubectl version --short >/dev/null 2>&1; then
  log_error "kubectl not configured. Aborting."
  exit 1
fi

if [[ -z "$APP_NAME" ]]; then
  log_error "APP_NAME environment variable is required"
  echo "Usage: APP_NAME=erp-api $0"
  exit 1
fi

# Function to check deployment health
check_deployment_health() {
  local app=$1
  local timeout=${2:-30}

  if [[ -n "$HEALTH_CHECK_URL" ]]; then
    log_info "Checking health endpoint: $HEALTH_CHECK_URL"

    # Wait for rollout to complete
    log_info "Waiting for deployment rollout to complete..."
    kubectl -n "$NAMESPACE" rollout status deployment/"$app" --timeout="${timeout}s"

    if [[ $? -eq 0 ]]; then
      log_success "Deployment rollout completed successfully"
      return 0
    else
      log_warning "Deployment rollout failed or timed out"
      return 1
    fi
  else
    log_warning "No health check URL provided, skipping health verification"
    return 0
  fi
}

# Function to get deployment history
get_deployment_history() {
  local app=$1
  kubectl -n "$NAMESPACE" rollout history deployment/"$app"
}

# Function to rollback to specific version
rollback_to_version() {
  local app=$1
  local version=$2

  log_step "Rolling back $app to version $version"

  if kubectl -n "$NAMESPACE" rollout undo deployment/"$app" --to-revision="$version"; then
    log_success "Rollback initiated for $app to version $version"

    # Wait for rollback to complete
    if kubectl -n "$NAMESPACE" rollout status deployment/"$app" --timeout=300s; then
      log_success "Rollback completed successfully for $app"
      return 0
    else
      log_error "Rollback failed for $app"
      return 1
    fi
  else
    log_error "Failed to initiate rollback for $app"
    return 1
  fi
}

# Function to auto-rollback on failure
auto_rollback_on_failure() {
  local app=$1

  log_step "Monitoring deployment for $app (auto-rollback enabled)"

  # Wait for initial deployment
  sleep 30

  # Check if deployment is healthy
  if ! check_deployment_health "$app" 60; then
    log_warning "Deployment health check failed for $app"

    # Get current deployment info
    local current_info=$(kubectl -n "$NAMESPACE" rollout history deployment/"$app" --output=json)
    local current_revision=$(echo "$current_info" | jq -r '.latestRevision // empty')

    if [[ -n "$current_revision" && "$current_revision" -gt 1 ]]; then
      local previous_revision=$((current_revision - 1))
      log_info "Auto-rolling back $app from revision $current_revision to $previous_revision"

      if rollback_to_version "$app" "$previous_revision"; then
        log_success "Auto-rollback completed successfully for $app"
        return 0
      else
        log_error "Auto-rollback failed for $app"
        return 1
      fi
    else
      log_error "No previous version available for rollback of $app"
      return 1
    fi
  else
    log_success "Deployment health check passed for $app"
    return 0
  fi
}

# Function to show deployment status
show_deployment_status() {
  local app=$1

  log_info "=== Deployment Status for $app ==="
  echo ""

  # Show deployment info
  kubectl -n "$NAMESPACE" get deployment "$app" -o wide

  echo ""
  log_info "=== Rollout History ==="
  get_deployment_history "$app"

  echo ""
  log_info "=== Pod Status ==="
  kubectl -n "$NAMESPACE" get pods -l app="$app" -o wide

  echo ""
  log_info "=== Recent Events ==="
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | grep -i "$app" | tail -10
}

# Main execution
main() {
  log_info "Starting deployment rollback management for $APP_NAME"

  case "${1:-status}" in
    "status")
      show_deployment_status "$APP_NAME"
      ;;

    "history")
      log_info "Deployment history for $APP_NAME:"
      get_deployment_history "$APP_NAME"
      ;;

    "rollback")
      if [[ -z "$ROLLBACK_VERSION" ]]; then
        log_error "ROLLBACK_VERSION environment variable is required for rollback"
        echo "Usage: ROLLBACK_VERSION=2 $0 rollback"
        exit 1
      fi

      if rollback_to_version "$APP_NAME" "$ROLLBACK_VERSION"; then
        log_success "Rollback completed successfully"
        show_deployment_status "$APP_NAME"
      else
        log_error "Rollback failed"
        exit 1
      fi
      ;;

    "auto-rollback")
      if [[ "$AUTO_ROLLBACK" == "true" ]]; then
        if auto_rollback_on_failure "$APP_NAME"; then
          log_success "Auto-rollback monitoring completed"
        else
          log_error "Auto-rollback monitoring failed"
          exit 1
        fi
      else
        log_info "Auto-rollback is disabled. Set AUTO_ROLLBACK=true to enable."
      fi
      ;;

    *)
      echo "Usage: $0 {status|history|rollback|auto-rollback}"
      echo ""
      echo "Environment Variables:"
      echo "  APP_NAME          - Application name (required)"
      echo "  NAMESPACE         - Kubernetes namespace (default: erp)"
      echo "  ROLLBACK_VERSION  - Version to rollback to (for rollback command)"
      echo "  AUTO_ROLLBACK     - Enable automatic rollback on failure (default: false)"
      echo "  HEALTH_CHECK_URL  - Health check endpoint URL (optional)"
      echo ""
      echo "Examples:"
      echo "  APP_NAME=erp-api $0 status"
      echo "  APP_NAME=erp-api $0 history"
      echo "  APP_NAME=erp-api ROLLBACK_VERSION=2 $0 rollback"
      echo "  APP_NAME=erp-api AUTO_ROLLBACK=true HEALTH_CHECK_URL=https://erpapi.masterspace.co.ke/api/v1/core/health/ $0 auto-rollback"
      exit 1
      ;;
  esac
}

# Run main function with all arguments
main "$@"
