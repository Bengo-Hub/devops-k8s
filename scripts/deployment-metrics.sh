#!/bin/bash
set -euo pipefail

# Deployment Metrics Collector
# Collects comprehensive deployment metrics for Prometheus monitoring

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
NAMESPACE=${NAMESPACE:-erp}
METRICS_PORT=${METRICS_PORT:-9091}
METRICS_PATH=${METRICS_PATH:-/metrics}
OUTPUT_DIR=${OUTPUT_DIR:-/tmp/deployment-metrics}

# Pre-flight checks
if ! kubectl version --short >/dev/null 2>&1; then
  log_error "kubectl not configured. Aborting."
  exit 1
fi

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to get deployment metrics
get_deployment_metrics() {
  local app_name=$1
  local namespace=${2:-$NAMESPACE}

  log_step "Collecting metrics for $app_name in namespace $namespace"

  # Get deployment information
  local deployment_info=$(kubectl -n "$namespace" get deployment "$app_name" -o json 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    log_warning "Deployment $app_name not found in namespace $namespace"
    return 1
  fi

  # Extract metrics
  local replicas=$(echo "$deployment_info" | jq -r '.spec.replicas // 0')
  local ready_replicas=$(echo "$deployment_info" | jq -r '.status.readyReplicas // 0')
  local unavailable_replicas=$(echo "$deployment_info" | jq -r '.status.unavailableReplicas // 0')
  local available_replicas=$(echo "$deployment_info" | jq -r '.status.availableReplicas // 0')

  # Get rollout history
  local rollout_history=$(kubectl -n "$namespace" rollout history deployment/"$app_name" -o json 2>/dev/null)
  local latest_revision=$(echo "$rollout_history" | jq -r '.latestRevision // 0')

  # Get pod information
  local pods_info=$(kubectl -n "$namespace" get pods -l app="$app_name" -o json 2>/dev/null)
  local pod_count=$(echo "$pods_info" | jq '.items | length // 0')

  # Calculate health metrics
  local health_ratio=0
  if [[ $replicas -gt 0 ]]; then
    health_ratio=$(echo "scale=2; $ready_replicas / $replicas" | bc 2>/dev/null || echo "0")
  fi

  # Get resource usage (if metrics server is available)
  local cpu_usage="0"
  local memory_usage="0"

  if kubectl top pods -n "$namespace" >/dev/null 2>&1; then
    local top_output=$(kubectl top pods -n "$namespace" -l app="$app_name" --no-headers 2>/dev/null | head -1)
    if [[ -n "$top_output" ]]; then
      cpu_usage=$(echo "$top_output" | awk '{print $2}' | sed 's/m$//')
      memory_usage=$(echo "$top_output" | awk '{print $3}' | sed 's/Mi$//')
    fi
  fi

  # Generate Prometheus format metrics
  cat > "$OUTPUT_DIR/${app_name}_deployment_metrics.prom" << EOF
# HELP deployment_replicas_current Current number of replicas
# TYPE deployment_replicas_current gauge
deployment_replicas_current{app="$app_name",namespace="$namespace"} $replicas

# HELP deployment_replicas_ready Number of ready replicas
# TYPE deployment_replicas_ready gauge
deployment_replicas_ready{app="$app_name",namespace="$namespace"} $ready_replicas

# HELP deployment_replicas_available Number of available replicas
# TYPE deployment_replicas_available gauge
deployment_replicas_available{app="$app_name",namespace="$namespace"} $available_replicas

# HELP deployment_replicas_unavailable Number of unavailable replicas
# TYPE deployment_replicas_unavailable gauge
deployment_replicas_unavailable{app="$app_name",namespace="$namespace"} $unavailable_replicas

# HELP deployment_health_ratio Ratio of ready to total replicas (0-1)
# TYPE deployment_health_ratio gauge
deployment_health_ratio{app="$app_name",namespace="$namespace"} $health_ratio

# HELP deployment_latest_revision Latest deployment revision
# TYPE deployment_latest_revision gauge
deployment_latest_revision{app="$app_name",namespace="$namespace"} $latest_revision

# HELP deployment_pod_count Total number of pods
# TYPE deployment_pod_count gauge
deployment_pod_count{app="$app_name",namespace="$namespace"} $pod_count

# HELP deployment_cpu_usage_millicores CPU usage in millicores
# TYPE deployment_cpu_usage_millicores gauge
deployment_cpu_usage_millicores{app="$app_name",namespace="$namespace"} $cpu_usage

# HELP deployment_memory_usage_mebibytes Memory usage in MiB
# TYPE deployment_memory_usage_mebibytes gauge
deployment_memory_usage_mebibytes{app="$app_name",namespace="$namespace"} $memory_usage
EOF

  log_success "Metrics collected for $app_name"
  return 0
}

# Function to get application health metrics
get_app_health_metrics() {
  local app_name=$1
  local namespace=${2:-$NAMESPACE}

  # This would typically query application health endpoints
  # For now, we'll use Kubernetes readiness probes as a proxy

  local ready_pods=$(kubectl -n "$namespace" get pods -l app="$app_name" -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' | grep -o "True" | wc -l)

  cat >> "$OUTPUT_DIR/${app_name}_deployment_metrics.prom" << EOF

# HELP app_ready_pods Number of pods that are ready
# TYPE app_ready_pods gauge
app_ready_pods{app="$app_name",namespace="$namespace"} $ready_pods
EOF

  log_info "Health metrics collected for $app_name"
}

# Function to start metrics server
start_metrics_server() {
  log_step "Starting deployment metrics server"

  # Create a simple HTTP server to serve metrics
  cd "$OUTPUT_DIR"

  # Create a simple metrics server script
  cat > metrics_server.py << 'EOF'
#!/usr/bin/env python3
import http.server
import socketserver
import os
import glob

PORT = int(os.environ.get('METRICS_PORT', 9091))

class MetricsHandler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/metrics' or self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/plain')
            self.end_headers()

            # Combine all metrics files
            metrics_content = "# Deployment Metrics\n"
            for metrics_file in sorted(glob.glob('*_deployment_metrics.prom')):
                with open(metrics_file, 'r') as f:
                    metrics_content += f.read() + "\n"

            self.wfile.write(metrics_content.encode())
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == "__main__":
    with socketserver.TCPServer(("", PORT), MetricsHandler) as httpd:
        print(f"Serving metrics on port {PORT}")
        httpd.serve_forever()
EOF

  chmod +x metrics_server.py

  # Start metrics server in background
  nohup python3 metrics_server.py > metrics_server.log 2>&1 &
  METRICS_PID=$!

  log_success "Metrics server started with PID $METRICS_PID on port $METRICS_PORT"

  # Wait a moment for server to start
  sleep 2

  # Test the metrics endpoint
  if curl -s "http://localhost:$METRICS_PORT/metrics" >/dev/null; then
    log_success "Metrics server is responding correctly"
  else
    log_warning "Metrics server may not be responding correctly"
  fi

  return $METRICS_PID
}

# Function to collect all deployment metrics
collect_all_metrics() {
  log_step "Collecting metrics for all deployments in namespace $NAMESPACE"

  # Get all deployments in the namespace
  local deployments=$(kubectl -n "$NAMESPACE" get deployments -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

  if [[ -z "$deployments" ]]; then
    log_warning "No deployments found in namespace $NAMESPACE"
    return 1
  fi

  local success_count=0
  local total_count=0

  for deployment in $deployments; do
    total_count=$((total_count + 1))

    if get_deployment_metrics "$deployment" "$NAMESPACE"; then
      success_count=$((success_count + 1))
      get_app_health_metrics "$deployment" "$NAMESPACE"
    fi
  done

  log_success "Collected metrics for $success_count/$total_count deployments"

  # Combine all metrics into a single file
  cat "$OUTPUT_DIR"/*_deployment_metrics.prom > "$OUTPUT_DIR/combined_deployment_metrics.prom" 2>/dev/null || true

  return $((total_count - success_count))
}

# Function to stop metrics server
stop_metrics_server() {
  local pid=${1:-}

  if [[ -n "$pid" && -d /proc/$pid ]]; then
    log_info "Stopping metrics server (PID: $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 2
    kill -9 "$pid" 2>/dev/null || true
    log_success "Metrics server stopped"
  fi
}

# Function to generate deployment metrics dashboard
generate_dashboard_config() {
  local app_name=$1

  cat > "$OUTPUT_DIR/${app_name}_dashboard.json" << EOF
{
  "dashboard": {
    "title": "Deployment Metrics - $app_name",
    "tags": ["deployment", "kubernetes"],
    "panels": [
      {
        "title": "Replica Status",
        "type": "stat",
        "targets": [
          {
            "expr": "deployment_replicas_ready{app=\"$app_name\"}",
            "legendFormat": "Ready"
          },
          {
            "expr": "deployment_replicas_current{app=\"$app_name\"}",
            "legendFormat": "Total"
          }
        ]
      },
      {
        "title": "Health Ratio",
        "type": "gauge",
        "targets": [
          {
            "expr": "deployment_health_ratio{app=\"$app_name\"} * 100",
            "legendFormat": "Health %"
          }
        ],
        "fieldConfig": {
          "defaults": {
            "max": 100,
            "min": 0,
            "thresholds": {
              "steps": [
                {"color": "red", "value": 0},
                {"color": "yellow", "value": 50},
                {"color": "green", "value": 90}
              ]
            }
          }
        }
      },
      {
        "title": "Resource Usage",
        "type": "timeseries",
        "targets": [
          {
            "expr": "deployment_cpu_usage_millicores{app=\"$app_name\"}",
            "legendFormat": "CPU (mcores)"
          },
          {
            "expr": "deployment_memory_usage_mebibytes{app=\"$app_name\"}",
            "legendFormat": "Memory (MiB)"
          }
        ]
      }
    ]
  }
}
EOF

  log_info "Generated dashboard configuration for $app_name"
}

# Main execution
main() {
  case "${1:-collect}" in
    "collect")
      collect_all_metrics
      ;;

    "serve")
      start_metrics_server
      ;;

    "dashboard")
      if [[ -z "${2:-}" ]]; then
        log_error "App name required for dashboard generation"
        echo "Usage: $0 dashboard <app_name>"
        exit 1
      fi
      generate_dashboard_config "$2"
      ;;

    "all")
      log_step "Running complete metrics collection pipeline"

      collect_all_metrics
      start_metrics_server

      # Generate dashboards for all deployments
      for metrics_file in "$OUTPUT_DIR"/*_deployment_metrics.prom; do
        if [[ -f "$metrics_file" ]]; then
          app_name=$(basename "$metrics_file" _deployment_metrics.prom)
          generate_dashboard_config "$app_name"
        fi
      done

      log_success "Complete metrics pipeline executed"
      ;;

    "stop")
      # This would be called with the PID from the serve command
      stop_metrics_server "${2:-}"
      ;;

    *)
      echo "Usage: $0 {collect|serve|dashboard|all|stop}"
      echo ""
      echo "Commands:"
      echo "  collect    - Collect metrics for all deployments"
      echo "  serve      - Start metrics server"
      echo "  dashboard  - Generate Grafana dashboard config"
      echo "  all        - Run complete pipeline"
      echo "  stop       - Stop metrics server (requires PID)"
      echo ""
      echo "Environment Variables:"
      echo "  NAMESPACE         - Kubernetes namespace (default: erp)"
      echo "  METRICS_PORT      - Metrics server port (default: 9091)"
      echo "  METRICS_PATH      - Metrics endpoint path (default: /metrics)"
      echo "  OUTPUT_DIR        - Output directory (default: /tmp/deployment-metrics)"
      echo ""
      echo "Examples:"
      echo "  $0 collect"
      echo "  $0 serve"
      echo "  $0 dashboard erp-api"
      echo "  $0 all"
      exit 1
      ;;
  esac
}

# Run main function with all arguments
main "$@"
