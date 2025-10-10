Monitoring and Alerts
---------------------

This guide covers setting up a complete monitoring stack with Prometheus, Grafana, and alerting for your Kubernetes cluster.

Stack Components
----------------
- **Prometheus**: Metrics collection and storage
- **Grafana**: Visualization and dashboards
- **Alertmanager**: Alert routing and notifications
- **kube-state-metrics**: Kubernetes object metrics
- **node-exporter**: Node-level metrics
- **Loki** (optional): Log aggregation

Prerequisites
-------------
- Kubernetes cluster with kubectl access
- Helm 3 installed
- cert-manager for TLS (optional)

Installation
------------

### Quick Install (Automated)

From the devops-k8s repository root:

```bash
# Run the automated installation script
./scripts/install-monitoring.sh

# With custom Grafana domain (optional)
GRAFANA_DOMAIN=grafana.yourdomain.com ./scripts/install-monitoring.sh
```

The script will:
- Check for cert-manager (install if missing)
- Install Prometheus + Grafana with production settings
- Apply ERP-specific alerts
- Configure TLS ingress for Grafana
- Display credentials and access information

**Default Grafana Domain:** `grafana.masterspace.co.ke`

---

### Manual Installation (Alternative)

### 1. Add Helm Repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### 2. Create Monitoring Namespace

```bash
kubectl create namespace monitoring
```

### 3. Install kube-prometheus-stack

Using the provided values file from this repo:
```yaml
prometheus:
  prometheusSpec:
    retention: 30d
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 50Gi
    resources:
      requests:
        cpu: 500m
        memory: 2Gi
      limits:
        cpu: 2000m
        memory: 4Gi

grafana:
  adminPassword: "changeme"
  persistence:
    enabled: true
    size: 10Gi
  ingress:
    enabled: true
    ingressClassName: nginx
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - grafana.masterspace.co.ke
    tls:
      - secretName: grafana-tls
        hosts:
          - grafana.masterspace.co.ke

alertmanager:
  alertmanagerSpec:
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
```

Install the stack:
```bash
helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f manifests/monitoring/prometheus-values.yaml \
  --timeout=15m \
  --wait
```

**Note:** Installation may take 10-15 minutes on first run due to image pulls.

### 4. Apply ERP Alerts

```bash
kubectl apply -f manifests/monitoring/erp-alerts.yaml
```

### 5. Verify Installation

```bash
# Check pods
kubectl get pods -n monitoring

# Check services
kubectl get svc -n monitoring

# Check ingress
kubectl get ingress -n monitoring

# Get Grafana admin password
kubectl get secret -n monitoring prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d && echo
```

Accessing Dashboards
-------------------

### Grafana UI

#### Option A: Port Forward (Development)
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Access at http://localhost:3000
# Username: admin
# Password: (from secret above)
```

#### Option B: Ingress (Production) - Recommended

Access at: **https://grafana.masterspace.co.ke**

The installation script automatically configures:
- TLS certificate via cert-manager
- NGINX ingress with proper annotations
- Domain as specified (default: grafana.masterspace.co.ke)

**Ensure DNS:** Point `grafana.masterspace.co.ke` to your VPS IP: **77.237.232.66**

### Prometheus UI

```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090
# Access at http://localhost:9090
```

### Alertmanager UI

```bash
kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-alertmanager 9093:9093
# Access at http://localhost:9093
```

Configuring Alerts
------------------

### 1. Create PrometheusRule for ERP Applications

Create `erp-alerts.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: erp-alerts
  namespace: monitoring
  labels:
    prometheus: kube-prometheus
