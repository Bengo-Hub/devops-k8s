#!/bin/bash

# =============================================================================
# BengoERP Monitoring Setup Script
# =============================================================================
# This script sets up comprehensive monitoring for BengoERP deployments:
# - Prometheus metrics collection
# - Grafana dashboards
# - Alerting rules
# - Log aggregation
# - Distributed tracing
# =============================================================================

set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-erp}"
MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-infra}"
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-latest}"
GRAFANA_VERSION="${GRAFANA_VERSION:-latest}"
LOKI_VERSION="${LOKI_VERSION:-latest}"
TEMPO_VERSION="${TEMPO_VERSION:-latest}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    for cmd in kubectl helm curl; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "$cmd is required but not installed"
            exit 1
        fi
    done

    log_success "All prerequisites are available"
}

# Install Prometheus Operator
install_prometheus() {
    log_info "Installing Prometheus Operator..."

    # Add Prometheus community Helm repo
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
    helm repo update

    # Create monitoring namespace if it doesn't exist
    kubectl create namespace "$MONITORING_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

    # Install kube-prometheus-stack
    helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
        --namespace "$MONITORING_NAMESPACE" \
        --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
        --set grafana.adminPassword="admin" \
        --set grafana.persistence.enabled=true \
        --set grafana.persistence.size="10Gi" \
        --wait

    log_success "Prometheus Operator installed successfully"
}

# Configure Grafana dashboards
setup_grafana_dashboards() {
    log_info "Setting up Grafana dashboards..."

    # Wait for Grafana to be ready
    kubectl wait --for=condition=available --timeout=300s deployment/prometheus-grafana -n "$MONITORING_NAMESPACE"

    # Get Grafana admin password
    GRAFANA_PASSWORD=$(kubectl get secret prometheus-grafana -n "$MONITORING_NAMESPACE" -o jsonpath="{.data.admin-password}" | base64 -d)

    # Create BengoERP dashboard configuration
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: bengoerp-grafana-dashboards
  namespace: $MONITORING_NAMESPACE
data:
  bengoerp-overview.json: |
    {
      "dashboard": {
        "title": "BengoERP Overview",
        "tags": ["bengoerp", "overview"],
        "timezone": "browser",
        "panels": [
          {
            "title": "API Request Rate",
            "type": "graph",
            "targets": [
              {
                "expr": "rate(bengoerp_api_requests_total[5m])",
                "legendFormat": "{{ method }} {{ endpoint }}"
              }
            ]
          },
          {
            "title": "API Response Time",
            "type": "graph",
            "targets": [
              {
                "expr": "histogram_quantile(0.95, rate(bengoerp_api_request_duration_seconds_bucket[5m]))",
                "legendFormat": "{{ method }} {{ endpoint }}"
              }
            ]
          },
          {
            "title": "Active Users",
            "type": "stat",
            "targets": [
              {
                "expr": "bengoerp_api_active_users"
              }
            ]
          },
          {
            "title": "Database Query Performance",
            "type": "graph",
            "targets": [
              {
                "expr": "histogram_quantile(0.95, rate(bengoerp_api_db_query_duration_seconds_bucket[5m]))",
                "legendFormat": "{{ query_type }}"
              }
            ]
          }
        ]
      }
    }
EOF

    log_success "Grafana dashboards configured"
}

# Setup alerting rules
setup_alerts() {
    log_info "Setting up alerting rules..."

    cat <<EOF | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: bengoerp-alerts
  namespace: $MONITORING_NAMESPACE
spec:
  groups:
  - name: bengoerp
    rules:
    - alert: BengoERPApiHighErrorRate
      expr: rate(bengoerp_api_requests_total{status_code=~"5.."}[5m]) / rate(bengoerp_api_requests_total[5m]) > 0.05
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "High API error rate detected"
        description: "API error rate is {{ $value }}% which is above threshold of 5%"

    - alert: BengoERPApiHighResponseTime
      expr: histogram_quantile(0.95, rate(bengoerp_api_request_duration_seconds_bucket[5m])) > 2
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High API response time detected"
        description: "95th percentile response time is {{ $value }}s which is above threshold of 2s"

    - alert: BengoERPDBSlowQueries
      expr: histogram_quantile(0.95, rate(bengoerp_api_db_query_duration_seconds_bucket[5m])) > 1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Slow database queries detected"
        description: "95th percentile query time is {{ $value }}s which is above threshold of 1s"

    - alert: BengoERPLowActiveUsers
      expr: bengoerp_api_active_users < 10
      for: 10m
      labels:
        severity: info
      annotations:
        summary: "Low user activity detected"
        description: "Active users count is {{ $value }} which is below threshold of 10"
EOF

    log_success "Alerting rules configured"
}

# Setup log aggregation with Loki
setup_logging() {
    log_info "Setting up log aggregation..."

    # Install Loki stack
    helm upgrade --install loki grafana/loki-stack \
        --namespace "$MONITORING_NAMESPACE" \
        --set loki.persistence.enabled=true \
        --set loki.persistence.size="20Gi" \
        --wait

    # Configure log shipping for BengoERP pods
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: bengoerp-logging-config
  namespace: $NAMESPACE
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
      grpc_listen_port: 0
    positions:
      filename: /tmp/positions.yaml
    clients:
      - url: http://loki-loki-distributed-gateway.$MONITORING_NAMESPACE.svc.cluster.local/loki/api/v1/push
    scrape_configs:
      - job_name: bengoerp-api
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names: [$NAMESPACE]
        pipeline_stages:
          - json:
              expressions:
                level: level
                message: message
          - labels:
              level:
              app: bengoerp-api
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
EOF

    log_success "Log aggregation configured"
}

# Setup distributed tracing with Tempo
setup_tracing() {
    log_info "Setting up distributed tracing..."

    # Install Tempo
    helm upgrade --install tempo grafana/tempo \
        --namespace "$MONITORING_NAMESPACE" \
        --set tempo.persistence.enabled=true \
        --set tempo.persistence.size="10Gi" \
        --wait

    log_success "Distributed tracing configured"
}

# Main installation function
main() {
    log_info "Starting BengoERP monitoring setup..."

    check_prerequisites
    install_prometheus
    setup_grafana_dashboards
    setup_alerts
    setup_logging
    setup_tracing

    log_success "BengoERP monitoring setup completed successfully!"

    # Print access information
    echo ""
    log_info "Access Information:"
    echo "  Grafana: http://prometheus-grafana.$MONITORING_NAMESPACE"
    echo "  Prometheus: http://prometheus-prometheus.$MONITORING_NAMESPACE"
    echo "  AlertManager: http://prometheus-alertmanager.$MONITORING_NAMESPACE"
    echo ""
    log_info "Default Grafana credentials: admin / admin"
}

# Run main function
main "$@"
