# Object storage (Cloudflare R2)

All services store files (media, documents, exports, tenant backups) in two R2 buckets through
the shared Go package `github.com/Bengo-Hub/httpware/objectstore` (v0.8.0+). This replaces the
per-service media PVCs and the in-cluster MinIO (its open source server is archived and no
longer maintained).

| Bucket | Holds | Served |
|---|---|---|
| `codevertex-media-public` | avatars, logos, item and menu images, covers, other public pictures | `https://media.codevertexafrica.com/<key>`, cached by Cloudflare (keys never change content) |
| `codevertex-media-private` | KYC, patient photos, signatures, documents, attachments, exports, backups | only by presigned links (15 minutes by default) |

Keys: `<service>/<tenant_id>/<media_type>/<yyyy>/<mm>/<uuid>.<ext>` (uploads) or
`<service>/<tenant_id>/<media_type>/<content hash>.<ext>` (moved files), and
`<service>/users/<user_id>/<media_type>/...` for personal media. Rows store the key.

Free tiers only (no paid Cloudflare feature without sign-off): R2 10 GB-month storage, 1M Class A
and 10M Class B operations a month, no egress fees. Image Transformations, if enabled later, give
5,000 unique transformations a month; beyond that new variants fail (no charge), so pages must fall
back to the original image.

## Moving a service off its media volume

1. Deploy the service version on `objectstore` with `objectStorage.enabled: true`. Old `/media/...`
   values keep being served from the volume, so nothing breaks.
2. In the pod run the service's `relink-media` command (report), then with `--apply`. Every file a
   row still references is uploaded under its tenant's key and the row is updated; files no row
   references are not moved. It is safe to run again.
3. Rerun the report until nothing is left to move, then release the PVC and drop `MEDIA_ROOT`,
   `MEDIA_URL_BASE` and `persistence` from the values (ask before deleting a PVC: it destroys data).

Replaced or removed images delete their old file right after the row is saved, once no other row
of the tenant uses it, so storage only holds files in use.

| Service | State |
|---|---|
| treasury-api | done (never had a media volume) |
| inventory-api | done 2026-10-17: relinked, PVC `inventory-api-media` released, `MEDIA_ROOT=/app/media` (shipped icons and demo pictures inside the image) |
| ordering-backend | done 2026-10-17: uploads require a signed-in tenant user (were anonymous), volume was empty so nothing moved, PVC `ordering-backend-media` released, no `MEDIA_*` env |
| pos-api | done 2026-10-17: damage evidence and lost-and-found photos private (signed links), screensavers and job attachments public; volume held no files; PVC `pos-api-media` released |
| auth-api | done 2026-10-17: tenant logos, service icons and profile pictures stored on the public bucket, rows keep the link; 7 tenants and 2 users with inline images moved at startup; 2026-10-18 legal signature images moved from base64 in the row to the private bucket (no rows existed); no volume |
| logistics-api | done 2026-10-17: KYC and proof-of-delivery files private (presigned), uploads require sign-in (were anonymous); the volume held only test KYC files (user: hard delete), PVC `logistics-api-media` released; map volumes (tileserver, valhalla) untouched |
| hospital-api | done 2026-10-17: patient photos private (presigned); production had no media volume (an upload would have been lost on restart), no patient had a photo |
| library-api | done 2026-10-17: covers public with a thumbnail next to each, e-book files private and streamed through the API after the loan or purchase check (range requests passed to R2); all 579 covers were Open Library links and there were no e-books, so nothing moved; PVC `library-api-media` (no files) deleted with user approval |
| maskani-api | done 2026-10-17: keys `maskani/<tenant>/<kind>/...`; estate and unit photos public (market and maskani-commerce load them from the media domain), every other kind and issued PDFs private with presigned links; volume held no files; PVC `maskani-api-media` deleted with user approval |
| erp-api | done 2026-10-17: resumes, claim receipts and employee documents private (presigned links in responses; before, links pointed at a `/media` route erp-api never served); volume held no files; PVC `erp-api-media` and the unmounted legacy `erp-api-app-media` (Django era) deleted with user approval |
| marketflow-api | nothing to do (2026-10-18): stores no files, no volume |

Before dropping a volume, check the service's entrypoint and Dockerfile for media-directory setup: logistics' entrypoint ran `mkdir -p $MEDIA_ROOT/...` and crash-looped without the volume (fixed in `112f70d`).

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

## Platform database backup (disaster recovery)

The CronJob `infra/postgresql-backup` (`manifests/backup/postgresql-backup-cronjob.yaml`) runs
`pg_dumpall` of the whole Postgres cluster, which holds every service database, at 02:00 each day.
It checks the dump, copies it to R2 `codevertex-platform-backups/postgresql/` and keeps the newest 3
there and 1 on the local volume (since 2026-10-18; it kept a single copy before). Older copies are
pruned only after the new dump is confirmed on R2. The manifest is applied by the `provision.yml`
workflow, not by Argo CD: after editing it, run `kubectl diff -f` then `kubectl apply -f`.

Tenant backups (download of one tenant's data from the SSO client area) are separate and on demand;
see the object storage plan, Phase 5.
