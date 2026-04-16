# PgBouncer migration — 2026-04-16

All application services now route Postgres connections through a shared PgBouncer in `infra` namespace. Result: postgres client connections dropped from ~50 to 19, with 2000-client capacity on the pooler side.

## Pattern

Every service has a Kubernetes Secret with some subset of these keys:

```
POSTGRES_URL      postgresql://<user>:<pass>@<host>:<port>/<db>?sslmode=disable
DATABASE_URL      postgresql://<user>:<pass>@<host>:<port>/<db>
DATABASE_HOST     postgresql.infra.svc.cluster.local
DATABASE_PORT     5432
DB_HOST           postgresql.infra.svc.cluster.local
DB_PORT           5432
ConnectionStrings__DefaultConnection  (truload-backend, .NET syntax)
```

**Migration is a secret patch + pod restart.** Change:

- host: `postgresql.infra.svc.cluster.local` → `pgbouncer.infra.svc.cluster.local`
- port: `5432` → `6432`

Credentials and database name stay identical. PgBouncer uses `auth_query` against the `pgbouncer.user_lookup` helper function in `postgres` db to dynamically validate every service user's SCRAM hash — no userlist.txt entries per user needed.

## Services migrated

| Service | Namespace | Secret | Driver |
|---|---|---|---|
| treasury-api | treasury | treasury-api-secrets + treasury-api-env | Go (pgx) |
| projects-api | projects | projects-api-secrets | Go |
| subscription-api | subscriptions | subscription-api-secrets | Go |
| ticketing-api | ticketing | ticketing-api-secrets | Go |
| notifications-api | notifications | notifications-api-env | Go |
| pos-api | pos | pos-api-secrets | Go (blocked — see below) |
| iot-api | iot | iot-api-secrets | Go (HPA-scaled to 0) |
| inventory-api | inventory | inventory-api-secrets | Go |
| logistics-api | logistics | logistics-api-secrets | Go |
| ordering-backend | ordering | ordering-backend-secrets | Go |
| auth-api | auth | auth-api-secrets | Go |
| marketflow-api | marketflow | marketflow-api-secrets | Go |
| marketflow-ai | marketflow | marketflow-ai-secrets | Go |
| isp-billing-backend | isp-billing | isp-billing-backend-secrets | Python/FastAPI + SQLAlchemy |
| erp-api-app | erp | erp-api-env | Django/psycopg2 |
| truload-backend | truload | truload-backend-env | .NET/Npgsql |

## Also in this change

- **`scripts/infrastructure/create-service-secrets.sh`**: defaults changed from `PG_HOST=postgresql.infra.svc.cluster.local PG_PORT=5432` → `pgbouncer.infra.svc.cluster.local:6432`. Future runs of this script produce pgbouncer-pointed secrets. To bypass for one-off migration tasks, export `PG_HOST=postgresql.infra.svc.cluster.local PG_PORT=5432` before running.
- **`apps/pos-api/values.yaml`**: pinned tag to `ab24928c`. Image `0e86af28` panics at init (`interface {} is nil, not string` in ent runtime). Unpin after pos-service team ships a fix.
- **Duplicate secret removed**: `subscriptions/subscriptions-api-secrets` (plural, orphaned). Canonical is `subscription-api-secrets` (singular, matches Helm release name).
- **Stale RabbitMQ keys removed** from `truload/truload-backend-env`: `RabbitMQ__Host/Port/Username/Password` — rabbit was decommissioned in the 2026-04-15 optimization pass.

## Cluster-side setup (one-time, already done)

```sql
-- Run in postgres (admin_user, postgres db)
CREATE ROLE pgbouncer_auth WITH LOGIN PASSWORD '<random>';
CREATE SCHEMA pgbouncer AUTHORIZATION pgbouncer_auth;

CREATE OR REPLACE FUNCTION pgbouncer.user_lookup(i_username text, OUT uname text, OUT phash text)
RETURNS record AS $$
BEGIN
    SELECT usename, passwd FROM pg_shadow WHERE usename=i_username INTO uname, phash;
    RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION pgbouncer.user_lookup(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer.user_lookup(text) TO pgbouncer_auth;
```

```bash
# k8s Secret for pgbouncer to bootstrap-authenticate itself before running auth_query.
# Contains userlist.txt line: "pgbouncer_auth" "<plaintext password>"
kubectl create secret generic pgbouncer-auth-creds -n infra \
  --from-file=userlist.txt=/tmp/pgbouncer_userlist.txt \
  --from-literal=pgbouncer-auth-password=<password>
```

## Env name standardization (deferred — cross-repo)

Audit found one non-standard key: `TREASURY_POSTGRES_URL` (in `treasury-api-env` secret, read by the treasury-api Go app as its own canonical name). The generic `POSTGRES_URL` key also exists in the same secret. To standardize the treasury app to `POSTGRES_URL`, the change must happen in the `treasury-api` repo's `config/app.env.example` and the Go config loader — not devops-k8s. Tracking as a follow-up.

## Future migrations

When adding a new service, either:
1. Add its Application via ArgoCD with the normal template (which references a per-service secret).
2. Run `scripts/infrastructure/create-service-secrets.sh <service-name>` — new defaults will point the generated secret at PgBouncer automatically.

## Rollback

Per-service rollback (if pgbouncer ever misbehaves):

```bash
# Point a single service back at postgresql directly
NS=<namespace>; SECRET=<secret>; DEPLOY=<deployment>
kubectl get secret -n $NS $SECRET -o json | \
  python3 -c "import sys,json,base64; d=json.load(sys.stdin); \
    for k in ('POSTGRES_URL','DATABASE_URL'):
      if k in d['data']:
        v=base64.b64decode(d['data'][k]).decode().replace('pgbouncer.infra.svc.cluster.local:6432','postgresql.infra.svc.cluster.local:5432'); \
        d['data'][k]=base64.b64encode(v.encode()).decode()
    for k,v in (('DATABASE_HOST','postgresql.infra.svc.cluster.local'),('DATABASE_PORT','5432'),('DB_HOST','postgresql.infra.svc.cluster.local'),('DB_PORT','5432')):
      if k in d['data']: d['data'][k]=base64.b64encode(v.encode()).decode()
    print(json.dumps(d))" | kubectl apply -f -
kubectl rollout restart deploy/$DEPLOY -n $NS
```
