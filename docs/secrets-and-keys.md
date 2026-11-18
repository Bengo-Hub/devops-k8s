# Secrets and keys in production

How the platform's secrets reach the pods, what was checked on 2026-10-20 and 2026-11-18, and what is still open.
This file lists names and process only. No value belongs here.

## Where secrets come from

Every application and infrastructure Secret on the cluster comes from a SealedSecret in
`manifests/sealed-secrets/<namespace>/<secret-name>.sealedsecret.yaml`. The ArgoCD application
`sealed-secrets-manifests` syncs that folder (recursively), and the sealed-secrets controller in
`kube-system` decrypts each file into its Secret. Git is the only writer: nothing runs
`kubectl create`, `patch` or `apply` against these Secrets, because the controller rewrites each one
from git whenever it restarts (every node reboot), and a key that exists only in the live Secret is
lost. That is how pos-api lost `TERMINAL_JWT_SECRET` on 2026-11-07.

Files are sealed with strict scope (they decrypt only under that name in that namespace) and carry
`argocd.argoproj.io/sync-options: Prune=false`, so removing or moving a file never deletes a live
Secret. Deleting a Secret is a separate `kubectl delete sealedsecret` after the file is gone.

Not sealed, by design: cert-manager certificates and ACME keys, webhook and operator generated
certificates (ingress-nginx admission, VPA, Calico), Helm chart output (nats-box), ArgoCD's own
`argocd-secret`, `argocd-redis` and the placeholder `argocd-notifications-secret` that the
argocd-notifications application renders from git, the public Cloudflare origin-pull CA, and the
sealing keys themselves.

Since 2026-11-18 the Secrets that deploys used to write on every run are sealed too:
`registry-credentials` in each namespace, `truload/truload-frontend-env`, `cafe/cafe-website-env`
and `codevertex/codevertex-website-secrets`. Their writers changed first (see below).
`treasury/registry-credentials` followed once the KRA certification run in treasury ended, and the
empty `food-delivery` namespace (nothing deploys there any more) was deleted rather than sealed.

### Deploy-time keys outside the standard set

