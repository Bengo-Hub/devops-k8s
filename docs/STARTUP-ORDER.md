# Startup order after a node reboot

The cluster runs on a single node (mss-prod-master). When kured reboots it for a kernel or OS
update (`apps/kured/app.yaml`, window 22:00 to 23:00 UTC), every pod on the node starts again at
the same moment. Before November 2026 nothing decided who goes first, so services that need
auth-api at startup raced it and lost.

## What went wrong on 13 November 2026

After the kured reboot, notifications-api, hadia-api, erp-api, marketflow-ai and most other Go
APIs exited with

```
failed to initialise app: auth validator init: initial JWKS fetch: JWKS fetch failed: status 503
```

or `connect: connection refused` on the in-cluster auth-api address, and the migrations in their
entrypoints hit `connection refused` on PostgreSQL. They sat in Error and CrashLoopBackOff for
minutes, and email OTPs stopped because notifications-api was down. The same race caused the
2026-09-01 incident noted at the top of `apps/auth-api/values.yaml`; the `auth-critical`
PriorityClass added then helps auth-api win CPU, but it does not hold anyone back.

I fixed it in two places:

1. **Ordering in the chart.** An opt-in init container, `wait-for-deps`, holds the app container
   back until the services it cannot start without answer.
2. **Resilience in code.** The shared auth client (`github.com/Bengo-Hub/shared-auth-client`,
   published as `github.com/Bengo-Hub/auth-client`) no longer treats a failed first JWKS fetch
   as fatal. It retries with backoff for up to 30 seconds, then starts without keys, keeps
   retrying in the background and answers 503 for bearer requests until the keys load.

The ordering makes the normal case clean. The code change is what stops a crash loop when the
ordering is not enough, for example when the public JWKS hostname is still not routing.

## The layers

Only hard startup dependencies count: something whose absence makes the process exit during
init. Runtime calls that have timeouts, fallbacks or circuit breakers do not need ordering.

| Layer | Services | Hard startup dependencies |
|---|---|---|
| L0 infrastructure | postgresql, pgbouncer, redis-master (infra), nats (messaging), ingress-nginx-controller | none of ours |
| L1 | auth-api | postgresql (entrypoint migrations use the direct URL), pgbouncer, Redis, NATS |
| L2 | notifications-api, hadia-api, erp-api, pos-api, inventory-api, ordering-backend, treasury-api, subscription-api, logistics-api, library-api, hospital-api, projects-api, ticketing-api, maskani-api, marketflow-api, marketflow-ai | their database (postgresql, plus pgbouncer where used) and auth-api's JWKS. Some also need NATS or Redis, see below |
| L3 | none today | |

Extra hard dependencies inside L2:

- hadia-api exits without NATS outside local runs (`nats connection at startup`).
- marketflow-api exits without Redis or NATS (`connect to NATS`).
- marketflow-ai exits without Redis (`ping redis`).
- Every other L2 service only warns when Redis or NATS is missing and keeps running.

Why L3 is empty: I checked every service's app wiring for fatal init errors, and none of them
calls another L2 service at startup. auth-api calls subscription-api only at request time (JWT
enrichment, 5s timeout), and the tenant syncers and role pushes that call auth-api at startup log
and carry on when it fails. If a service ever starts failing init because a peer is down, it
becomes L3 and lists that peer the same way L2 lists auth-api.

Most L2 services fetch the JWKS from the public hostname (sso.codevertexafrica.com), which goes
out through ingress-nginx, so they also wait for the ingress controller. hadia-api and
maskani-api read the JWKS in-cluster and skip that check.

## How the wait works

The shared chart (`charts/app`) renders the init container when an app sets
`startupDependencies`. The template lives in `charts/app/templates/_helpers.tpl`
(`app.waitForDepsContainer`) and is placed first in the pod's init containers in
`charts/app/templates/deployment.yaml`.

- Each entry is either `url` (an HTTP GET that must return 2xx, through busybox `wget`, 3 second
  timeout per try) or `tcp` (a plain connect, through `nc -z`, 3 second timeout per try).
- Checks run in the listed order, every `startupWait.intervalSeconds` (5 by default).
- All entries share one total budget, `startupWait.timeoutSeconds` (600 by default). When it runs
  out, the container logs which dependency never answered and exits 0, so the app starts anyway.
  A dependency that stays down can delay a pod by at most about ten minutes and never blocks it
  for good.
