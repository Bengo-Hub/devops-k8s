# Object storage (Cloudflare R2)

All services store files (media, documents, exports, tenant backups) in two R2 buckets through
the shared Go package `github.com/Bengo-Hub/httpware/objectstore` (v0.8.0+). This replaces the
per-service media PVCs and the in-cluster MinIO (its open source server is archived and no
longer maintained).

| Bucket | Holds | Served |
|---|---|---|
| `codevertex-media-public` | avatars, logos, item and menu images, covers, other public pictures | `https://media.codevertexafrica.com/<key>`, cached by Cloudflare (keys never change content) |
| `codevertex-media-private` | KYC, patient photos, signatures, documents, attachments, exports, backups | only by presigned links (15 minutes by default) |

Keys: `<service>/<tenant_id>/<media_type>/<yyyy>/<mm>/<uuid>.<ext>`, or
`<service>/users/<user_id>/<media_type>/...` for personal media. Old `/media/<path>` values map to
`<service>/legacy/<public|private>/<path>`.

R2 free tier (2026-10): 10 GB-month storage, 1M Class A and 10M Class B operations a month, no
egress fees.

## Setup

1. Repository secrets (already present): `CF_R2_ACCOUNT_ID`, `CF_R2_API_TOKEN`,
   `CF_R2_S3_ENDPOINT`, `CF_R2_ACCESS_KEY_ID`, `CF_R2_SECRET_ACCESS_KEY`, `CF_API_TOKEN`,
   `KUBE_CONFIG`.
2. Run the `Object Storage (Cloudflare R2)` workflow (`.github/workflows/object-storage.yml`):
   - `buckets`: creates both buckets, CORS (GET and HEAD from any origin) on the public one, and
     binds the public domain to it.
   - `secrets`: writes Secret `object-storage` (`OBJECT_STORAGE_*`) into each namespace listed.
   - `all`: both. Every step is idempotent, so it can be run again after adding a namespace or
     rotating the R2 key.
3. In an app's `values.yaml` set:

   ```yaml
   objectStorage:
     enabled: true
   ```

   The chart then loads the Secret through `envFrom` (optional, so a pod starts before it exists;
   the service falls back to `MEDIA_ROOT` then).

## Rotating the R2 key

Create a new R2 API token in Cloudflare, update `CF_R2_ACCESS_KEY_ID` and
`CF_R2_SECRET_ACCESS_KEY`, run the workflow with `secrets`, then restart the deployments.

## Still manual

`postgresql-backup-r2-secrets` (infra namespace, platform Postgres backups to
`codevertex-platform-backups`) was created by hand and is not yet written by this workflow.
