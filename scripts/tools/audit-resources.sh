#!/usr/bin/env bash
# Resource audit script for Kubernetes cluster
# Helps prevent pod limit exhaustion and resource overcommit

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[✓]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[⚠]${NC} $1"; }
log_error() { echo -e "${RED}[✗]${NC} $1"; }
log_section() { echo -e "${CYAN}━━━ $1 ━━━${NC}"; }

# =============================================================================
# Pod Count Analysis
# =============================================================================
log_section "Pod Count Analysis"

TOTAL_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
ACTIVE_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -cv "Terminating\|Completed" || echo "0")
TERMINATING_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "Terminating" || echo "0")
FAILED_PODS=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep -c "Error\|Failed\|CrashLoopBackOff" || echo "0")

POD_LIMIT=150
POD_USAGE_PCT=$((ACTIVE_PODS * 100 / POD_LIMIT))

echo "Total Pods:       $TOTAL_PODS"
echo "Active Pods:      $ACTIVE_PODS / $POD_LIMIT ($POD_USAGE_PCT%)"
echo "Terminating Pods: $TERMINATING_PODS"
echo "Failed Pods:      $FAILED_PODS"
echo ""

if [[ $ACTIVE_PODS -ge 143 ]]; then
    log_error "Pod count dangerously high! (>95% of limit)"
    log_error "Action required: Scale down non-critical services"
elif [[ $ACTIVE_PODS -ge 128 ]]; then
    log_warning "Pod count approaching limit (>85%)"
    log_warning "Consider reducing replica counts"
elif [[ $ACTIVE_PODS -ge 113 ]]; then
    log_warning "Pod count elevated (>75%)"
else
    log_success "Pod count healthy (<75% of limit)"
fi

if [[ $TERMINATING_PODS -gt 10 ]]; then
    log_warning "$TERMINATING_PODS pods stuck terminating - may need force deletion"
fi

if [[ $FAILED_PODS -gt 5 ]]; then
    log_warning "$FAILED_PODS pods in failed state - investigate and cleanup"
fi

# =============================================================================
# Pods by Namespace
# =============================================================================
log_section "Pods by Namespace (Top 10)"

kubectl get pods --all-namespaces --no-headers 2>/dev/null | \
    awk '{print $1}' | sort | uniq -c | sort -rn | head -10 | \
    while read count ns; do
        if [[ $count -gt 15 ]]; then
            log_warning "$ns: $count pods (consider reducing replicas)"
        else
            echo "$ns: $count pods"
        fi
    done
echo ""

# =============================================================================
# Resource Requests Analysis
# =============================================================================
log_section "Resource Requests Summary"

# Get node capacity
NODE_CPU=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[0].status.allocatable.cpu' || echo "0")
NODE_MEM_KB=$(kubectl get nodes -o json 2>/dev/null | jq -r '.items[0].status.allocatable.memory' | sed 's/Ki//' || echo "0")
NODE_MEM_GB=$((NODE_MEM_KB / 1024 / 1024))

echo "Node Capacity: ${NODE_CPU} CPU cores, ${NODE_MEM_GB}GB memory"
echo ""

# Show current resource usage from node
if kubectl get --raw "/apis/metrics.k8s.io/v1beta1/nodes" >/dev/null 2>&1; then
    log_success "Metrics available from metrics-server"
    kubectl top nodes 2>/dev/null || log_warning "Failed to get node metrics"
else
    log_warning "Metrics-server not available - cannot show actual usage"
    log_warning "Run: kubectl rollout restart deployment metrics-server -n kube-system"
fi
echo ""

# Show resource requests by namespace
log_section "Top Resource Consuming Namespaces"
echo ""