- The image is `busybox:1.36`, the same tiny image the chart already uses for `init-media`. It
  runs as nobody (65534), read-only root filesystem, no privilege escalation, all capabilities
  dropped, RuntimeDefault seccomp, with 5m/8Mi requested and 50m/32Mi limits. A pod reserves
  the larger of its init and app requests, so this adds nothing to the node's bill.
- If the busybox build ever lacks `nc -z`, the script says so in its log and skips the TCP checks
  instead of waiting out the whole budget.
- During an ordinary rolling deploy every dependency is already up, so the init container passes
  in well under a second.

Checks always use the cluster Service DNS, never a public hostname, so the wait does not depend
on Cloudflare. The auth-api check uses the JWKS document itself,
`http://auth-api.auth.svc.cluster.local:4000/api/v1/.well-known/jwks.json`, which is exactly
what the validator needs. The Service only routes to ready auth-api pods, so a 200 there means
auth-api finished its migrations and seed.

### Network policy

The init container runs with the pod's labels and namespace, so it can reach what the app can.
auth-api's ingress policy (`manifests/network-policies/auth-api-ingress.yaml`) lists every L2
namespace already. A new service that waits on auth-api must have its namespace added there
first, or the check times out after ten minutes.

## Adding a dependency

1. Confirm it is a hard startup dependency: find the error the service returns from its app
   wiring (`internal/app/app.go` or `cmd/server/main.go`) when the peer is down. If it only logs
   a warning, it does not belong in the list.
2. Add an entry to the app's `apps/<service>/values.yaml`:

   ```yaml
   startupDependencies:
     - name: postgresql
       tcp: postgresql.infra.svc.cluster.local:5432
     - name: auth-api
       url: http://auth-api.auth.svc.cluster.local:4000/api/v1/.well-known/jwks.json
     - name: pos-api            # an L3 dependency on an L2 service
       url: http://pos-api.pos.svc.cluster.local:4000/healthz
   ```

   For HTTP, point at a cheap endpoint that answers 200 only when the peer can serve (its health
   or readiness route). For infrastructure, use TCP.
3. If the target has an ingress NetworkPolicy, add the caller's namespace to it.
4. Never create a cycle: a service must not wait on anything in its own layer or above. The
   bounded budget means a cycle would not deadlock forever, but every pod in it would sit out
   the full ten minutes.
5. Render the chart locally before pushing (commands below).

Optional per-app tuning:

```yaml
startupWait:
  timeoutSeconds: 300   # total budget across all entries
  intervalSeconds: 5
```

## Scheduling priority

PriorityClasses already exist in `manifests/priorityclasses/`: `db-critical` (PostgreSQL, Redis,
pgbouncer, Stalwart), `ingress-critical` (ingress-nginx), `auth-critical` (auth-api),
`platform-high` and `batch-low`. The chart passes `priorityClassName` through. On one node
priority only matters when the node is short of CPU or memory, which is exactly the
reboot-recovery case, so the infra and auth tiers keep their head start. NATS runs without a
PriorityClass today; adding one means a NATS rolling restart, so I left it as a separate change.

## kured

I reviewed `apps/kured/app.yaml` and changed nothing. `drainTimeout: 5m` with `forceReboot: true`
is still right for a single node (the drain can never fully succeed here, see the comments in
that file), and the one-hour window with a 30 minute period gives two chances per night.
Ordering after the reboot is handled by the init containers above, not by kured.

## Checking it after a reboot

```bash
# which pods are still held back
kubectl get pods -A | grep Init:
# what one of them is waiting for
kubectl logs -n notifications deploy/notifications-api -c wait-for-deps
# a pod that gave up waiting says so
kubectl logs -n <ns> <pod> -c wait-for-deps | grep "starting anyway"
```

A healthy recovery shows L0 pods Running first, then auth-api, then the L2 services leaving
`Init:0/1` within a few seconds of auth-api turning ready.

## Validating chart changes

```bash
helm lint charts/app -f apps/auth-api/values.yaml
helm template auth-api charts/app -f apps/auth-api/values.yaml | grep -A40 "name: wait-for-deps"
helm template notifications-api charts/app -f apps/notifications-api/values.yaml | grep -A40 "name: wait-for-deps"
```
