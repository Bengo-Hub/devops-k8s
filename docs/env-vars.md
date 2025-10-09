Environments and Secrets
------------------------

Each app should provide `kubeSecrets/devENV.yaml` in its repo with a namespaced Secret manifest containing all required environment variables for that environment.

Example `kubeSecrets/devENV.yaml`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: erp-api-env
  namespace: erp
type: Opaque
stringData:
  DATABASE_URL: postgresql://user:pass@host:5432/db
  REDIS_URL: redis://host:6379/0
  JWT_SECRET: change-me
```

Required Variables
------------------
- DATABASE_URL, REDIS_URL, JWT_SECRET (example; define per-service)

Kube Config
-----------
Provide `KUBE_CONFIG` (base64) as an org/repo secret for the workflow to apply secrets automatically.


