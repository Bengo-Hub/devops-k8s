#!/bin/bash
# Database Credentials Verification Script
# Checks if PostgreSQL and Redis secrets are correctly configured

set -euo pipefail

NAMESPACE=${1:-erp}

echo "=== Database Credentials Verification ==="
echo "Namespace: $NAMESPACE"
echo ""

# Check PostgreSQL secret
echo "1. PostgreSQL Secret Check:"
if kubectl -n $NAMESPACE get secret postgresql >/dev/null 2>&1; then
    echo "✅ PostgreSQL secret exists"
    
    # Check for postgres-password key
    PG_ADMIN_PASS=$(kubectl -n $NAMESPACE get secret postgresql -o jsonpath='{.data.postgres-password}' 2>/dev/null | base64 -d || echo "")
    if [[ -n "$PG_ADMIN_PASS" ]]; then
        echo "✅ postgres-password key found (length: ${#PG_ADMIN_PASS})"
    else
        echo "❌ postgres-password key NOT found"
    fi
    
    # Check for password key (app user)
    PG_APP_PASS=$(kubectl -n $NAMESPACE get secret postgresql -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
    if [[ -n "$PG_APP_PASS" ]]; then
        echo "✅ password key found (app user, length: ${#PG_APP_PASS})"
    else
        echo "⚠️  password key NOT found (no custom app user configured)"
    fi
    
    # List all keys in secret
    echo "   Available keys in secret:"
    kubectl -n $NAMESPACE get secret postgresql -o jsonpath='{.data}' | jq -r 'keys[]' | sed 's/^/     - /'
else
    echo "❌ PostgreSQL secret NOT found"
fi
echo ""

# Check Redis secret
echo "2. Redis Secret Check:"
if kubectl -n $NAMESPACE get secret redis >/dev/null 2>&1; then
    echo "✅ Redis secret exists"
    
    REDIS_PASS=$(kubectl -n $NAMESPACE get secret redis -o jsonpath='{.data.redis-password}' 2>/dev/null | base64 -d || echo "")
    if [[ -n "$REDIS_PASS" ]]; then
        echo "✅ redis-password key found (length: ${#REDIS_PASS})"
    else
        echo "❌ redis-password key NOT found"
    fi
    
    # List all keys
    echo "   Available keys in secret:"
    kubectl -n $NAMESPACE get secret redis -o jsonpath='{.data}' | jq -r 'keys[]' | sed 's/^/     - /'
else
    echo "❌ Redis secret NOT found"
fi
echo ""

# Check erp-api-env secret
echo "3. Application Environment Secret Check (erp-api-env):"
if kubectl -n $NAMESPACE get secret erp-api-env >/dev/null 2>&1; then
    echo "✅ erp-api-env secret exists"
    
    # Check DATABASE_URL
    DATABASE_URL=$(kubectl -n $NAMESPACE get secret erp-api-env -o jsonpath='{.data.DATABASE_URL}' 2>/dev/null | base64 -d || echo "")
    if [[ -n "$DATABASE_URL" ]]; then
        # Mask password in output
        MASKED_URL=$(echo "$DATABASE_URL" | sed -E 's/:([^@]+)@/:***@/')
        echo "✅ DATABASE_URL: $MASKED_URL"
    else
        echo "❌ DATABASE_URL NOT set"
    fi
    
    # Check REDIS_URL
    REDIS_URL=$(kubectl -n $NAMESPACE get secret erp-api-env -o jsonpath='{.data.REDIS_URL}' 2>/dev/null | base64 -d || echo "")
    if [[ -n "$REDIS_URL" ]]; then
        MASKED_REDIS=$(echo "$REDIS_URL" | sed -E 's/:([^@]+)@/:***@/')
        echo "✅ REDIS_URL: $MASKED_REDIS"
    else
        echo "❌ REDIS_URL NOT set"
    fi
    
    echo "   All environment keys:"
    kubectl -n $NAMESPACE get secret erp-api-env -o jsonpath='{.data}' | jq -r 'keys[]' | sed 's/^/     - /'
else
    echo "❌ erp-api-env secret NOT found"
fi
echo ""

# Test PostgreSQL connection
echo "4. PostgreSQL Connection Test:"
if [[ -n "${PG_ADMIN_PASS:-}" ]]; then
    echo "   Testing connection with postgres user..."
    POD_NAME=$(kubectl -n $NAMESPACE get pod -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$POD_NAME" ]]; then
        if kubectl -n $NAMESPACE exec $POD_NAME -- bash -c "PGPASSWORD='$PG_ADMIN_PASS' psql -U postgres -d bengo_erp -c 'SELECT 1;'" >/dev/null 2>&1; then
            echo "✅ PostgreSQL connection successful"
        else
            echo "❌ PostgreSQL connection failed"
            echo "   Try manually: kubectl -n $NAMESPACE exec -it $POD_NAME -- psql -U postgres -d bengo_erp"
        fi
    else
        echo "⚠️  PostgreSQL pod not found"
    fi
else
    echo "⚠️  Skipping (no password available)"
fi
echo ""

# Summary
echo "=== Summary ==="
echo ""
if [[ -n "${PG_ADMIN_PASS:-}" && -n "${REDIS_PASS:-}" && -n "${DATABASE_URL:-}" ]]; then
    echo "✅ All credentials are configured correctly"
    echo ""
    echo "Migration should work. If it still fails, check:"
    echo "  - Migration job has correct imagePullSecrets"
    echo "  - Pod can resolve DNS (postgresql.infra.svc.cluster.local)"
    echo "  - Network policies allow pod-to-pod communication"
else
    echo "❌ Some credentials are missing. Run these commands to fix:"
    echo ""
    if [[ -z "${PG_ADMIN_PASS:-}" ]]; then
        echo "# Set PostgreSQL password:"
        echo "kubectl -n $NAMESPACE create secret generic postgresql \\"
        echo "  --from-literal=postgres-password=YOUR_PASSWORD \\"
        echo "  --dry-run=client -o yaml | kubectl apply -f -"
        echo ""
    fi
    if [[ -z "${DATABASE_URL:-}" ]]; then
        echo "# Update erp-api-env with DATABASE_URL:"
        echo "PG_PASS=\$(kubectl -n $NAMESPACE get secret postgresql -o jsonpath='{.data.postgres-password}' | base64 -d)"
        echo "kubectl -n $NAMESPACE patch secret erp-api-env -p \\"
        echo "  \"{\\\"stringData\\\":{\\\"DATABASE_URL\\\":\\\"postgresql://postgres:\${PG_PASS}@postgresql.infra.svc.cluster.local:5432/bengo_erp\\\"}}\""
        echo ""
    fi
fi

