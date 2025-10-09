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
- Common (per service; adjust to your stack):
  - DATABASE_URL: e.g., postgresql://user:pass@host:5432/db
  - REDIS_URL: e.g., redis://:pass@host:6379/0
  - CELERY_BROKER_URL: typically same as REDIS_URL
  - CELERY_RESULT_BACKEND: typically same as REDIS_URL
  - JWT_SECRET: random 32-64 chars
  - DJANGO_SECRET_KEY (Django apps): random 50 chars
  - DEBUG: "False"
  - ALLOWED_HOSTS: e.g., api.domain.tld,localhost,127.0.0.1
  - NEXT_PUBLIC_API_URL (for UI): e.g., https://api.domain.tld

Optional (based on DB type):
- PostgreSQL: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
- MySQL: MYSQL_URL or MYSQL_* variants
- MongoDB: MONGO_URL

Kube Config
-----------
Provide `KUBE_CONFIG` (base64) as an org/repo secret for the workflow to apply secrets automatically.

Defaults and Auto-generation
----------------------------
- If `KUBE_CONFIG` is missing, cluster operations (kubectl, secret apply) are skipped.
- If `JWT_SECRET` is missing in the target Kubernetes Secret (`env_secret_name`), the workflow will generate a 64-hex random value and create/patch the secret with `JWT_SECRET`.
- Database passwords (`POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `MONGO_PASSWORD`, `MYSQL_PASSWORD`) are auto-generated when `setup_databases: true` and the corresponding secrets are not provided.


