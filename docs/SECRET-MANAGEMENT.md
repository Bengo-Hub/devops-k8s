# Secret Management for ArgoCD Deployments

Pre-created imperative Secrets (a script or workflow running `kubectl create secret` before ArgoCD
syncs) are retired. Every Secret an application or infrastructure component reads is a SealedSecret
in `manifests/sealed-secrets/<namespace>/<secret-name>.sealedsecret.yaml`, synced by the
`sealed-secrets-manifests` ArgoCD application and decrypted in the cluster by the sealed-secrets
controller. Git is the only writer.

How it works, how to add or change a key, how shared values are rotated, how the sealing key is
backed up and how drift is detected: [secrets-and-keys.md](secrets-and-keys.md).

## Rules

1. Never `kubectl create`, `patch` or `apply` a Secret that a SealedSecret owns. The controller
   rewrites it from git at its next restart (every node reboot) and the change is lost.
2. Never commit a plain `kind: Secret` with `data` or `stringData` under `manifests/` or `apps/`. The
   `no-plaintext-secrets.yml` workflow fails such a push.
3. Commit and push a sealed file before refreshing ArgoCD; selfHeal puts the previous file back
   otherwise.
4. Do not let a Helm chart render a Secret whose values you need to control. Point the chart at an
   existing Secret name (`existingSecret` or similar) and seal that Secret.
5. A Secret that ArgoCD itself renders from git (an application's own `secret.yaml`) is not sealed
   as well; one Secret, one writer.

## History

Until November 2026 Secrets were pre-created by `provision.yml`, `create-service-secrets.sh` and
service `build.sh` scripts, and the Superset chart had its own pre-created pair (Superset is no
longer deployed and its Secrets were removed on 2026-11-18). The move to SealedSecrets is recorded
in secrets-and-keys.md under "Result of the 2026-11-18 migration".
