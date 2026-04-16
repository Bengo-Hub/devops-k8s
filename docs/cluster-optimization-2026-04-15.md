# Cluster optimization — 2026-04-15

Single-node k3s on Contabo (12 vCPU / 47Gi / 484Gi). Changes below rebalance resources, remove dead weight, and tune autoscaling (HPA + VPA). A KEDA HTTP scale-to-zero pilot was attempted and then reverted on 2026-04-16 — the KEDA HTTP add-on chart 0.10.0 didn't expose `conditionWaitTimeout` via values, so first-request cold starts 502'd and couldn't be reliably raised. Notes left here so the next attempt knows what blocked us.

## Changes in this repo

**Removed**
- `apps/rabbitmq/` + `manifests/databases/rabbitmq-statefulset.yaml` + `manifests/databases/rabbitmq-values.yaml` — no consumers across any service. Messaging is NATS/JetStream.
- `scripts/infrastructure/install-rabbitmq.sh`
- RabbitMQ alert rule in `manifests/monitoring/db-queue-alerts.yaml` (replaced with NATS JetStream lag alert)
- Broken Redis/RabbitMQ HPAs in `manifests/infrastructure-hpa.yaml` (HPA can't target StatefulSets; file now holds Postgres + Redis VPAs only)

**Added**
- `apps/vpa/app.yaml` — installs Fairwinds VPA (recommender + updater + admission controller). Required for the PostgreSQL/Redis VPAs to take effect.
- `apps/pgbouncer/app.yaml` + `manifests/databases/pgbouncer.yaml` — shared transaction-mode connection pooler. Listens on `pgbouncer.infra.svc.cluster.local:6432`, multiplexes app connections onto 20 real PG backends (max_client_conn=2000). Migrate apps by swapping `POSTGRES_URL` host from `postgresql.infra` → `pgbouncer.infra` and port `5432` → `6432`.
- Priority classes: `ingress-critical` (ingress-nginx, coredns), `platform-high` (argocd, prometheus, cert-manager) in `manifests/priorityclasses/db-critical.yaml`. Attach via `spec.priorityClassName` in each workload.

**Right-sized**
- PostgreSQL: req 500m/2Gi → **1000m/3Gi**, lim 2000m/8Gi → **4000m/12Gi**. `shared_buffers` 2Gi → 3Gi, `effective_cache_size` 6Gi → 9Gi, `work_mem` 16 → 32Mi.
- erp-api: req 200m/512Mi → **300m/768Mi**, lim 1000m/1Gi → **1500m/1.5Gi**.
- truload-backend: req 100m/256Mi → **200m/512Mi**, lim 500m/512Mi → **1000m/1Gi**.

**HPA enabled (min=1, max=2, CPU 70%)** on: inventory-api, logistics-api, iot-api, pos-api, projects-api, subscriptions-api, ticketing-api, treasury-api, notifications-api, isp-billing-backend, marketflow-api, truload-backend.

## Cluster-side actions you need to run (SSH)

```bash
# 1. Verify RabbitMQ truly empty before deletion
kubectl exec -n infra rabbitmq-0 -- rabbitmqctl list_queues name messages 2>&1 | head
kubectl exec -n infra rabbitmq-0 -- rabbitmqctl list_connections 2>&1 | head

# 2. Remove RabbitMQ (after ArgoCD prunes the Application)
kubectl delete application rabbitmq -n argocd --wait=false
kubectl delete statefulset rabbitmq -n infra
kubectl delete pvc data-rabbitmq-0 data-rabbitmq-1 -n infra
kubectl delete svc rabbitmq rabbitmq-headless -n infra 2>/dev/null

# 3. Remove orphan marketflow Ollama PVC (shared Ollama in shared-infra is the one in use)
kubectl -n marketflow delete statefulset ollama 2>/dev/null
kubectl -n marketflow delete svc ollama 2>/dev/null
kubectl -n marketflow delete pvc ollama-data-ollama-0

# 4. Investigate duplicate Prometheus install (audit found 3 alertmanager + 3 prometheus PVCs)
kubectl get pvc -n infra | grep -E 'prometheus|alertmanager'
helm list -A | grep -iE 'prom|monitor'
# Expected: ONE prometheus stack. If multiple helm releases, uninstall the duplicate.

# 5. After ArgoCD picks up the new apps (vpa, pgbouncer):
kubectl -n vpa get pods                # should see recommender/updater/admission
kubectl -n infra get pods -l app=pgbouncer

# 6. Migrate apps to PgBouncer (one at a time, non-breaking):
# Update POSTGRES_URL secret host to pgbouncer.infra.svc.cluster.local:6432
# Rolling restart the deployment. Watch connection count:
kubectl -n infra exec postgresql-0 -- psql -U admin_user -c "SELECT count(*) FROM pg_stat_activity;"

# 7. Apply priority classes to ingress-nginx / argocd / prometheus:
kubectl -n ingress-nginx patch deploy ingress-nginx-controller --patch '{"spec":{"template":{"spec":{"priorityClassName":"ingress-critical"}}}}'
kubectl -n kube-system patch deploy coredns --patch '{"spec":{"template":{"spec":{"priorityClassName":"ingress-critical"}}}}'
kubectl -n argocd patch deploy argocd-server --patch '{"spec":{"template":{"spec":{"priorityClassName":"platform-high"}}}}'
```

## Deferred / flagged

- **Duplicate monitoring stacks**: audit found PVCs for both `monitoring-kube-prometheus-*` and `prometheus-*` and `prometheus-kube-prometheus-*` — three stacks' worth of prometheus/alertmanager storage. Inspect with `helm list -A` and delete the duplicates (reclaims ~40Gi).
- **PVC auto-delete in cleanup job**: left as list-only. Auto-deleting unmounted PVCs risks data loss during rolling restarts.
- **Media PVC sizes**: erp-api/inventory-api/ordering-backend/truload define no explicit `persistence.size` — inherit chart default. Set explicitly before growth bites.
