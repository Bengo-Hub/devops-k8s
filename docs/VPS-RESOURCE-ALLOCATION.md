# VPS Resource Allocation - Optimized for 12-Core Server

> **⚠️ CRITICAL:** Maximum 110 pods per node. Monitor pod count to prevent scheduling failures.  
> **Last Updated:** December 10, 2025 - Post-optimization audit

## Server Specifications (Actual)
- **CPU:** 12 cores (AMD EPYC)
- **RAM:** 47GB total (~48GB allocatable)
- **Disk:** 242GB (158GB free)
- **Pod Limit:** 150 pods/node (hard limit)
- **Current Usage:** 95% CPU requested, 60% memory requested
- **Current Pods:** ~99 active (90% of limit)

## Optimization Strategy

### Priority Tier System

#### Tier 1: Critical Storage & Core Services (High Resources)
**Target:** 40% of CPU, 60% of RAM

| Service | CPU Request | Memory Request | Max Replicas | Rationale |
|---------|-------------|----------------|--------------|-----------|
| **PostgreSQL** | 500m | 2Gi | 1 (StatefulSet) | Database - needs RAM for caching |
| **Redis** | 200m | 1Gi | 1 (StatefulSet) | Cache - memory-intensive |
| **erp-api** | 300m | 1Gi | 6 | Main application service |
| **Celery Worker** | 200m | 768Mi | 2 | Background job processing |
| **auth-service** | 150m | 256Mi | 4 | Critical authentication |

#### Tier 2: Active Services (Medium Resources)
**Target:** 30% of CPU, 25% of RAM

| Service | CPU Request | Memory Request | Max Replicas |
|---------|-------------|----------------|--------------|
| **cafe-backend** | 200m | 512Mi | 4 |
| **notifications-app** | 150m | 512Mi | 4 |
| **treasury-app** | 150m | 512Mi | 4 |
| **cafe-frontend** | 100m | 256Mi | 4 |
| **erp-ui** | 100m | 256Mi | 4 |

#### Tier 3: Standby Services (Minimal Resources)
**Target:** 10% of CPU, 10% of RAM

| Service | CPU Request | Memory Request | Max Replicas | Note |
|---------|-------------|----------------|--------------|------|
| **pos-service** | 50m | 128Mi | 2 | Not actively used |
| **inventory-service** | 50m | 128Mi | 2 | Not actively used |
| **logistics-service** | 50m | 128Mi | 2 | Not actively used |
| **truload-backend** | 30m | 96Mi | 1-2 | Not actively used, VPA disabled |
| **truload-frontend** | 30m | 96Mi | 1-2 | Not actively used, VPA disabled |

**⚠️ TruLoad VPA Disabled:** VPA caused pod eviction loops when metrics-server unavailable. Keep disabled until metrics-server is stable.

## Auto-Scaling Configuration

### All Services
- **Min Replicas:** 1 (cost-efficient)
- **Max Replicas:** 2-6 (based on tier)
- **CPU Threshold:** 70% (balanced)
- **Memory Threshold:** 75% (balanced)
- **Scale-up:** Fast (30s delay)
- **Scale-down:** Slow (5min stabilization)

## Resource Recommendations for Storage Services

### PostgreSQL Enhancement
```yaml
resources:
  requests:
    cpu: 500m      # Increased from 250m
    memory: 2Gi    # Increased from 512Mi
  limits:
    cpu: 2000m     # Can burst to 2 cores
    memory: 8Gi    # Can use up to 8GB for caching
```

### Redis Enhancement
```yaml
resources:
  requests:
    cpu: 200m      # Stable baseline
    memory: 1Gi    # Increased for better caching
  limits:
    cpu: 1000m     # Can burst
    memory: 4Gi    # Sufficient for cache operations
```

## Total Resource Allocation

### CPU Distribution (12 cores available)
- Storage Services: ~1.0 core (8%)
- Tier 1 Apps: ~4.0 cores (33%)
- Tier 2 Apps: ~3.5 cores (29%)
- Tier 3 Apps: ~1.0 core (8%)
- Infrastructure: ~1.5 cores (13%)
- **Reserve:** ~1.0 core (8%) for bursting

**Total Baseline:** ~11 cores (92%)

### Memory Distribution (47GB available)
- Storage Services: ~3GB (6%)
- Tier 1 Apps: ~8GB (17%)
- Tier 2 Apps: ~6GB (13%)
- Tier 3 Apps: ~2GB (4%)
- Infrastructure: ~8GB (17%)
- **Reserve:** ~20GB (43%) for bursting & system

**Total Baseline:** ~27GB (57%)

---

## 🚨 Critical Limits & Monitoring

### Pod Count Management
**Hard Limit:** 110 pods per node (kubelet default)

**Current Distribution (Dec 10, 2025):**
```
infra:          ~18 pods (after cleanup from 25)
erp:            ~11 pods
kube-system:    ~11 pods
truload:        ~3 pods (reduced from 9)
Other services: ~56 pods
```

**Pod Count Thresholds:**
- ✅ **<85 pods (75%):** Healthy
- ⚠️ **85-95 pods (75-85%):** Monitor closely
- 🚨 **95-105 pods (85-95%):** Scale down non-critical
- 🔴 **>105 pods (>95%):** Critical - immediate action required

**Monitoring Commands:**
```bash
# Check current pod count
kubectl get pods --all-namespaces --no-headers | wc -l

# Run resource audit
./scripts/audit-resources.sh
```

### VPA Safety Guidelines

**When to Disable VPA:**
- ❌ metrics-server unavailable
- ❌ Low-priority services
- ❌ When pod count >95

**Current Status:**
- TruLoad services: VPA **DISABLED** (metrics-server issues)

---

## 📊 Resource Optimization History

### December 10, 2025 - Major Optimization
**Issues:** Pod overflow (114/110), VPA loops, duplicate monitoring

**Actions:**
1. ✅ Cleaned duplicate Prometheus/Grafana (freed ~15 pods)
2. ✅ Disabled VPA for TruLoad
3. ✅ Increased PostgreSQL (500m/2Gi → 2000m/4Gi)
4. ✅ Increased ERP API, reduced max replicas
5. ✅ Fixed Helm template bugs

**Results:** Pod count 114 → 99, deployments stable

---

## Benefits of This Configuration

✅ **Storage Services Prioritized:** PostgreSQL and Redis get significant resources  
✅ **ERP-API Optimized:** Main service can scale to 6 replicas  
✅ **Efficient Use:** Plenty of RAM for database caching  
✅ **Auto-Scaling:** All services scale on demand  
✅ **Cost-Effective:** Min 1 replica reduces idle resource waste  
✅ **Room to Grow:** 43% RAM and 8% CPU available for bursts

