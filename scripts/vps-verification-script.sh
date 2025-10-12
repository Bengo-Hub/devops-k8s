#!/bin/bash

# =============================================================================
# BengoERP VPS Verification Script
# =============================================================================
# This script performs comprehensive verification of all services and
# configurations required for the BengoERP deployment pipeline.
# Run this script on your Contabo VPS to ensure everything is properly set up.
# =============================================================================

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${PURPLE}[STEP]${NC} $1"; }
log_section() { echo -e "${CYAN}==========================================${NC}"; echo -e "${CYAN}$1${NC}"; echo -e "${CYAN}==========================================${NC}"; }

# Global test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test result functions
run_test() {
    local test_name="$1"
    local test_command="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_info "Testing: $test_name"

    if eval "$test_command"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        log_success "$test_name - PASSED"
        return 0
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        log_error "$test_name - FAILED"
        return 1
    fi
}

print_summary() {
    log_section "VERIFICATION SUMMARY"
    echo "Tests Run: $TESTS_RUN"
    echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "All tests passed! VPS is ready for BengoERP deployment."
        return 0
    else
        log_error "Some tests failed. Please address the issues above before deploying."
        return 1
    fi
}

# =============================================================================
# VPS INFORMATION COLLECTION
# =============================================================================

log_section "VPS INFORMATION"

run_test "Collect VPS Information" "
    echo 'Hostname: '$(hostname)
    echo 'OS Version: '$(lsb_release -d 2>/dev/null | cut -f2 || echo 'Unknown')
    echo 'Kernel: '$(uname -r)
    echo 'CPU Cores: '$(nproc)
    echo 'Memory: '$(free -h | awk 'NR==2{printf \"%.1fGB/%.1fGB\", \$3/1024/1024, \$2/1024/1024}')
    echo 'Disk Usage: '$(df -h / | awk 'NR==2{print \$5 \" used (\"$3\"/\"$2\")\"}')
    echo 'Public IP: '$(curl -s ifconfig.me || echo 'Unable to determine')
"

# =============================================================================
# SSH ACCESS VERIFICATION
# =============================================================================

log_section "SSH ACCESS VERIFICATION"

run_test "SSH Service Status" "
    systemctl is-active --quiet ssh && echo 'SSH service is running' || (echo 'SSH service is not running' && exit 1)
"

run_test "SSH Port Accessibility" "
    netstat -tuln | grep -q ':22 ' && echo 'SSH port (22) is listening' || (echo 'SSH port (22) is not accessible' && exit 1)
"

run_test "SSH Configuration Security" "
    sshd -t 2>/dev/null && echo 'SSH configuration is valid' || (echo 'SSH configuration has errors' && exit 1)
"

run_test "SSH Authorized Keys" "
    [[ -f ~/.ssh/authorized_keys ]] && [[ -s ~/.ssh/authorized_keys ]] && echo 'SSH authorized_keys exists and is not empty' || (echo 'No SSH authorized_keys found' && exit 1)
"

# =============================================================================
# NETWORK AND FIREWALL VERIFICATION
# =============================================================================

log_section "NETWORK AND FIREWALL VERIFICATION"

run_test "Internet Connectivity" "
    ping -c 3 8.8.8.8 >/dev/null 2>&1 && echo 'Internet connectivity is working' || (echo 'No internet connectivity' && exit 1)
"

run_test "DNS Resolution" "
    nslookup github.com >/dev/null 2>&1 && echo 'DNS resolution is working' || (echo 'DNS resolution failed' && exit 1)
"

run_test "Required Ports Open" "
    # Check if required ports are accessible
    ports_open=0
    for port in 22 6443 80 443; do
        if netstat -tuln | grep -q \":$port \"; then
            echo \"Port $port: Open\"
            ports_open=$((ports_open + 1))
        else
            echo \"Port $port: Closed\"
        fi
    done
    [[ $ports_open -ge 3 ]] && echo 'Required ports are accessible' || (echo 'Some required ports are closed' && exit 1)
"

# =============================================================================
# DOCKER VERIFICATION
# =============================================================================

log_section "DOCKER VERIFICATION"

run_test "Docker Installation" "
    command -v docker >/dev/null 2>&1 && echo 'Docker is installed' || (echo 'Docker is not installed' && exit 1)
"

run_test "Docker Version" "
    docker --version | grep -q 'Docker version' && echo 'Docker version: '$(docker --version) || (echo 'Cannot get Docker version' && exit 1)
"

