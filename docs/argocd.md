Argo CD Setup
-------------

1. Install Argo CD in `argocd` namespace.
2. Configure a repo credential (SSH deploy key) for `devops-k8s`.
3. Apply applications:

```yaml
# apps/erp-api/app.yaml and apps/erp-ui/app.yaml
```

4. Enable automated sync and self-heal.
5. Optionally configure App of Apps pattern to group applications per environment.


