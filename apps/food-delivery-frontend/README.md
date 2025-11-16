# Food Delivery Frontend

ArgoCD application deploying the Next.js frontend for the Food Delivery platform using the shared `charts/app` Helm chart.

## Key Settings

- Namespace: `food-delivery`
- Image: `ghcr.io/bengobox/food-delivery-frontend`
- Ingress: `app.food-delivery.bengobox.com`
- Health probe path: `/healthz`
- External dependencies: Food Delivery backend API, Notifications service, Mapbox

Secrets referenced:

- `food-delivery-frontend-secrets`
  - `mapboxToken`
  - `sentryDsn`

Update `values.yaml` to align with production domains or scaling requirements.
