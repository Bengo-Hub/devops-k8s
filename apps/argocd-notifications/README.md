# Argo CD Notifications

Installs the official [`argocd-notifications`](https://github.com/argoproj/argo-helm/tree/master/charts/argocd-notifications) chart to enable sync status alerts from Argo CD.

## Notes

- Namespace: `argocd`
- Default configuration deploys the controller with basic triggers enabled.
- Configure delivery channels (Slack, email, webhook, etc.) by extending the `helm.values` section within `app.yaml` or by providing a secret named `argocd-notifications-secret` per the chart documentation.
- Subscriptions array is empty by default—add team specific subscriptions before enabling in production.
