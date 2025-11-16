# Food Delivery Backend

ArgoCD application for deploying the Go backend that powers ordering, logistics, and integrations for the Food Delivery platform.

## Configuration Highlights

- Namespace: `food-delivery`
- Image: `ghcr.io/bengobox/food-delivery-backend`
- Health endpoint: `/healthz`
- Metrics endpoint: `/metrics`
- Secrets: `food-delivery-backend-secrets` should expose `postgresUrl`
- External dependencies
  - PostgreSQL: `postgres://...` (managed secret)
  - Redis: `redis-master.food-delivery.svc.cluster.local:6379`
  - NATS JetStream: `nats.messaging.svc.cluster.local`
  - OTEL collector for telemetry

Adjust `values.yaml` to align with environment-specific URLs, scaling requirements, and secret names.
