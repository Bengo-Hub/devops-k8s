# Notifications Service

ArgoCD application deploying the multi-channel notifications platform.

## Highlights

- Namespace: `notifications`
- Image: `ghcr.io/bengobox/notifications-app`
- Health endpoint: `/healthz`
- Metrics endpoint: `/metrics`
- Secrets:
  - `notifications-app-secrets` – provides `postgresUrl`
  - `notifications-provider-secrets` – provider API credentials (SendGrid, Twilio, FCM)
- External dependencies:
  - PostgreSQL: tenant/template metadata
  - Redis: rate limiting, idempotency
  - NATS JetStream: inbound/outbound events
  - OTEL collector for telemetry export

Update `values.yaml` with environment-specific hosts, provider secrets, and scaling requirements.
