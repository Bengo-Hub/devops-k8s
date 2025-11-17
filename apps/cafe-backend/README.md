# Cafe Backend

ArgoCD application for deploying the Go backend that powers ordering, logistics, and integrations for the Cafe platform.

## Configuration Highlights

- Namespace: `cafe`
- Image: `ghcr.io/bengobox/cafe-backend`
- Health endpoint: `/healthz`
- Metrics endpoint: `/metrics`
- Secrets: `cafe-backend-secrets` should expose `postgresUrl`
- External dependencies
  - PostgreSQL: `postgres://...` (managed secret)
  - Redis: `redis-master.infra.svc.cluster.local:6379`
  - NATS JetStream: `nats.messaging.svc.cluster.local`
  - OTEL collector for telemetry

Adjust `values.yaml` to align with environment-specific URLs, scaling requirements, and secret names.
