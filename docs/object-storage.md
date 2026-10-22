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
and 10M Class B operations a month, no egress fees. Image Transformations (enabled on the zone
2026-10-21, see Image delivery) give 5,000 unique transformations a month; beyond that new variants
fail (no charge), so pages fall back to the original image.

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
| library-api | done 2026-10-17: covers public (smaller sizes from edge Image Transformations since 2026-10-21; the server-written `_thumb` copies were retired in library-api `1694d72`), e-book files private and streamed through the API after the loan or purchase check (range requests passed to R2); all 579 covers were Open Library links and there were no e-books, so nothing moved; PVC `library-api-media` (no files) deleted with user approval |
| maskani-api | done 2026-10-17: keys `maskani/<tenant>/<kind>/...`; estate and unit photos public (market and maskani-commerce load them from the media domain), every other kind and issued PDFs private with presigned links; volume held no files; PVC `maskani-api-media` deleted with user approval |
| erp-api | done 2026-10-17: resumes, claim receipts and employee documents private (presigned links in responses; before, links pointed at a `/media` route erp-api never served); volume held no files; PVC `erp-api-media` and the unmounted legacy `erp-api-app-media` (Django era) deleted with user approval |
| marketflow-api | nothing to do (2026-10-18): stores no files, no volume |

Before dropping a volume, check the service's entrypoint and Dockerfile for media-directory setup: logistics' entrypoint ran `mkdir -p $MEDIA_ROOT/...` and crash-looped without the volume (fixed in `112f70d`).

## Image delivery

Images are resized at the edge by Cloudflare Image Transformations, switched on for the
`codevertexafrica.com` zone in the dashboard (Images, Transformations) on 2026-10-21. A variant is
the original's path behind `/cdn-cgi/image/<options>/` on the same host:

    https://media.codevertexafrica.com/cdn-cgi/image/width=256,quality=75,format=auto,fit=scale-down,onerror=redirect/<key>

Measured: a 170 KB tenant logo is 5.6 KB as a 256 px JPEG and 3.5 KB as AVIF; a 94 KB shipped
inventory menu image is 8 KB as WebP. `format=auto` serves AVIF or WebP to browsers that accept
them.

The UIs never build these links by hand. They use shared-ui-lib's `media` entry (v0.1.117+):