A service `build.sh` that needs keys the standard script does not build (a UI's env Secret,
codevertex-website's Prisma URLs and AI key) pipes them into `scripts/sealing/seal-desired.sh`:

    kubectl create secret generic <secret> -n <ns> --from-literal=K=v ... --dry-run=client -o json \
      | bash "$DEVOPS_DIR/scripts/sealing/seal-desired.sh" <ns> <secret> <app>

It follows the same generate-or-preserve rule as create-service-secrets.sh: a key the Secret lacks is
sealed, committed and synced; an existing value is kept (named, and replaced only with
`SEAL_OVERWRITE=1`); when nothing is missing it exits without a commit. It never patches or applies
the live Secret.

### Image pull secrets

`registry-credentials` (one per namespace) has a single writer, the `registry-credentials.yml`
workflow. It builds the dockerconfigjson from the `REGISTRY_*` GitHub secrets and seals it into
every namespace that has a sealed copy (or the namespaces given), commits and waits for the sync. Run
it after rotating the Docker Hub token; pull secrets are read at image pull time, so nothing needs a
restart. provision.yml and every service `build.sh` skip a `registry-credentials` Secret that a
SealedSecret owns, and only create one in a namespace that has none yet.

### Service secrets

`scripts/infrastructure/create-service-secrets.sh` runs on every service deploy. It works out the
standard keys (database and Redis URLs, SECRET_KEY, the service's encryption key,
TERMINAL_JWT_SECRET, SESSION_SECRET, INTERNAL_SERVICE_KEY where listed) with generate-or-preserve:
values that must never change are generated once and read back from the live Secret afterwards.
When the Secret already holds every key it does nothing. When a key is missing, or the Secret does
not exist yet (a brand-new service), it seals the whole Secret, commits the file to this repo with
the release-bot rebase loop and waits for the controller to sync it. A value already in the Secret
is never replaced by a deploy; the script names any key whose value differs and replaces it only
when rerun with `SEAL_OVERWRITE=1`. It writes no plaintext copy anywhere. `DRY_RUN=1` prints the
key names it would seal and stops.

### Adding or changing a key by hand

    printf 'MY_KEY=%s
' "$value_from_password_manager" | scripts/sealing/seal-keys.sh <ns> <secret> MY_KEY

Commit and push first, then refresh `sealed-secrets-manifests`, then restart the workloads that read
the key. Never apply a sealed file before it is pushed: selfHeal puts the old one back. To adopt a
Secret that exists only in the cluster, `scripts/sealing/seal-from-live.sh <ns> <secret>` seals it
as it is, then `kubectl annotate secret <secret> -n <ns> sealedsecrets.bitnami.com/managed=true`
lets the controller take it over without touching its data.

### Shared values

`scripts/sealing/shared-keys.yaml` lists every Secret that carries a shared value
(INTERNAL_SERVICE_KEY, the master database and Redis password) and the workloads to restart.
`scripts/sealing/reseal-shared-key.sh <KEY>` reads the new value once on stdin and reseals it into
all of them in one commit. R2 object storage is sealed from its GitHub secrets by the
`object-storage.yml` workflow.

### Sealing key

The controller renews its key every 30 days and keeps the old ones, so older files stay readable.
The `sealed-secrets-key-rotate.yml` workflow runs daily (and on demand) and copies the keys,
encrypted with age, to the private R2 backup bucket (`sealed-secrets-keys/`, newest 30 kept), and
gzipped to the `SEALED_SECRETS_MASTER_KEY` GitHub secret. Only the age public recipient is in this
repo; the age identity is held offline. provision.yml restores the keys before ArgoCD on a rebuilt
cluster and reads either format of the GitHub secret.

A recovery drill runs monthly on a workstation. `scripts/sealing/recovery-drill.py` does it in
memory: it fetches the newest backup from R2, decrypts it with the age identity, and opens one
value of each sealed file given to it, printing only the file, the key name and which sealing key
opened it. Nothing is written to disk.

    g(){ kubectl get secret postgresql-backup-r2-secrets -n infra -o jsonpath="{.data.$1}" | base64 -d; }
    R2_EP="$(g R2_S3_ENDPOINT)" R2_AK="$(g R2_ACCESS_KEY_ID)" R2_SK="$(g R2_SECRET_ACCESS_KEY)" \
      python3 -I scripts/sealing/recovery-drill.py <identity file> codevertex-platform-backups sealed-secrets-keys \
      manifests/sealed-secrets/auth/auth-api-secrets.sealedsecret.yaml

With the age CLI the same check is `age -d -i <identity> <backup> | gunzip` into
`kubeseal --recovery-unseal`, deleting the decrypted key file afterwards.

Drills: 2026-11-18, first backup (4 keys) decrypted; hospital, library-ui and auth files opened by
the newest key.

### Drift

The nightly `sealed-secrets-drift.yml` workflow runs `scripts/sealing/check-sealed-drift.sh`. It fails
when a sealed Secret's data was written by anything other than the controller after its last sync,
or when a SealedSecret is not Synced, and lists Opaque Secrets that have no SealedSecret behind them.
A failed scheduled run emails the account that owns the schedule. Between runs, fleet-health-watcher
pages on Slack and email when any SealedSecret is not Synced for two polls in a row (about 4
minutes). It reads SealedSecret objects only and has no access to Secrets, so the data-write check
stays in the nightly workflow.
The `no-plaintext-secrets.yml` workflow fails any push that adds a plain Secret with data under
`manifests/` or `apps/`.

## Auditing

`scripts/tools/audit-secret-refs.sh` is read-only and prints names and presence only:

    printf 'pos pos-api\ntreasury treasury-api\n' | scripts/tools/audit-secret-refs.sh

It reports secrets a deployment references that do not exist and keys missing from existing ones.

## Result of the 2026-10-20 audit

- `INTERNAL_SERVICE_KEY` is present, 48 characters and identical in all 14 API deployments and in
  the UIs that use it. Treasury (`SUBSCRIPTIONS_API_KEY`) and auth-api (`AUTH_SUBSCRIPTION_API_KEY`)
  have their own variable names that are unset; both fall back to the shared key in code, so
  nothing is broken.
- Fixed: maskani-ui referenced `maskani-ui-secrets`, which did not exist, so its subscription proxy
  had no key. The secret now exists with the shared key (the secrets script already lists maskani-ui).
- Fixed: pos-api had no `TERMINAL_JWT_SECRET`, so PIN-terminal tokens were signed with the shared
  service key (anyone holding it could mint terminal tokens for any tenant). pos-api now has its own
  secret, generated once by the script and read by the deployment without a fallback.
- Fixed (code): ordering-backend had no webhook secrets and treated an unsigned request as valid, so
  the public `POST /api/v1/webhooks/treasury` route could mark an order paid. Both ordering webhooks
  now refuse unsigned, badly signed and unconfigured requests. Nothing legitimate sends them: treasury
  has no webhook endpoints or deliveries and logistics has no sender. Set `TREASURY_WEBHOOK_SECRET`
  and `LOGISTICS_WEBHOOK_SECRET` only if a sender is ever configured.
- Known and intentional (provider keys live in the database): treasury KRA eTIMS and OSCU
  credentials, marketflow Meta, Claude, Groq and Tavily keys, isp-billing SMS, SMTP and MikroTik
  defaults.
- Still to review: isp-billing-frontend has no `NEXTAUTH_SECRET` value in its secret (its source does
  not appear to use next-auth, so it is probably a leftover reference), and auth-api's
  `PLATFORM_API_KEY` reference points at a key that does not exist (harmless because of the
  fallback; remove the reference).
- Sentry DSNs (projects-ui, ticketing-ui, isp-billing) and the projects-ui Mapbox token are optional
  and unset.

## Result of the 2026-11-18 migration

- The 2026-11-17 INTERNAL_SERVICE_KEY rotation had been patched into the seven sealed Secrets but not
  into git, so the next controller restart would have put the revoked key back on seven services.
  All seven were resealed from their live state; provision.yml no longer writes a sealed Secret.
- The sealing-key backup was three keys behind (last written 2026-08-21). It now runs daily, with
  the age-encrypted R2 copy as the primary.
- The remaining application and infrastructure Secrets were adopted namespace by namespace, each
  sealed from its live state with identical data and no pod restart.
- Eight Secrets nothing mounted (cafe backend and frontend, both Superset copies, RabbitMQ, the
  food-delivery ordering-frontend env, auth-service-token-keys, the MapTiler key) were removed.
  Their sealed copies are kept in `archive/sealed-orphans-2026-11-18/`, which nothing syncs.
- Kept on purpose: `subscriptions/subscriptions-api-secrets` (subscriptions-api's build.sh still
  writes it on every deploy) and `argocd-initial-admin-secret` (the admin password was never changed).
- The seven Stalwart mailbox Secrets hold the platform mailbox credentials, so they were sealed
  rather than removed.
