# calcom — self-hosted Cal.com for MarketFlow scheduling

Cal.com deployment at `https://calendar.codevertexitsolutions.com`. Used as the embedded booking widget on FBO profile pages (`/p/{slug}`) and inside the agentic RAG `book_meeting` tool's fallback when Google Calendar is not linked.

## Prerequisites

1. Create the `calcom` database in the shared infra Postgres:
   ```sql
   CREATE DATABASE calcom OWNER calcom_user;
   GRANT ALL PRIVILEGES ON DATABASE calcom TO calcom_user;
   ```
2. Provision the secret `calcom-secrets` in the `calcom` namespace:
   ```
   DATABASE_URL              postgresql://calcom_user:PASS@postgresql.infra.svc.cluster.local:5432/calcom
   NEXTAUTH_SECRET           32-byte base64
   CALENDSO_ENCRYPTION_KEY   32-byte base64 (used for OAuth token encryption)
   CRON_API_KEY              random 32-byte string (for reminder cron)
   EMAIL_SERVER_HOST         smtp-relay.brevo.com   (optional)
   EMAIL_SERVER_USER         …                      (optional)
   EMAIL_SERVER_PASSWORD     …                      (optional)
   ```
   Use SealedSecrets or kubectl directly:
   ```
   kubectl create ns calcom
   kubectl -n calcom create secret generic calcom-secrets \
     --from-literal=DATABASE_URL=… \
     --from-literal=NEXTAUTH_SECRET=$(openssl rand -base64 32) \
     --from-literal=CALENDSO_ENCRYPTION_KEY=$(openssl rand -base64 32) \
     --from-literal=CRON_API_KEY=$(openssl rand -hex 32)
   ```

## Manifests

| File | Purpose |
|------|---------|
| `namespace.yaml` | Creates the `calcom` namespace |
| `deployment.yaml` | Single-replica rolling (Recreate strategy keeps DB migrations safe) |
| `service.yaml`    | ClusterIP exposing port 80 → 3000 |
| `ingress.yaml`    | HTTPS at `calendar.codevertexitsolutions.com` with Let's Encrypt |
| `app.yaml`        | ArgoCD Application pointing at `apps/calcom/manifests` |

## Integration with MarketFlow

1. Tenant admin enables Cal.com in `/platform/providers` by entering the instance URL + admin API key.
2. Per-tenant booking pages are created on first use of the `book_meeting` agent tool (or manually from `/[orgSlug]/settings/integrations`).
3. Cal.com's webhook at `BOOKING_CREATED` fires `POST https://marketflowapi.codevertexitsolutions.com/api/v1/webhooks/calcom/booking` — handler at `marketflow-api/internal/modules/webhooks/calcom_handler.go` creates the `ScheduledMeeting` row.

## Upgrade

Cal.com release cadence is ~monthly. Bump the `image` tag in `deployment.yaml`, merge to `main`, ArgoCD will roll out. Run `kubectl logs` during rollout to confirm the Prisma migrations succeed.