| Export | Use |
|---|---|
| `MediaImage` | drop-in `<img>` for stored media: srcset, sizes, lazy loading, async decoding; on error it retries the original, then `fallbackSrc` |
| `mediaImageLoaderFor(src)` | `loader` for next/image: Cloudflare for zone images, undefined (Next's own optimizer) for local assets and other hosts; zone images then need no `images.remotePatterns` entry |
| `transformImageUrl`, `imageSrcSet`, `isTransformableImage` | the rules underneath |

Rules that keep this free and safe:

- Only public https files on the zone are transformed: the media host and the API hosts' shipped
  `/media/` trees. SVG and GIF, presigned links (private bucket) and other hosts (Open Library
  covers) are used as they are. A presigned link must never be transformed, because the variant
  would be cached at the edge without the signature check.
- Widths snap to 64, 128, 256, 512, 1024 and 1600 and quality is fixed per screen, so one image
  has at most six variants. The count of unique variants is what the free allowance measures.
- `onerror=redirect` sends the browser to the original when a variant fails, including after the
  monthly allowance is used up.
- `NEXT_PUBLIC_IMAGE_TRANSFORMS=off` at build time turns the helpers into pass-throughs.
- shared-ui-lib's dist carries no `'use client'`. Server components use a one-line client boundary
  (marketflow-ui `src/components/media-image.tsx`) or a small client wrapper around next/image
  (maskani-commerce `MediaPhoto`), because a loader function cannot cross from a server component.
- Print layouts (POS receipts) keep the original files, which must be loaded before printing.

Where it is used (2026-10-21): ordering-frontend (item galleries, ImageWithFallback, TenantLogo,
avatar, brand logos), pos-ui (terminal product grid, brand chips, splash and settings logos, hotel
photos), inventory-ui, maskani-ui, maskani-commerce, treasury-ui, hospital-ui, library-ui,
logistics-ui, marketflow-ui, erp-ui, auth-ui, and library-ui covers (`07fe462`; library-api no
longer writes `_thumb` copies, `1694d72`).

The PWA media cache (`shared-ui-lib/pwa/sw-media.js`, copied into each app's `public/`) caches
`media.codevertexafrica.com` and `/cdn-cgi/image/` variants as well as the API hosts' `/media/`
trees, so offline terminals keep their images.

Usage is on the Cloudflare dashboard under Images. If it nears 5,000 a month, check which screens
request widths that are not needed before considering a paid plan (needs sign-off).

## Video ads (planned, 2026-10-22)

Status: **planned, not built.** It belongs to the MarketFlow ads autopilot, whose plan is kept in the
private workspace. Nothing below is deployed yet.

The cluster runs on one node, so the rule for video is that bytes never pass through it in volume. No
video encoding runs on the cluster. Generation and rendering happen at external providers, and so do
the WhatsApp rendition and thumbnails.

Where a finished video lives, decided per file by the worker in this order:

1. **The provider's own hosted link**, when it is public and lives long enough for review and
   publishing (for example a render provider's 30-day download link). Nothing is copied.
2. **The provider's share or public option**, switched on when the default link needs a login.
3. **A copy in the public bucket** when the provider has no public option or its link expires too
   soon. Media type `video-drafts` (httpware v0.17.0), key
   `marketflow/<tenant_id>/video-drafts/<yyyy>/<mm>/<uuid>.mp4`, unguessable and never listed. The
   media type writes a short cache header (`Cache-Control: public, max-age=300`), not the bucket's
   usual long-lived caching, so a deletion takes effect at the edge within minutes.
4. **The private bucket** with presigned links, only for tenants that switch on private previews.

Preview links are viewable by anyone who has them. Approving or publishing needs sign-in. Viewers
stream from the provider CDN or the R2 edge through a short redirect link, so only a few hundred
bytes reach the cluster. Preview videos are never sent through Image Transformations.

A copy under `media.codevertexafrica.com` sits on our own domain, so that URL prefix can be verified
with TikTok, and TikTok pulls the file itself. YouTube resumable uploads and TikTok chunked uploads
are the only places video bytes cross the cluster: streamed in 8 MB chunks, once per platform per ad.

Free tier safety:

- The service's own hourly purge deletes drafts after review. R2 lifecycle rules match a fixed
  prefix only (no wildcard for the tenant segment), so a 10-day backstop on
  `marketflow/<tenant>/video-drafts/` and `marketflow/<tenant>/video-sources/` would need one rule
  per tenant. Until that is automated, the live-bytes alert below is the backstop.
- An abort-incomplete-multipart-uploads rule (1 day) on both buckets, so abandoned footage
  uploads do not keep their parts.
- Bucket CORS for the marketflow UI origins: allow `PUT`, expose `ETag` (the browser reads each
  part's ETag during a multipart upload).
- A live-bytes gauge across both buckets: above 8 GB, new renders wait with a clear message. Each
  tenant can hold at most 5 live drafts.
- Customer footage (media type `video-sources`, private, up to 1 GB) is uploaded from the browser
  straight to R2 with presigned PUT or multipart links (`UploadURL`, `CreateMultipart`, `PartURL`,
  then `VerifyUpload`), never through ingress, so the ingress body limit (10m for marketflow) and Cloudflare's
  100 MB request limit stay as they are.

Deployment changes:

- `objectStorage.enabled: true` for marketflow-api, the new worker and marketflow-ai.
- A new `marketflow-worker` app (same image, `cmd/worker`), split out of the API pod. Requests 100m
  CPU and 256Mi, limits 1 CPU and 768Mi, 1 replica. Jobs are lock-guarded and idempotent, so a
  second replica only adds availability. It gets a new lowest-priority PriorityClass, `batch-low`
  (value -100), so the scheduler gives way to the business apps first.
- NATS subjects `marketflow.creative.>`, `marketflow.publish.>` and `conversion.>` on the
  `marketflow` stream, with one durable consumer per publishing platform.

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

The httpware Relinker keeps an old file's extension even when its bytes are another format (it
stores the sniffed Content-Type, so browsers are unaffected). auth-api's own logo move sniffs the
bytes since `92b05a4`; the one mislabelled logo (alpha-china-market, a JPEG stored as `.png`) was
copied to a `.jpg` key and repointed on 2026-10-21, and every stored auth image was checked.

## Platform database backup (disaster recovery)

The CronJob `infra/postgresql-backup` (`manifests/backup/postgresql-backup-cronjob.yaml`) runs
`pg_dumpall` of the whole Postgres cluster, which holds every service database, at 02:00 each day.
It checks the dump, copies it to R2 `codevertex-platform-backups/postgresql/` and keeps the newest 3
there and 1 on the local volume (since 2026-10-18; it kept a single copy before). Older copies are
pruned only after the new dump is confirmed on R2. The manifest is applied by the `provision.yml`
workflow, not by Argo CD: after editing it, run `kubectl diff -f` then `kubectl apply -f`.

## Tenant backups

Tenant admins back up their own data on demand from the SSO client area (accounts, My
Organization, Backups). auth-api calls `GET /api/v1/s2s/tenant-export` on the services listed in
`BACKUP_TENANT_SERVICES` (apps/auth-api/values.yaml), zips the exports to
`codevertex-media-private/auth/<tenant>/backups/` and keeps only the newest. A new service with
tenant data must serve that endpoint (httpware/tenantexport), be added to the list, and admit the
`auth` namespace in its ingress NetworkPolicy if it has one. The old per-service backup modules,
their BACKUP_* settings and tables were removed on 2026-10-19.

Which services a backup collects is decided per tenant (2026-10-20):

- Entries are `name=url` or `name=url|tag`. The tag is the subscriptions service tag the data
  belongs to and defaults to the service name; notifications and subscriptions have none.
- auth-api reads the tenant's plan from subscriptions-api
  `GET /api/v1/tenants/{id}/entitled-services` and skips every service the plan does not cover
  (`not_in_plan`). If the plan cannot be read the backup does not start (503), it never guesses.
- The organization picks services in the backup page (`POST .../backup` with
  `{"services": [...]}`; no body means every service in the plan). `GET .../backup/services`
  feeds the picker. A pick outside the plan is a 400.
- Each service is probed first (`tenant-export?probe=1`, httpware v0.15.0) and skipped as `empty`
  when the tenant has no rows, so a service the tenant never used no longer shows as included. A
  service on an older httpware has no probe: it exports, and an export with a zero-row summary is
  also `empty`. A stream without its summary line is `failed` (cut short).
- Up to 3 services export in parallel, each with a 20 minute limit; a run is claimed with one
  conditional UPDATE so two pods cannot both start it; the archive is capped at 2 GB.
- The download link is issued by `GET .../backup/download` when the user presses Download (logged
  with who asked), not on every status poll.

Known gaps: every service still accepts the one shared S2S key for the export, so a leaked key can
export any tenant (a per-caller or tenant-bound credential is not built yet); services below
httpware v0.15.0 do not answer the probe and are only skipped after a full export.

## Release step: a dead GH_PAT only fails at push

This repository is public, so a service's CI release step clones and fetches it without
credentials; an expired `GH_PAT` in that service's repository only shows up when `update-values.sh`
pushes the new image tag (`could not read Username`, reported as "check token permissions").
Re-sync it with the `sync-secrets.yml` workflow (`target_repo=Bengo-Hub/<repo>`,
`secrets=GH_PAT`). If the tag must ship meanwhile, set `image.tag` in `apps/<app>/values.yaml`.

2026-10-20: auth-api, auth-ui, erp-api, treasury-api, subscriptions-api, projects-api and marketflow-ui
failed this way, and a re-sync only held for a few hours. Cause: `sync-secrets.yml` copied
`PROPAGATE_PAT` into each repository's `GH_PAT` (and `GIT_TOKEN`), so CI pushed to devops-k8s with
the sync token, not with `GH_PAT`. Rule (user): CI always pushes with `GH_PAT`; `PROPAGATE_PAT` only
authenticates the sync itself, and `GH_PAT` is what gets synced, with `PROPAGATE_PAT` as the fallback.
Fixed in devops-k8s `0d208fa`; after re-syncing, treasury-api's stuck deploy went through. Tags for
auth-api, subscriptions-api, auth-ui and marketflow-ui had been set by hand meanwhile.
