#!/usr/bin/env bash
set -euo pipefail

# Script to seed initial data for auth-service
# Creates default tenant and admin user

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE=${NAMESPACE:-auth}
IMAGE=${IMAGE:-docker.io/codevertex/auth-service:latest}
SEED_PASSWORD=${SEED_PASSWORD:-ChangeMe123!}

echo "=================================="
echo "Auth Service - Seed Initial Data"
echo "=================================="
echo "Namespace: ${NAMESPACE}"
echo "Image: ${IMAGE}"
echo "Admin Password: ******"
echo ""

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    echo "Error: Namespace ${NAMESPACE} does not exist"
    exit 1
fi

# Create seed job
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: auth-service-seed-$(date +%s)
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: auth-service
        component: seed
    spec:
      restartPolicy: Never
      imagePullSecrets:
      - name: registry-credentials
      containers:
      - name: seed
        image: ${IMAGE}
        command: ["/usr/local/bin/seed"]
        envFrom:
        - secretRef:
            name: auth-service-secrets
        env:
        - name: SEED_ADMIN_PASSWORD
          value: "${SEED_PASSWORD}"
        resources:
          requests:
            memory: 256Mi
            cpu: 100m
          limits:
            memory: 512Mi
            cpu: 500m
EOF

echo ""
echo "✓ Seed job created"
echo ""
echo "Monitor with:"
echo "  kubectl logs -n ${NAMESPACE} -l component=seed --follow"
echo ""

