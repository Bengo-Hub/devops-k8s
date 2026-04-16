# KEDA HTTP scale-to-zero — 2026-04-16

First UI pilot: `treasury-ui` (host `books.codevertexitsolutions.com`). Pod drops to 0 replicas after ~5 min idle; first request wakes it via the KEDA interceptor. This is the DigitalOcean/AWS scale-to-zero pattern on self-hosted k3s.

## Cluster-side prerequisites

**KEDA operator** (already installed): `apps/keda/` deploys `keda` chart into `infra`. Provides the CRDs (`ScaledObject`, `HTTPScaledObject`, `TriggerAuthentication`, etc.).

**KEDA HTTP add-on** (already installed, but two fixes applied in this commit to `apps/keda-http/app.yaml`):
1. Override `kubeRbacProxy` sidecar image — default `gcr.io/kubebuilder/kube-rbac-proxy:v0.13.0` was removed when kubebuilder migrated registries. Set to `quay.io/brancz/kube-rbac-proxy:v0.14.4`.
2. Scale interceptor + scaler to 1 replica each (chart default was 3 each, burning ~1.5 CPU for nothing on a single node).

## The pattern — 3 objects per UI

For each UI that should scale to zero, add these three k8s objects (all in the UI's own namespace):

1. **HTTPScaledObject** (http.keda.sh/v1alpha1). Tells KEDA:
   - which deployment to scale (treasury-ui)
   - which hostname to watch (books.codevertexitsolutions.com)
   - replica bounds (0 to 2)
   - request-rate target (50 req/s/pod with 1-minute window)

2. **ExternalName Service** (`keda-http-interceptor`). Bridges cross-namespace: the UI's Ingress (in its own ns) can't directly target `keda-add-ons-http-interceptor-proxy.infra` — k8s Ingress backends are same-namespace. The ExternalName creates a local alias.

3. **Ingress**. Overrides the chart-managed ingress. Backend points at the bridge service (`keda-http-interceptor:8080`).

Example: [manifests/keda-http/treasury-ui.yaml](../manifests/keda-http/treasury-ui.yaml)

## Chart change per UI

In `apps/<ui>/values.yaml` set `ingress.enabled: false`. The chart's templated ingress would conflict with the standalone one in `manifests/keda-http/<ui>.yaml`. Everything else (deployment, service, PDB, etc.) still comes from the chart.

## Request flow

```
Internet → nginx Ingress (books.codevertexitsolutions.com)
        → keda-http-interceptor ExternalName (treasury ns)
        → keda-add-ons-http-interceptor-proxy.infra:8080
        → (if replicas=0) buffer request, signal scaler, wait for pod
        → treasury-ui service:80 → treasury-ui pod
```

Cold start latency: ~30-60 seconds on first request. Subsequent requests go straight through once the deployment is warm.

## Validation (post-deploy)

```bash
# 1. HTTPScaledObject should be Ready
kubectl get httpscaledobject -n treasury
# 2. After ~5 min idle, deployment should scale to 0
kubectl get deploy treasury-ui -n treasury
# 3. First request scales it back up
curl -sk -o /dev/null -w "cold start: %{time_total}s\n" https://books.codevertexitsolutions.com/
# 4. Second request is warm
curl -sk -o /dev/null -w "warm: %{time_total}s\n" https://books.codevertexitsolutions.com/
```

## Rolling out to other UIs

Candidates (low traffic, non-critical):
- projects-ui, ticketing-ui, subscriptions-ui, notifications-ui, truload-docs, cafe-website

For each, copy `manifests/keda-http/treasury-ui.yaml` → `manifests/keda-http/<ui>.yaml`, update:
- the three `name` fields (all `treasury-ui` → `<ui>`)
- `hosts[0]` and ingress `host` to the UI's hostname
- `secretName` in ingress TLS to match the UI's cert
- `service` + `port` in HTTPScaledObject `scaleTargetRef` if port differs

And in `apps/<ui>/values.yaml` set `ingress.enabled: false`.

The new `apps/keda-http-pilot/` ArgoCD Application watches `manifests/keda-http/` recursively — adding a new file in that folder is enough to get it synced.

## Rollback

Revert `ingress.enabled: true` in the UI's values.yaml, delete the three objects from `manifests/keda-http/<ui>.yaml`, and let ArgoCD reconcile. The chart's ingress will come back and the UI will serve directly from its pod (which HPA keeps at min=1).

## Known quirks

- `keda-add-ons-http-controller-manager` had an `ImagePullBackOff` on the `kube-rbac-proxy` sidecar until the image override was applied. Symptom: HTTPScaledObjects show status Ready but the interceptor returns 502 because it doesn't know about the host-to-service mapping. Fix applied in this commit.
- Restarting the interceptor/external-scaler after adding or changing HTTPScaledObjects ensures they pick up the new routing table:
  ```
  kubectl rollout restart deploy/keda-add-ons-http-interceptor -n infra
  kubectl rollout restart deploy/keda-add-ons-http-external-scaler -n infra
  ```
- **nginx ingress + ExternalName service**: nginx caches the resolved upstream, which can cause 502s after scale-from-zero. Add `nginx.ingress.kubernetes.io/service-upstream: "true"` to the ingress to force per-request DNS resolution of the bridge service. (Already applied on live ingresses; follow-up to bake this into `manifests/keda-http/*.yaml`.)
- **Cold-start timeout = 20s, not configurable via chart 0.10.0**: the `KEDA_CONDITION_WAIT_TIMEOUT` env var is hard-coded in the chart's interceptor Deployment template. Next.js cold starts often exceed 20s, so the first request after idle returns 502. A browser retry (or a client that automatically retries 5xx) lands on the warmed pod and succeeds. Workarounds:
  - Set `min: 1` on the HTTPScaledObject (keeps one warm pod always, no true scale-to-zero but still request-rate scaling)
  - Pre-warm via an external pinger that hits `/healthz` every N minutes
  - Wait for the keda-add-ons-http chart to expose the timeout (tracked upstream)
- **ACME HTTP-01 challenge**: when the chart-managed ingress is disabled and the standalone ingress routes to the interceptor, cert-manager's HTTP-01 solver adds its own higher-precedence Ingress for `/.well-known/acme-challenge/<token>` automatically, so certificate issuance/renewal still works. No action needed.
- **Pre-existing image pull failures** (projects-ui:latest, ticketing-ui:latest, truload-docs:latest): these tags don't exist on the registry. KEDA wiring is correct; fixing the tags is an app-team concern.
