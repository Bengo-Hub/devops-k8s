# devops-k8s app values (CORS and ingress)

This folder mirrors the **apps** layout used in **Bengo-Hub/devops-k8s**. Each `apps/<app_name>/values.yaml` includes:

- **Ingress** configuration with **NGINX CORS annotations** so all SSO-integrating frontend origins are allowed when calling backend APIs.
- **env** where applicable (e.g. `HTTP_ALLOWED_ORIGINS` for ordering-backend).

**Canonical reference:** [shared-docs/devops-k8s-ingress-cors.md](../shared-docs/devops-k8s-ingress-cors.md).

**Usage:** Copy or merge these values into your actual devops-k8s repo (e.g. Bengo-Hub/devops-k8s). If your Helm charts use a different structure, copy only the `ingress.annotations` block into your Ingress resource or chart values.

**Apps included:** auth-api, ordering-backend, notifications-api, logistics-api, treasury-api, inventory-api, pos-api, subscriptions-api.