spec:
  groups:
  - name: erp.rules
    interval: 30s
    rules:
    # API Health
    - alert: ERPAPIDown
      expr: up{job="erp-api"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "ERP API is down"
        description: "ERP API has been down for more than 2 minutes"

    # UI Health
    - alert: ERPUIDown
      expr: up{job="erp-ui"} == 0
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "ERP UI is down"
        description: "ERP UI has been down for more than 2 minutes"

    # High CPU
    - alert: HighCPUUsage
      expr: rate(container_cpu_usage_seconds_total{namespace="erp"}[5m]) > 0.8
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High CPU usage in ERP namespace"
        description: "CPU usage is above 80% for 5 minutes"

    # High Memory
    - alert: HighMemoryUsage
      expr: container_memory_usage_bytes{namespace="erp"} / container_spec_memory_limit_bytes{namespace="erp"} > 0.9
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "High memory usage in ERP namespace"
        description: "Memory usage is above 90% for 5 minutes"

    # Pod Restarts
    - alert: PodRestartingTooOften
      expr: rate(kube_pod_container_status_restarts_total{namespace="erp"}[15m]) > 0.1
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "Pod restarting too often"
        description: "Pod {{ $labels.pod }} is restarting frequently"

    # HPA at Max
    - alert: HPAMaxedOut
      expr: kube_horizontalpodautoscaler_status_current_replicas{namespace="erp"} == kube_horizontalpodautoscaler_spec_max_replicas{namespace="erp"}
      for: 10m
      labels:
        severity: warning
      annotations:
        summary: "HPA has reached maximum replicas"
        description: "HPA {{ $labels.horizontalpodautoscaler }} is at max capacity"
```

Apply:
```bash
kubectl apply -f manifests/monitoring/erp-alerts.yaml
```

**Note:** If you used the `install-monitoring.sh` script, alerts are already applied.

### 2. Configure Alertmanager Notifications

Create `alertmanager-config.yaml`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-prometheus-kube-prometheus-alertmanager
  namespace: monitoring
type: Opaque
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'cluster', 'service']
      group_wait: 10s
      group_interval: 10s
      repeat_interval: 12h
      receiver: 'email'
      routes:
      - match:
          severity: critical
        receiver: email
        continue: true
    receivers:
    - name: 'email'
      email_configs:
      - to: 'codevertexitsolutions@gmail.com'
        from: 'alerts@codevertexitsolutions.com'
        smarthost: smtp.gmail.com:587
        auth_username: 'codevertexitsolutions@gmail.com'
        auth_password: '<APP_PASSWORD>'
        headers:
          Subject: '{{ template "email.default.subject" . }}'
```

Apply:
```bash
# Update the password first in manifests/monitoring/alertmanager-config.yaml
# Replace <APP_PASSWORD> with your Gmail app password
kubectl apply -f manifests/monitoring/alertmanager-config.yaml
kubectl rollout restart statefulset -n monitoring alertmanager-prometheus-kube-prometheus-alertmanager
```

**Email Configuration:**
- Alerts sent to: `codevertexitsolutions@gmail.com`
- From: `alerts@codevertexitsolutions.com`
- SMTP: Gmail (smtp.gmail.com:587)
- Auth: Requires Gmail App Password (not regular password)

Application Metrics
-------------------

### Expose Metrics from Applications

#### Django API (Prometheus Client)
Install `django-prometheus`:
```bash
pip install django-prometheus
```

Add to `settings.py`:
```python
INSTALLED_APPS = [
    'django_prometheus',
    # ... other apps
]

MIDDLEWARE = [
    'django_prometheus.middleware.PrometheusBeforeMiddleware',
    # ... other middleware
    'django_prometheus.middleware.PrometheusAfterMiddleware',
]
```

Add to `urls.py`:
```python
urlpatterns = [
    path('metrics/', include('django_prometheus.urls')),
    # ... other urls
]
```

#### ServiceMonitor for ERP API
Create `erp-api-servicemonitor.yaml`:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: erp-api
  namespace: monitoring
  labels:
    app: erp-api
spec:
  selector:
    matchLabels:
      app: erp-api
  endpoints:
  - port: http
    path: /api/v1/metrics
    interval: 30s
```

Apply: `kubectl apply -f manifests/monitoring/erp-api-servicemonitor.yaml`

Deployment Metrics
------------------

### Automated Deployment Metrics Collection

The system includes automated deployment metrics collection for comprehensive monitoring of deployment health and performance.

#### Deployment Metrics Script

Use the deployment metrics collector script:

```bash
# Collect metrics for all deployments
./scripts/deployment-metrics.sh collect

# Start metrics server
./scripts/deployment-metrics.sh serve

# Generate Grafana dashboard config
./scripts/deployment-metrics.sh dashboard erp-api

# Run complete pipeline
./scripts/deployment-metrics.sh all
```

#### Metrics Collected

- **Replica Status**: Current, ready, available, and unavailable replicas
- **Health Ratio**: Ratio of ready to total replicas (0-1)
- **Deployment Revision**: Latest deployment revision number
- **Pod Count**: Total number of pods for the deployment
- **Resource Usage**: CPU and memory usage (if metrics server available)
- **Rollout History**: Deployment revision history

#### Prometheus Metrics Format

```prometheus
# Deployment replica metrics
deployment_replicas_current{app="erp-api",namespace="erp"} 3
deployment_replicas_ready{app="erp-api",namespace="erp"} 3
deployment_health_ratio{app="erp-api",namespace="erp"} 1.0

# Resource usage metrics
deployment_cpu_usage_millicores{app="erp-api",namespace="erp"} 150
deployment_memory_usage_mebibytes{app="erp-api",namespace="erp"} 256
```

#### Grafana Dashboard Integration

Deployment metrics are automatically integrated into Grafana:

1. **Deployment Health Panel**: Shows replica status and health ratio
2. **Resource Usage Panel**: Displays CPU and memory consumption
3. **Rollout History**: Tracks deployment revisions over time
4. **Alert Integration**: HPA and deployment failure alerts

#### Automated Metrics Collection

The deployment metrics collector can be deployed as a Kubernetes resource:

```bash
kubectl apply -f manifests/monitoring/deployment-metrics.yaml
```

This creates:
- **ServiceMonitor**: For Prometheus to scrape metrics
- **Service**: Exposes metrics endpoint
- **Deployment**: Runs metrics collection and server

Grafana Dashboards
------------------

### Import Pre-built Dashboards

1. Login to Grafana
2. Go to Dashboards > Import
3. Import these dashboard IDs:
   - **315**: Kubernetes cluster monitoring
   - **6417**: Kubernetes cluster overview
   - **7249**: Kubernetes pod metrics
   - **1860**: Node Exporter Full
   - **3119**: Kubernetes Deployment Metrics (for deployment-specific monitoring)

### Custom ERP Dashboard

Create custom dashboard for ERP metrics:
- API request rate and latency
- Database connection pool
- Active users
- Error rates
- Resource usage per service
- Deployment health and rollout status

### Deployment Metrics Dashboard

A specialized dashboard for deployment monitoring includes:
- **Replica Status**: Visual indicator of deployment health
- **Scaling Events**: HPA scaling decisions and timing
- **Resource Optimization**: VPA recommendations and adjustments
- **Rollback History**: Track deployment rollbacks and reasons
- **Performance Trends**: CPU/memory usage patterns over time

Deployment Rollbacks
--------------------

### Automated Rollback Capabilities

The system includes automated rollback capabilities for failed deployments with comprehensive monitoring and alerting.

#### Rollback Script

Use the deployment rollback script for managing deployment rollbacks:

```bash
# Check deployment status and history
./scripts/deployment-rollback.sh status

# View deployment history
./scripts/deployment-rollback.sh history

# Rollback to specific version
./scripts/deployment-rollback.sh rollback

# Enable auto-rollback on failure
./scripts/deployment-rollback.sh auto-rollback
```

#### Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `APP_NAME` | Application name | Required |
| `NAMESPACE` | Kubernetes namespace | `erp` |
| `ROLLBACK_VERSION` | Version to rollback to | Required for rollback |
| `AUTO_ROLLBACK` | Enable automatic rollback | `false` |
| `HEALTH_CHECK_URL` | Health check endpoint | Optional |

#### Manual Rollback

```bash
# Check current deployment status
kubectl -n erp rollout history deployment erp-api

# Rollback to previous version
kubectl -n erp rollout undo deployment erp-api --to-revision=2

# Monitor rollback status
kubectl -n erp rollout status deployment erp-api
```

#### Automated Rollback

Enable automatic rollback for production deployments:

```bash
APP_NAME=erp-api AUTO_ROLLBACK=true \
  HEALTH_CHECK_URL=https://erpapi.masterspace.co.ke/api/v1/core/health/ \
  ./scripts/deployment-rollback.sh auto-rollback
```

#### Rollback Monitoring

The system monitors for:
- **Deployment failures**: Automatic detection of failed rollouts
- **Health check failures**: Application-level health verification
- **Resource issues**: CPU/memory constraints during deployment
- **Pod restart spikes**: Indication of application instability

#### Alert Integration

Rollback events are integrated with the alerting system:

- **Critical**: Deployment failure with auto-rollback
- **Warning**: Manual rollback initiated
- **Info**: Successful rollback completion

Log Aggregation (Optional)
--------------------------

### Install Loki Stack

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm install loki grafana/loki-stack \
  -n monitoring \
  --set grafana.enabled=false \
  --set prometheus.enabled=false \
  --set promtail.enabled=true
```

Configure Grafana to use Loki as data source for log queries.

Maintenance
-----------

### Backup Grafana Dashboards
```bash
# Export all dashboards
kubectl exec -n monitoring deployment/prometheus-grafana -- grafana-cli admin export-all > dashboards-backup.json
```

### Cleanup Old Metrics
Prometheus retention is configured in values.yaml (default: 30d).

### Scale Prometheus for Large Deployments
```bash
# Edit values and upgrade
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f monitoring-values.yaml
```

Troubleshooting
---------------

### Prometheus Not Scraping Targets
```bash
# Check ServiceMonitor
kubectl get servicemonitor -n monitoring

# Check Prometheus targets
# Port forward and visit http://localhost:9090/targets
```

### High Resource Usage
- Reduce retention period
- Decrease scrape interval
- Add node affinity to spread pods

### Missing Metrics
- Verify ServiceMonitor labels match Prometheus selector
- Check application exposes /metrics endpoint
- Review Prometheus logs for scrape errors


