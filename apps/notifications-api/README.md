# Notifications Service

ArgoCD application deploying the multi-channel notifications platform.

## Highlights

- Namespace: `notifications`
- Image: `ghcr.io/bengobox/notifications-api`
- Health endpoint: `/healthz`
- Metrics endpoint: `/metrics`
- Secrets:
  - `notifications-api-secrets` – provides `postgresUrl`
  - `notifications-provider-secrets` – env-fallback provider credentials (SendGrid, Twilio, FCM). The actual active defaults are SMTP (email) and Africa's Talking (SMS) — see `internal/providers/manager.go`'s DB-first/env-fallback resolution order; these secret-backed env vars are only consulted when no DB-stored `ProviderSetting` exists.
- External dependencies:
  - PostgreSQL: tenant/template metadata
  - Redis: rate limiting, idempotency
  - NATS JetStream: inbound/outbound events
  - OTEL collector for telemetry export

Update `values.yaml` with environment-specific hosts, provider secrets, and scaling requirements.
