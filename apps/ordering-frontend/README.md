# Ordering Frontend

ArgoCD application deploying the Next.js frontend for the Ordering service using the shared `charts/app` Helm chart.

## Key Settings

- Namespace: `ordering`
- Domain: `ordersapp.codevertexitsolutions.com`
- Image: `docker.io/codevertex/ordering-frontend`
- Health probe path: `/healthz`
- External dependencies: Ordering backend API, Notifications service, Mapbox

Secrets referenced:

- `ordering-frontend-secrets`
  - `mapboxToken`
  - `sentryDsn`

Update `values.yaml` to align with production domains or scaling requirements.