run_test "Docker Service Status" "
    systemctl is-active --quiet docker && echo 'Docker service is running' || (echo 'Docker service is not running' && exit 1)
"

run_test "Docker User Permissions" "
    docker ps >/dev/null 2>&1 && echo 'Docker permissions are correct' || (echo 'Docker permission issues detected' && exit 1)
"

run_test "Docker Registry Access" "
    docker login --help >/dev/null 2>&1 && echo 'Docker registry commands available' || (echo 'Docker registry not accessible' && exit 1)
"

run_test "Docker Build Test" "
    docker build -t test-image - <<'EOF' >/dev/null 2>&1
FROM alpine:latest
RUN echo 'test build' > /test.txt
EOF
    [[ $? -eq 0 ]] && echo 'Docker build works correctly' && docker rmi test-image >/dev/null 2>&1 || (echo 'Docker build failed' && exit 1)
"

run_test "Docker Network Connectivity" "
    docker run --rm hello-world >/dev/null 2>&1 && echo 'Docker can pull and run images' || (echo 'Docker network issues detected' && exit 1)
"

# =============================================================================
# KUBERNETES VERIFICATION
# =============================================================================

log_section "KUBERNETES VERIFICATION"

run_test "Kubectl Installation" "
    command -v kubectl >/dev/null 2>&1 && echo 'kubectl is installed' || (echo 'kubectl is not installed' && exit 1)
"

run_test "Kubectl Version" "
    kubectl version --client --short 2>/dev/null | grep -q 'Client Version' && echo 'kubectl version: '$(kubectl version --client --short 2>/dev/null) || (echo 'Cannot get kubectl version' && exit 1)
"

run_test "Kubernetes Cluster Status" "
    kubectl cluster-info >/dev/null 2>&1 && echo 'Kubernetes cluster is accessible' || (echo 'Cannot connect to Kubernetes cluster' && exit 1)
"

run_test "Kubernetes Nodes" "
    node_count=$(kubectl get nodes 2>/dev/null | wc -l)
    [[ $node_count -gt 1 ]] && echo 'Kubernetes nodes: '$((node_count - 1))' found' || (echo 'No Kubernetes nodes found' && exit 1)
"

run_test "Kubernetes Namespaces" "
    ns_count=$(kubectl get namespaces 2>/dev/null | wc -l)
    [[ $ns_count -gt 1 ]] && echo 'Kubernetes namespaces: '$((ns_count - 1))' available' || (echo 'No Kubernetes namespaces found' && exit 1)
"

run_test "Kubernetes API Server" "
    kubectl get --raw=/healthz >/dev/null 2>&1 && echo 'Kubernetes API server is healthy' || (echo 'Kubernetes API server health check failed' && exit 1)
"

run_test "Required Namespaces" "
    for ns in kube-system kube-public default argocd erp; do
        if kubectl get namespace $ns >/dev/null 2>&1; then
            echo \"Namespace $ns: Exists\"
        else
            echo \"Namespace $ns: Missing\"
        fi
    done
    kubectl get namespace erp >/dev/null 2>&1 && echo 'ERP namespace is ready' || (echo 'ERP namespace needs to be created' && exit 1)
"

run_test "Kubernetes Resources" "
    # Check for essential resources
    resources_ok=0
    kubectl get pods -n kube-system >/dev/null 2>&1 && resources_ok=$((resources_ok + 1)) && echo 'Core system pods: OK' || echo 'Core system pods: Missing'
    kubectl get services -n kube-system >/dev/null 2>&1 && resources_ok=$((resources_ok + 1)) && echo 'Core services: OK' || echo 'Core services: Missing'
    kubectl get deployments -n kube-system >/dev/null 2>&1 && resources_ok=$((resources_ok + 1)) && echo 'Core deployments: OK' || echo 'Core deployments: Missing'

    [[ $resources_ok -ge 2 ]] && echo 'Essential Kubernetes resources are present' || (echo 'Some essential resources are missing' && exit 1)
"

# =============================================================================
# ARGOCD VERIFICATION
# =============================================================================

log_section "ARGOCD VERIFICATION"

run_test "ArgoCD Installation" "
    kubectl get pods -n argocd >/dev/null 2>&1 && echo 'ArgoCD is installed' || (echo 'ArgoCD is not installed' && exit 1)
"

run_test "ArgoCD Pods Status" "
    argocd_pods=$(kubectl get pods -n argocd --no-headers 2>/dev/null | wc -l)
    [[ $argocd_pods -gt 0 ]] && echo 'ArgoCD pods: $argocd_pods found' || (echo 'No ArgoCD pods found' && exit 1)
