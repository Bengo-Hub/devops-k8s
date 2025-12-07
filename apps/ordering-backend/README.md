# Ordering Backend

ArgoCD application for deploying the Go backend that powers ordering, logistics, and integrations for the Ordering service.

## Configuration Highlights

- Namespace: `ordering`
- Domain: `orderapi.codevertexitsolutions.com`
- Image: `docker.io/codevertex/ordering-backend`
- Health endpoint: `/healthz`
- Metrics endpoint: `/metrics`
- Secrets: `ordering-backend-secrets` should expose `postgresUrl`
- External dependencies
  - PostgreSQL: `postgres://...` (managed secret)
  - Redis: `redis-master.infra.svc.cluster.local:6379`
  - NATS JetStream: `nats.messaging.svc.cluster.local`
  - OTEL collector for telemetry

Adjust `values.yaml` to align with environment-specific URLs, scaling requirements, and secret names.
