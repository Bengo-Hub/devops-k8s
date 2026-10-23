# marketflow-worker

MarketFlow's background worker: NATS consumers (leads, conversions, CRM events, agents) and the
scheduled jobs (nurture steps, re-engagement, ad insights, chat retention, connected-account
token health, cron agents, SLA and meeting prep).

- **Manifest:** `manifests/marketflow-worker-deployment.yaml` (plain Deployment, applied by this
  Argo CD app). There is no `values.yaml`.
- **Image:** the marketflow-api image, started with `MF_ROLE=worker`. The entrypoint applies
  migrations (advisory-locked, idempotent) and then runs `/usr/local/bin/marketflow-worker` in the
  foreground. Each marketflow-api release moves the manifest's image through
  `update_plain_manifest_image` in marketflow-api's `build.sh`, the same pattern as
  `auth-session-cleanup`.
- **Env:** mirrors `apps/marketflow-api/values.yaml`. Add a worker setting to both files.
- **Scheduling:** PriorityClass `batch-low` (value -100, never preempts), so on the single node the
  business apps are scheduled first and this pod waits or is evicted first.
- **Health:** `/healthz` on port 4002 drives the startup, readiness and liveness probes, so a
  crashed worker is restarted (inside the API pod a dead background worker went unnoticed).
- **Why it is split from the API pod (Sprint 14):** its own restarts and probe, its own CPU and
  memory limits (heavy jobs such as video copies and platform uploads cannot slow or OOM the API),
  a lower priority, one copy instead of one per API replica, and a clean SIGTERM drain.

Rollout: this Deployment goes live first while the API pods still run the worker inline
(`MF_ROLE` unset means `all`). The jobs claim their period and consumers are durable, so running
both briefly is safe. Once this pod is healthy, `MF_ROLE=api` is set in
`apps/marketflow-api/values.yaml`.