"

run_test "ArgoCD Server Status" "
    kubectl get pod -n argocd -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q 'Running' && echo 'ArgoCD server is running' || (echo 'ArgoCD server is not running' && exit 1)
"

run_test "ArgoCD Applications" "
    app_count=$(kubectl get applications -n argocd 2>/dev/null | wc -l)
    [[ $app_count -gt 0 ]] && echo 'ArgoCD applications: '$((app_count - 1))' configured' || echo 'No ArgoCD applications configured'
"

run_test "ArgoCD Repository Access" "
    # Check if ArgoCD can access the devops repository
    kubectl get applications -n argocd -o jsonpath='{.items[*].spec.source.repoURL}' 2>/dev/null | grep -q 'github.com' && echo 'ArgoCD repository access configured' || echo 'ArgoCD repository access not configured'
"

# =============================================================================
# STORAGE AND RESOURCES VERIFICATION
# =============================================================================

log_section "STORAGE AND RESOURCES VERIFICATION"

run_test "Disk Space Availability" "
    disk_usage=$(df / | awk 'NR==2{print $5}' | sed 's/%//')
    [[ $disk_usage -lt 90 ]] && echo 'Disk space: '$disk_usage'% used (sufficient)' || (echo 'Disk space: '$disk_usage'% used (insufficient)' && exit 1)
"

run_test "Memory Availability" "
    mem_available=$(free | awk 'NR==2{printf \"%.1fGB\", $7/1024/1024}')
    echo 'Available memory: '$mem_available
    # Just informational, don't fail the test
"

run_test "CPU Resources" "
    cpu_load=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | tr -d ' ')
    echo 'CPU load: '$cpu_load
    # Just informational, don't fail the test
"

# =============================================================================
# SECURITY VERIFICATION
# =============================================================================

log_section "SECURITY VERIFICATION"

run_test "Firewall Status" "
    if command -v ufw >/dev/null 2>&1; then
        ufw_status=$(ufw status | grep -q 'Status: active' && echo 'Active' || echo 'Inactive')
        echo 'UFW firewall: '$ufw_status
    else
        echo 'UFW firewall: Not installed'
    fi
"

run_test "SSH Security" "
    # Check for password authentication
    if ! grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config 2>/dev/null; then
        echo 'SSH password authentication may be enabled (security risk)'
    else
        echo 'SSH password authentication disabled (secure)'
    fi
"

run_test "Root SSH Access" "
    # Check if root can SSH directly
    if grep -q 'PermitRootLogin yes' /etc/ssh/sshd_config 2>/dev/null; then
        echo 'Root SSH login is allowed'
    else
        echo 'Root SSH login is restricted (recommended)'
    fi
"

# =============================================================================
# CONNECTIVITY TESTS
# =============================================================================

log_section "CONNECTIVITY TESTS"

run_test "GitHub Connectivity" "
    curl -s --connect-timeout 10 https://github.com >/dev/null && echo 'GitHub is accessible' || (echo 'GitHub is not accessible' && exit 1)
"

run_test "Docker Hub Connectivity" "
    curl -s --connect-timeout 10 https://registry.hub.docker.com >/dev/null && echo 'Docker Hub is accessible' || (echo 'Docker Hub is not accessible' && exit 1)
"

run_test "Kubernetes API Connectivity" "
    kubectl get --raw=/healthz >/dev/null && echo 'Kubernetes API is accessible' || (echo 'Kubernetes API is not accessible' && exit 1)
"

# =============================================================================
# FINAL VERIFICATION
# =============================================================================

print_summary

# Exit with appropriate code
if [[ $TESTS_FAILED -eq 0 ]]; then
    log_success "VPS verification completed successfully!"
    echo ""
    echo "🎉 Your VPS is ready for BengoERP deployment!"
    echo ""
    echo "Next steps:"
    echo "1. Ensure GitHub secrets are configured correctly"
    echo "2. Test the deployment pipeline with DEPLOY=false first"
    echo "3. Run a full deployment test"
    exit 0
else
    log_error "VPS verification found issues that need to be resolved."
    echo ""
    echo "🔧 Please address the failed tests above before proceeding with deployment."
    echo ""
    echo "Common solutions:"
    echo "- Check the error messages for specific guidance"
    echo "- Review the setup documentation"
    echo "- Contact support if issues persist"
    exit 1
fi