kubectl get pods --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | 
        select(.metadata.namespace != null) |
        {
            ns: .metadata.namespace,
            cpu: (.spec.containers[].resources.requests.cpu // "0"),
            mem: (.spec.containers[].resources.requests.memory // "0")
        } | 
        "\(.ns) \(.cpu) \(.mem)"' | \
    awk '{
        ns=$1
        cpu=$2
        mem=$3
        
        # Convert CPU to millicores
        cpu_m=0
        if (cpu ~ /m$/) { cpu_m=int(cpu) }
        else if (cpu != "0") { cpu_m=int(cpu*1000) }
        
        # Convert memory to MB
        mem_mb=0
        if (mem ~ /Mi$/) { mem_mb=int(mem) }
        else if (mem ~ /Gi$/) { mem_mb=int(mem*1024) }
        else if (mem ~ /Ki$/) { mem_mb=int(mem/1024) }
        
        ns_cpu[ns] += cpu_m
        ns_mem[ns] += mem_mb
    }
    END {
        for (ns in ns_cpu) {
            printf "%s %.2f %d\n", ns, ns_cpu[ns]/1000, ns_mem[ns]
        }
    }' | sort -k2 -rn | head -10 | \
    while read ns cpu mem; do
        echo "$ns: ${cpu} CPU cores, ${mem}MB memory requested"
    done
echo ""

# =============================================================================
# VPA Status Check
# =============================================================================
log_section "Vertical Pod Autoscaler Status"

VPA_COUNT=$(kubectl get vpa --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")

if [[ $VPA_COUNT -eq 0 ]]; then
    log_info "No VPA resources found"
else
    echo "Found $VPA_COUNT VPA resources:"
    kubectl get vpa --all-namespaces 2>/dev/null | tail -n +2 | while read ns name target mode rest; do
        if [[ "$mode" != "Off" ]]; then
            log_warning "$ns/$name: updateMode=$mode (requires metrics-server)"
        else
            echo "$ns/$name: updateMode=Off"
        fi
    done
fi
echo ""

# =============================================================================
# HPA Status Check
# =============================================================================
log_section "Horizontal Pod Autoscaler Status"

HPA_COUNT=$(kubectl get hpa --all-namespaces --no-headers 2>/dev/null | wc -l || echo "0")
HPA_UNKNOWN=$(kubectl get hpa --all-namespaces 2>/dev/null | grep -c "<unknown>" || echo "0")

echo "Total HPAs: $HPA_COUNT"
echo "HPAs with unknown metrics: $HPA_UNKNOWN"

if [[ $HPA_UNKNOWN -gt 0 ]]; then
    log_error "$HPA_UNKNOWN HPAs cannot get metrics"
    log_error "Metrics-server may be down or unstable"
    log_error "Run: kubectl get pods -n kube-system -l k8s-app=metrics-server"
fi
echo ""

# =============================================================================
# Duplicate Resource Detection
# =============================================================================
log_section "Duplicate Resource Detection"

# Check for duplicate Prometheus operators
PROM_OPS=$(kubectl get deployment --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.name | contains("prometheus-operator")) | "\(.metadata.namespace)/\(.metadata.name)"' | \
    wc -l || echo "0")

if [[ $PROM_OPS -gt 1 ]]; then
    log_error "Found $PROM_OPS Prometheus operators (expected 1)"
    kubectl get deployment --all-namespaces 2>/dev/null | grep prometheus-operator
else
    log_success "Single Prometheus operator instance"
fi

# Check for duplicate Grafana
GRAFANA=$(kubectl get deployment --all-namespaces -o json 2>/dev/null | \
    jq -r '.items[] | select(.metadata.name | contains("grafana")) | "\(.metadata.namespace)/\(.metadata.name)"' | \
    wc -l || echo "0")

if [[ $GRAFANA -gt 1 ]]; then
    log_warning "Found $GRAFANA Grafana deployments (expected 1)"
    kubectl get deployment --all-namespaces 2>/dev/null | grep grafana
else
    log_success "Single Grafana instance"
fi
echo ""

# =============================================================================
# Recommendations
# =============================================================================
log_section "Recommendations"

if [[ $ACTIVE_PODS -ge 95 ]]; then
    echo "🔴 CRITICAL: Reduce pod count immediately"
    echo "   1. Scale down low-priority services:"
    echo "      kubectl scale deployment --replicas=1 -n <namespace> <deployment>"
    echo "   2. Disable autoscaling for non-critical apps"
    echo "   3. Check for stuck terminating pods"
    echo ""
fi

if [[ $HPA_UNKNOWN -gt 5 ]]; then
    echo "🟡 WARNING: Metrics-server issues detected"
    echo "   1. Restart metrics-server:"
    echo "      kubectl rollout restart deployment metrics-server -n kube-system"
    echo "   2. Disable VPA on affected services"
    echo "   3. Monitor HPA status after restart"
    echo ""
fi

if [[ $TERMINATING_PODS -gt 5 ]]; then
    echo "🟡 WARNING: Many pods stuck terminating"
    echo "   kubectl delete pod <pod-name> -n <namespace> --force --grace-period=0"
    echo ""
fi

if [[ $PROM_OPS -gt 1 ]] || [[ $GRAFANA -gt 1 ]]; then
    echo "🟡 WARNING: Duplicate monitoring resources"
    echo "   Review and remove duplicate Prometheus/Grafana deployments"
    echo ""
fi

# =============================================================================
# Summary
# =============================================================================
log_section "Summary"

if [[ $ACTIVE_PODS -lt 85 ]] && [[ $HPA_UNKNOWN -eq 0 ]] && [[ $PROM_OPS -le 1 ]]; then
    log_success "Cluster resources healthy ✓"
elif [[ $ACTIVE_PODS -lt 95 ]]; then
    log_warning "Cluster resources OK with warnings"
else
    log_error "Cluster resources critical - action required!"
fi
