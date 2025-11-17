# Cafe Frontend

ArgoCD application deploying the Next.js frontend for the Cafe platform using the shared `charts/app` Helm chart.

## Key Settings

- Namespace: `cafe`
- Image: `ghcr.io/bengobox/cafe-frontend`
- Ingress: `app.cafe.bengobox.com`
- Health probe path: `/healthz`
- External dependencies: Cafe backend API, Notifications service, Mapbox

Secrets referenced:

- `cafe-frontend-secrets`
  - `mapboxToken`
  - `sentryDsn`

Update `values.yaml` to align with production domains or scaling requirements.
