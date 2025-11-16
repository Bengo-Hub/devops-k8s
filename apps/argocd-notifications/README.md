# Argo CD Notifications

This app configures Argo CD's built-in Notifications using plain manifests (no Helm chart).

Manifests live at `manifests/argocd-notifications/`:
- `configmap.yaml` — defines services, templates, and triggers
- `secret.yaml` — provides sensitive values (referenced via `${secret:...}` in the ConfigMap)

The Argo CD Application at `apps/argocd-notifications/app.yaml` points to that path.

## Notes

- Namespace: `argocd`
- Default configuration enables basic webhook-based triggers.
- Configure delivery channels (Slack, email, webhook, etc.) by editing `configmap.yaml` and referencing secrets with `${secret:<name>:<key>}`.
- Provide real values in `secret.yaml` (or replace with your preferred secret management like Sealed Secrets).
- Optional subscriptions can be added by defining a `subscription.*` entry in the ConfigMap.
