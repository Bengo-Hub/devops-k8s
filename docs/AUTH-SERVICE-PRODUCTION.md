# Auth Service Production Setup

## Overview

The Auth Service handles authentication, authorization, and SSO for the BengoBox platform. It automatically runs migrations and seeds initial data on deployment.

## Database Setup

### Automatic Initialization

The auth-service deployment includes init containers that automatically:

1. **Run Migrations** (`auth-migrate`): Creates all database tables and schema
2. **Seed Data** (`auth-seed`): Creates default tenant and admin user

### Default Credentials

#### Tenant
- **Slug**: `codevertex`
- **Name**: CodeVertex
- **Status**: active

#### Admin User
- **Email**: `admin@codevertexitsolutions.com`
- **Password**: `ChangeMe123!`
- **Roles**: `superuser`

## API Endpoints

### Health Check
```bash
GET https://sso.codevertexitsolutions.com/healthz
```

### Swagger Documentation
```bash
GET https://sso.codevertexitsolutions.com/swagger/
```

### Login
```bash
POST https://sso.codevertexitsolutions.com/api/v1/auth/login

{
  "email": "admin@codevertexitsolutions.com",
  "password": "ChangeMe123!",
  "tenant_slug": "codevertex"
}
```

**⚠️ Important**: The tenant slug must be `codevertex` (NOT `bengobox`)

## Deployment Flow

### Init Containers (Sequential)

1. **migrate-schema**
   - Command: `/usr/local/bin/auth-migrate`
   - Connects to PostgreSQL
   - Runs Ent schema migrations
   - Creates all tables
   - Idempotent (safe to run multiple times)

2. **seed-data**
   - Command: `/usr/local/bin/auth-seed`
   - Creates `codevertex` tenant (if not exists)
   - Creates admin user (if not exists)
   - Sets up tenant membership
   - Idempotent (safe to run multiple times)

3. **Main Container** (after init containers succeed)
   - Command: `/usr/local/bin/auth`
   - Starts HTTP server on port 4101
   - Serves API and Swagger docs

## Troubleshooting

### Check Database Tables
```bash
kubectl exec -n infra postgresql-0 -c postgresql -- \
  psql -U admin_user -d auth -c "\dt"
```

### Check Tenant
```bash
kubectl exec -n infra postgresql-0 -c postgresql -- \
  psql -U admin_user -d auth -c "SELECT slug, name, status FROM tenants;"
```

### Check Users
```bash
kubectl exec -n infra postgresql-0 -c postgresql -- \
  psql -U admin_user -d auth -c "SELECT email, status FROM users;"
```

### Check Pod Logs
```bash
# Init container logs
kubectl logs -n auth <pod-name> -c migrate-schema
kubectl logs -n auth <pod-name> -c seed-data

# Main container logs
kubectl logs -n auth <pod-name> -f
```

### Health Check
```bash
kubectl exec -n auth <pod-name> -- wget -qO- http://localhost:4101/healthz
```

## Configuration

### Environment Variables

Set in `devops-k8s/apps/auth-service/values.yaml`:

```yaml
env:
  - name: AUTH_SERVICE_ENV
    value: production
  - name: AUTH_DB_URL
    valueFrom:
      secretKeyRef:
        name: auth-service-secrets
        key: postgresUrl
  - name: SEED_ADMIN_PASSWORD
    value: "ChangeMe123!"  # Change in production!
```

### Secrets

Required secrets in `auth-service-secrets`:
- `postgresUrl`: PostgreSQL connection string
- `REDIS_PASSWORD`: Redis password (optional)

JWT Keys secret `auth-token-keys`:
- `private.pem`: RSA private key (4096-bit)
- `public.pem`: RSA public key

## Production Checklist

- [ ] Database migrations run successfully
- [ ] Seed data created (1 tenant, 1 user)
- [ ] Health endpoint responds
- [ ] Login works with correct tenant slug
- [ ] JWT keys mounted and accessible
- [ ] Redis connection working
- [ ] Ingress TLS certificate issued
- [ ] Change default admin password!

## Common Issues

### Issue 1: "Failed to fetch" Error
**Cause**: Wrong tenant slug (`bengobox` instead of `codevertex`)
**Fix**: Use `tenant_slug: "codevertex"` in login requests

### Issue 2: No Users in Database
**Cause**: Seed init container failed
**Fix**: Check init container logs, ensure database is accessible

### Issue 3: Migrations Failed
**Cause**: Database connection issues
**Fix**: Verify `AUTH_DB_URL` secret, check PostgreSQL pod status

### Issue 4: Init Container Restart Loop
**Cause**: Database credentials incorrect
**Fix**: Verify secret contains correct `postgresUrl`

## Security Notes

1. **Change Default Password**: The default admin password `ChangeMe123!` should be changed immediately after first login
2. **JWT Keys**: Auto-generated 4096-bit RSA keys are stored in Kubernetes secret
3. **Database User**: Uses master password from `POSTGRES_PASSWORD`
4. **TLS**: Ingress automatically provisions Let's Encrypt certificate

## Architecture

```
┌─────────────────────────────────────────────┐
│         Auth Service Pod                    │
├─────────────────────────────────────────────┤
│  Init Container 1: migrate-schema           │
│  ├─ /usr/local/bin/auth-migrate             │
│  └─ Creates database schema                 │
├─────────────────────────────────────────────┤
│  Init Container 2: seed-data                │
│  ├─ /usr/local/bin/auth-seed                │
│  └─ Creates tenant + admin user             │
├─────────────────────────────────────────────┤
│  Main Container: auth                       │
│  ├─ /usr/local/bin/auth                     │
│  ├─ HTTP Server: 0.0.0.0:4101               │
│  ├─ Endpoints: /healthz, /api/v1/*, /swagger│
│  └─ Connects to: PostgreSQL + Redis         │
└─────────────────────────────────────────────┘
         ↓                    ↓
  PostgreSQL (infra)    Redis (infra)
```

## Related Files

- **Dockerfile**: `auth-service/Dockerfile` (builds all 3 binaries)
- **Values**: `devops-k8s/apps/auth-service/values.yaml`
- **Chart**: `devops-k8s/charts/app/templates/deployment.yaml`
- **Seed Logic**: `auth-service/cmd/seed/main.go`
- **Migrate Logic**: `auth-service/cmd/migrate/main.go`

