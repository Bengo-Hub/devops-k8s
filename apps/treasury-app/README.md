# Treasury Service

ArgoCD application deploying the Treasury Go service responsible for payments, settlements, and ledgering.

## Highlights

- Namespace: `treasury`
- Image: `ghcr.io/bengobox/treasury-app`
- Health endpoint: `/healthz`
- Metrics endpoint: `/metrics`
- Secrets: `treasury-app-secrets` should expose `postgresUrl`
- External dependencies:
  - PostgreSQL instance reachable via `postgresUrl`
  - Redis: `redis-master.treasury.svc.cluster.local:6380`
  - NATS JetStream cluster: `nats.messaging.svc.cluster.local`
  - MinIO/S3 endpoint for settlement artifacts
  - OTEL collector for tracing/metrics export

Adjust scaling, ingress, and dependency endpoints in `values.yaml` per environment.
