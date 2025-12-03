# VPS Resource Allocation - Optimized for 12-Core Server

## Server Specifications (Actual)
- **CPU:** 12 cores (AMD EPYC)
- **RAM:** 47GB total
- **Disk:** 242GB (158GB free)
- **Current Usage:** 87% CPU, 28% RAM

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
| **truload-backend** | 50m | 128Mi | 2 | Not actively used |
| **truload-frontend** | 50m | 128Mi | 2 | Not actively used |

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

## Benefits of This Configuration

✅ **Storage Services Prioritized:** PostgreSQL and Redis get significant resources  
✅ **ERP-API Optimized:** Main service can scale to 6 replicas  
✅ **Efficient Use:** Plenty of RAM for database caching  
✅ **Auto-Scaling:** All services scale on demand  
✅ **Cost-Effective:** Min 1 replica reduces idle resource waste  
✅ **Room to Grow:** 43% RAM and 8% CPU available for bursts

