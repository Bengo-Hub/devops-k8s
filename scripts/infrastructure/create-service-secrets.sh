#!/usr/bin/env bash
set -euo pipefail

# Provisions a service's Secret as a SealedSecret (manifests/sealed-secrets/<ns>/<secret>.sealedsecret.yaml).
# Standardized keys: POSTGRES_URL, POSTGRES_MIGRATE_URL, REDIS_URL, REDIS_PASSWORD, SECRET_KEY, DATABASE_*
# plus the per-service generate-or-preserve keys below. All Go backends read these env keys.
# It never patches a live Secret: missing keys are sealed and committed to this repo (see the write
# step at the end). Needs kubectl access and push rights on this checkout (build.sh clones it with GH_PAT).
#
# Usage:
#   SERVICE_NAME=auth-api ./create-service-secrets.sh
#   SERVICE_NAME=ordering-backend NAMESPACE=ordering ./create-service-secrets.sh
#   SERVICE_NAME=treasury-api NAMESPACE=treasury ./create-service-secrets.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tools/common.sh"

# Configuration
SERVICE_NAME=${SERVICE_NAME:-}
NAMESPACE=${NAMESPACE:-}
DB_NAME=${DB_NAME:-}
DB_USER=${DB_USER:-}
SECRET_NAME=${SECRET_NAME:-}

# Validate service name
if [[ -z "$SERVICE_NAME" ]]; then
    log_error "SERVICE_NAME is required"
    echo ""
    echo "Usage:"
    echo "  SERVICE_NAME=auth-api ./create-service-secrets.sh"
    echo "  SERVICE_NAME=ordering-backend NAMESPACE=ordering ./create-service-secrets.sh"
    echo ""
    echo "Supported services:"
    echo "  - auth, ordering, treasury, inventory, logistics, erp"
    echo "  - subscriptions, projects, notifications"
    echo "  - truload, isp-billing, ticketing, cafe, pos"
    exit 1
fi

# Infer namespace from service name if not provided
if [[ -z "$NAMESPACE" ]]; then
    case "$SERVICE_NAME" in
        auth-api)
            NAMESPACE="auth"
            ;;
        auth-ui)
            NAMESPACE="auth"
            ;;
        subscriptions-api)
            NAMESPACE="subscriptions"
            ;;
        subscriptions-ui)
            NAMESPACE="subscriptions"
            ;;
        notifications-api)
            NAMESPACE="notifications"
            ;;
        notifications-ui)
            NAMESPACE="notifications"
            ;;
        logistics-ui)
            NAMESPACE="logistics"
            ;;
        logistics-api)
            NAMESPACE="logistics"
            ;;
        ordering-backend)
            NAMESPACE="ordering"
            ;;
        ordering-frontend)
            NAMESPACE="ordering"
            ;;
        treasury-api)
            NAMESPACE="treasury"
            ;;
        treasury-ui)
            NAMESPACE="treasury"
            ;;
        inventory-api)
            NAMESPACE="inventory"
            ;;
        inventory-ui)
            NAMESPACE="inventory"
            ;;
        pos-api)
            NAMESPACE="pos"
            ;;
        pos-ui)
            NAMESPACE="pos"
            ;;
        erp-api)
            NAMESPACE="erp"
            ;;
        erp-ui)
            NAMESPACE="erp"
            ;;
        projects-api)
            NAMESPACE="projects"
            ;;
        projects-ui)
            NAMESPACE="projects"
            ;;
        # Subscription service — note: namespace is "subscriptions" (plural) but
        # the Helm release/secret uses "subscription-api" (singular)
        subscription-api)
            NAMESPACE="subscriptions"
            ;;
        ticketing-api)
            NAMESPACE="ticketing"
            ;;
        ticketing-ui)
            NAMESPACE="ticketing"
            ;;
        truload-backend)
            NAMESPACE="truload"
            ;;
        truload-frontend)
            NAMESPACE="truload"
            ;;
        isp-billing-backend)
            NAMESPACE="isp-billing"
            ;;
        isp-billing-frontend)
            NAMESPACE="isp-billing"
            ;;
        cafe-website)
            NAMESPACE="cafe"
            ;;
        rider-app)
            NAMESPACE="logistics"
            ;;
        *)
            # Try to extract namespace from service name
            NAMESPACE=$(echo "$SERVICE_NAME" | sed 's/-service$//' | sed 's/-backend$//' | sed 's/-app$//' | sed 's/-api$//' | sed 's/-ui$//' | sed 's/-frontend$//')
            ;;
    esac
fi

# Infer database name from service name if not provided
if [[ -z "$DB_NAME" ]]; then
    DB_NAME=$(echo "$SERVICE_NAME" | sed 's/-service$//' | sed 's/-backend$//' | sed 's/-api$//' | sed 's/-app$//' | tr '-' '_')
fi

# Infer database user from database name if not provided
if [[ -z "$DB_USER" ]]; then
    DB_USER="${DB_NAME}_user"
fi

# Infer secret name if not provided
if [[ -z "$SECRET_NAME" ]]; then
    SECRET_NAME="${SERVICE_NAME}-secrets"
fi

log_section "Creating Secrets for ${SERVICE_NAME}"

log_info "Configuration:"
echo "  Service Name: ${SERVICE_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Database Name: ${DB_NAME}"
echo "  Database User: ${DB_USER}"
echo "  Secret Name: ${SECRET_NAME}"
echo ""

# Function to generate secure random password
generate_password() {
    local length=${1:-32}
    openssl rand -base64 48 | tr -d "=+/" | cut -c1-${length}
}

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
    log_warning "Namespace ${NAMESPACE} does not exist. Creating..."
    kubectl create namespace "${NAMESPACE}"
fi

# Check if secret already exists and retrieve existing values to avoid rotation
EXISTING_SECRET_KEY=""
if kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log_info "Secret ${SECRET_NAME} already exists. Retrieving existing values to avoid rotation..."
    EXISTING_SECRET_KEY=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.SECRET_KEY}" 2>/dev/null | base64 -d || echo "")
    
    # Never for a sealed Secret: deleting it would just be recreated from git by the controller.
    if [[ "${ENABLE_CLEANUP:-false}" == "true" && -z "$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="SealedSecret")].name}' 2>/dev/null)" ]]; then
        log_info "Cleanup mode active: Existing secret will be fully replaced."
        kubectl delete secret "${SECRET_NAME}" -n "${NAMESPACE}"
    fi
fi

# Generate passwords and connection strings
log_info "Generating secure passwords..."

# Database password - Priority: POSTGRES_PASSWORD env > cluster secret > generate
PG_NAMESPACE=${PG_NAMESPACE:-infra}
# Default host/port now point at PgBouncer (transaction pooler) instead of
# postgresql directly. Every app connects through pgbouncer to multiplex onto
# ~20 real PG backends. To bypass pgbouncer for a one-off task, export
# PG_HOST=postgresql.infra.svc.cluster.local PG_PORT=5432 before running.
PG_HOST=${PG_HOST:-pgbouncer.infra.svc.cluster.local}
PG_PORT=${PG_PORT:-6432}

# Try to get password - Priority: POSTGRES_PASSWORD env > admin-user-password secret > postgres-password secret
# CRITICAL: Service users now use POSTGRES_PASSWORD (master password) for consistency
DATABASE_PASSWORD=""
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    log_info "Using POSTGRES_PASSWORD from environment (GitHub secret - master password)"
    DATABASE_PASSWORD="${POSTGRES_PASSWORD}"
elif kubectl get secret postgresql -n "${PG_NAMESPACE}" >/dev/null 2>&1; then
    # Get master password from admin-user-password (used for all service users)
    DATABASE_PASSWORD=$(kubectl get secret postgresql -n "${PG_NAMESPACE}" -o jsonpath="{.data.admin-user-password}" 2>/dev/null | base64 -d || echo "")
    
    if [[ -z "$DATABASE_PASSWORD" ]]; then
        # Fallback to postgres-password if admin-user-password not found
        DATABASE_PASSWORD=$(kubectl get secret postgresql -n "${PG_NAMESPACE}" -o jsonpath="{.data.postgres-password}" 2>/dev/null | base64 -d || echo "")
    fi
    
    if [[ -n "$DATABASE_PASSWORD" ]]; then
        log_info "Retrieved master password from PostgreSQL secret (used for all service users)"
    fi
fi

# Generate new password if not found (should not happen in production)
if [[ -z "$DATABASE_PASSWORD" ]]; then
    DATABASE_PASSWORD=$(generate_password 32)
    log_warning "Generated new password. This should not happen in production!"
    log_warning "Ensure POSTGRES_PASSWORD is set or PostgreSQL secret exists."
fi

# Application SECRET_KEY (used by some services for encryption/session)
if [[ -n "${SECRET_KEY:-}" ]]; then
    APP_SECRET_KEY="$SECRET_KEY"
elif [[ -n "${EXISTING_SECRET_KEY:-}" ]]; then
    log_info "Retrieved existing app SECRET_KEY from cluster"
    APP_SECRET_KEY="$EXISTING_SECRET_KEY"
else
    APP_SECRET_KEY=$(generate_password 64)
    log_info "Generated new app SECRET_KEY"
fi

# ENCRYPTION_SALT — stable salt for isp-billing's at-rest config encryption
# (router credentials, etc.). Without a fixed salt the app generates a random one
# on every restart, so anything encrypted by one pod becomes undecryptable after a
# restart. Read-existing-first so it NEVER rotates once set (rotating it would
# orphan previously-encrypted data). Scoped to isp-billing-backend only.
APP_ENCRYPTION_SALT=""
if [[ "${SERVICE_NAME}" == "isp-billing-backend" ]]; then
    EXISTING_ENCRYPTION_SALT=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.ENCRYPTION_SALT}" 2>/dev/null | base64 -d || echo "")
    if [[ -n "${ENCRYPTION_SALT:-}" ]]; then
        APP_ENCRYPTION_SALT="$ENCRYPTION_SALT"
    elif [[ -n "${EXISTING_ENCRYPTION_SALT:-}" ]]; then
        log_info "Retrieved existing ENCRYPTION_SALT from cluster (preserved)"
        APP_ENCRYPTION_SALT="$EXISTING_ENCRYPTION_SALT"
    else
        APP_ENCRYPTION_SALT=$(openssl rand -hex 32)
        log_info "Generated new ENCRYPTION_SALT for isp-billing-backend"
    fi
fi

# CREDENTIAL_ENCRYPTION_KEY — stable AES-256 key (base64 of 32 bytes) for at-rest
# credential/token encryption in the Go services that support a UI-configurable
# key. Resolution in-app is DB-first; this env var is the FALLBACK. Read-existing-
# first so it NEVER rotates once set (rotating would silently fall decryption back
# to older candidate keys). Each service reads a differently-named env var.
APP_ENC_KEY_VAR=""
case "${SERVICE_NAME}" in
    treasury-api)      APP_ENC_KEY_VAR="TREASURY_GATEWAY_ENCRYPTION_KEY" ;;
    ordering-backend)  APP_ENC_KEY_VAR="GOOGLE_TOKEN_ENCRYPTION_KEY" ;;
    # marketflow's deployment maps secret data-key ENCRYPTION_KEY -> env MF_SECURITY_ENCRYPTION_KEY.
    marketflow-api)    APP_ENC_KEY_VAR="ENCRYPTION_KEY" ;;
    notifications-api) APP_ENC_KEY_VAR="SECURITY_ENCRYPTION_KEY" ;;
    # maskani-api: AES-GCM field encryption of identity numbers and KRA PINs. Must never rotate.
    maskani-api)       APP_ENC_KEY_VAR="FIELD_ENCRYPTION_KEY" ;;
    # hadia-api: AES-GCM field encryption of phones, guest contacts and payout numbers (key ring root;
    # rotation adds keys through FIELD_ENCRYPTION_KEYS, never by replacing this one). Must never rotate.
    hadia-api)         APP_ENC_KEY_VAR="FIELD_ENCRYPTION_KEY" ;;
esac
APP_ENC_KEY_VALUE=""
if [[ -n "${APP_ENC_KEY_VAR}" ]]; then
    EXISTING_ENC_KEY=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.${APP_ENC_KEY_VAR}}" 2>/dev/null | base64 -d || echo "")
    OVERRIDE_ENC_KEY="${!APP_ENC_KEY_VAR:-}"   # allow explicit override via same-named env var
    if [[ -n "${OVERRIDE_ENC_KEY}" ]]; then
        APP_ENC_KEY_VALUE="${OVERRIDE_ENC_KEY}"
        log_info "Using provided ${APP_ENC_KEY_VAR} from environment"
    elif [[ -n "${EXISTING_ENC_KEY}" ]]; then
        log_info "Retrieved existing ${APP_ENC_KEY_VAR} from cluster (preserved)"
        APP_ENC_KEY_VALUE="${EXISTING_ENC_KEY}"
    else
        APP_ENC_KEY_VALUE=$(openssl rand -base64 32)
        log_info "Generated new ${APP_ENC_KEY_VAR} for ${SERVICE_NAME}"
    fi
fi

# TERMINAL_JWT_SECRET — library-api and pos-api desk/kiosk PIN (terminal) JWT HMAC secret. These
# tokens are signed AND verified by the service itself (not shared across services), so
# generate-or-preserve a per-service value. Read-existing-first so it never rotates (would
# invalidate live PIN sessions). pos-api used to sign them with the shared INTERNAL_SERVICE_KEY,
# which let any holder of that key mint terminal tokens for any tenant (fixed 2026-10-20).
APP_TERMINAL_JWT_SECRET=""
if [[ "${SERVICE_NAME}" == "library-api" || "${SERVICE_NAME}" == "pos-api" ]]; then
    EXISTING_TJS=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.TERMINAL_JWT_SECRET}" 2>/dev/null | base64 -d || echo "")
    if [[ -n "${TERMINAL_JWT_SECRET:-}" ]]; then
        APP_TERMINAL_JWT_SECRET="$TERMINAL_JWT_SECRET"
        log_info "Using provided TERMINAL_JWT_SECRET from environment"
    elif [[ -n "${EXISTING_TJS:-}" ]]; then
        log_info "Retrieved existing TERMINAL_JWT_SECRET from cluster (preserved)"
        APP_TERMINAL_JWT_SECRET="$EXISTING_TJS"
    else
        APP_TERMINAL_JWT_SECRET=$(openssl rand -base64 48)
        log_info "Generated new TERMINAL_JWT_SECRET for library-api"
    fi
fi

# SESSION_SECRET — codevertex-website HMAC key for the cv_session cookie, the Digitika parent
# portal session and the one-time code hashes. The site refuses to sign anything in production
# without it (parent portal "Could not send a code", website SSO session 500). Read-existing-first
# so it never rotates (that would sign every parent and admin out and burn pending codes).
APP_SESSION_SECRET=""
if [[ "${SERVICE_NAME}" == "codevertex-website" ]]; then
    EXISTING_SESSION_SECRET=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.SESSION_SECRET}" 2>/dev/null | base64 -d || echo "")
    if [[ -n "${SESSION_SECRET:-}" ]]; then
        APP_SESSION_SECRET="$SESSION_SECRET"
        log_info "Using provided SESSION_SECRET from environment"
    elif [[ -n "${EXISTING_SESSION_SECRET:-}" ]]; then
        APP_SESSION_SECRET="$EXISTING_SESSION_SECRET"
        log_info "Retrieved existing SESSION_SECRET from cluster (preserved)"
    else
        APP_SESSION_SECRET=$(openssl rand -base64 48)
        log_info "Generated new SESSION_SECRET for codevertex-website"
    fi
fi

# INTERNAL_SERVICE_KEY — the SHARED platform service-to-service key (all services use the SAME
# value; treasury/auth/subscriptions validate it). library-api needs it to call treasury for
# membership-fee / fine / e-book payment intents. mail-ui needs it to call auth-api's S2S MFA
# federation endpoints (POST /api/v1/s2s/mfa/status|verify) during webmail login. hadia-api calls
# treasury, notifications and subscriptions with it. email-provisioner checks it on every
# /internal/* call (auth-api, subscriptions-api and notifications-api send it). NEVER generate
# a fresh one here (a new value would not match the platform key) — preserve the existing cluster
# value, or accept it from env.
APP_INTERNAL_SERVICE_KEY=""
case "${SERVICE_NAME}" in
    library-api|mail-ui|maskani-api|maskani-ui|maskani-commerce|hadia-api|email-provisioner) NEEDS_ISK=true ;;
    *) NEEDS_ISK=false ;;
esac
if [[ "${NEEDS_ISK}" == "true" ]]; then
    EXISTING_ISK=$(kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" -o jsonpath="{.data.INTERNAL_SERVICE_KEY}" 2>/dev/null | base64 -d || echo "")
    if [[ -n "${INTERNAL_SERVICE_KEY:-}" ]]; then
        APP_INTERNAL_SERVICE_KEY="$INTERNAL_SERVICE_KEY"
        log_info "Using provided INTERNAL_SERVICE_KEY from environment"
    elif [[ -n "${EXISTING_ISK:-}" ]]; then
        APP_INTERNAL_SERVICE_KEY="$EXISTING_ISK"
        log_info "Retrieved existing INTERNAL_SERVICE_KEY from cluster (preserved)"
    else
        # First deploy: copy the platform value from auth-api, which validates it.
        AUTH_ISK=$(kubectl get secret auth-api-secrets -n auth -o jsonpath="{.data.INTERNAL_SERVICE_KEY}" 2>/dev/null | base64 -d || echo "")
        if [[ -n "${AUTH_ISK}" ]]; then
            APP_INTERNAL_SERVICE_KEY="$AUTH_ISK"
            log_info "Copied INTERNAL_SERVICE_KEY from auth-api-secrets"
        else
            log_warning "INTERNAL_SERVICE_KEY not set for ${SERVICE_NAME}: S2S calls will fail until provisioned (copy from auth-api-secrets)"
        fi
    fi
fi

# Redis password - Priority: POSTGRES_PASSWORD env > REDIS_PASSWORD env > redis secret
# CRITICAL: Redis now uses POSTGRES_PASSWORD (master password) for consistency
REDIS_PASSWORD=""
REDIS_HOST="redis-master.infra.svc.cluster.local"
REDIS_PORT="6379"
if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
    log_info "Using POSTGRES_PASSWORD for Redis (master password)"
    REDIS_PASSWORD="${POSTGRES_PASSWORD}"
elif [[ -n "${REDIS_PASSWORD:-}" ]]; then
    log_info "Using REDIS_PASSWORD from environment"
    REDIS_PASSWORD="${REDIS_PASSWORD}"
elif kubectl get secret redis -n infra >/dev/null 2>&1; then
    REDIS_PASSWORD=$(kubectl get secret redis -n infra \
        -o jsonpath="{.data.redis-password}" | base64 -d 2>/dev/null || echo "")
    if [[ -n "$REDIS_PASSWORD" ]]; then
        log_info "Retrieved Redis password from secret"
    fi
fi

# URL-encode a string for safe embedding in connection URIs (RFC 3986 userinfo).
# Characters like ! @ : / ? # [ ] and others must be percent-encoded.
url_encode_password() {
    python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null \
    || printf '%s' "$1" | sed 's/!/%21/g; s/@/%40/g; s/:/%3A/g; s|/|%2F|g; s/?/%3F/g; s/#/%23/g'
}

# Construct PostgreSQL URL (password is percent-encoded for safe URL parsing by Go/pgx)
if [[ -n "$DATABASE_PASSWORD" ]]; then
    ENCODED_DB_PASSWORD=$(url_encode_password "$DATABASE_PASSWORD")
    POSTGRES_URL="postgresql://${DB_USER}:${ENCODED_DB_PASSWORD}@${PG_HOST}:${PG_PORT}/${DB_NAME}?sslmode=disable"
else
    POSTGRES_URL="postgresql://${DB_USER}:CHANGE_ME@${PG_HOST}:${PG_PORT}/${DB_NAME}?sslmode=disable"
fi

# POSTGRES_MIGRATE_URL: always the direct Postgres host, bypassing PgBouncer,
# regardless of what PG_HOST/PG_PORT resolved to above. Migrations that hold a
# session-level pg_advisory_lock() across the tool's lifetime need a real,
# un-pooled connection — through PgBouncer's transaction-pooling mode, a
# client crash can orphan the lock on a pooled backend connection indefinitely
# (found 2026-09-02: hospital-api was never given this key, so its migrate
# path fell back to POSTGRES_URL/PgBouncer and got stuck this way in
# production). See shared-docs/docs/platform-standards/connection-pooling-pgbouncer.md.
POSTGRES_MIGRATE_HOST="postgresql.infra.svc.cluster.local"
POSTGRES_MIGRATE_PORT="5432"
if [[ -n "$DATABASE_PASSWORD" ]]; then
    POSTGRES_MIGRATE_URL="postgresql://${DB_USER}:${ENCODED_DB_PASSWORD}@${POSTGRES_MIGRATE_HOST}:${POSTGRES_MIGRATE_PORT}/${DB_NAME}?sslmode=disable"
else
    POSTGRES_MIGRATE_URL="postgresql://${DB_USER}:CHANGE_ME@${POSTGRES_MIGRATE_HOST}:${POSTGRES_MIGRATE_PORT}/${DB_NAME}?sslmode=disable"
fi

# Read-replica URL: when pgbouncer has a "<db>_ro" alias (manifests/databases/pgbouncer.yaml routes it
# to postgresql-replica), the service gets POSTGRES_READONLY_URL for its heavy read-only queries.
# treasury_ro existed since 2026-08-21 but treasury-api-secrets never got the key, so treasury read
# everything from the primary (added by hand 2026-11-14; this keeps it on every re-sync).
POSTGRES_READONLY_URL=""
if [[ -n "$DATABASE_PASSWORD" ]] && kubectl -n infra get configmap pgbouncer-config -o jsonpath='{.data.pgbouncer\.ini}' 2>/dev/null | grep -qE "^[[:space:]]*${DB_NAME}_ro[[:space:]]*="; then
    POSTGRES_READONLY_URL="postgresql://${DB_USER}:${ENCODED_DB_PASSWORD}@${PG_HOST}:${PG_PORT}/${DB_NAME}_ro?sslmode=disable"
fi

# Construct Redis URL (password is percent-encoded)
if [[ -n "$REDIS_PASSWORD" ]]; then
    ENCODED_REDIS_PASSWORD=$(url_encode_password "$REDIS_PASSWORD")
    REDIS_URL="redis://:${ENCODED_REDIS_PASSWORD}@${REDIS_HOST}:${REDIS_PORT}/0"
else
    REDIS_URL="redis://${REDIS_HOST}:${REDIS_PORT}/0"
fi

# Upsert standardized keys (POSTGRES_URL, REDIS_*, SECRET_KEY, DATABASE_*)
# IMPORTANT: Uses patch to MERGE keys into existing secret, never replacing it.
# This preserves service-specific keys (OAuth, seeding) added by provision.yml.
log_info "Upserting standardized keys into ${SECRET_NAME} in namespace ${NAMESPACE}..."

# Build array of standardized key literals
declare -a secret_literals=(
    "--from-literal=POSTGRES_URL=${POSTGRES_URL}"
    "--from-literal=POSTGRES_MIGRATE_URL=${POSTGRES_MIGRATE_URL}"
    "--from-literal=SECRET_KEY=${APP_SECRET_KEY}"
    "--from-literal=DATABASE_HOST=${PG_HOST}"
    "--from-literal=DATABASE_PORT=${PG_PORT}"
    "--from-literal=DATABASE_NAME=${DB_NAME}"
    "--from-literal=DATABASE_USER=${DB_USER}"
    "--from-literal=DATABASE_PASSWORD=${DATABASE_PASSWORD}"
    "--from-literal=REDIS_URL=${REDIS_URL}"
    "--from-literal=REDIS_HOST=${REDIS_HOST}"
    "--from-literal=REDIS_PORT=${REDIS_PORT}"
    "--from-literal=REDIS_PASSWORD=${REDIS_PASSWORD}"
)
if [[ -n "${POSTGRES_READONLY_URL}" ]]; then
    secret_literals+=("--from-literal=POSTGRES_READONLY_URL=${POSTGRES_READONLY_URL}")
fi
# isp-billing-backend: include the stable ENCRYPTION_SALT (see above).
if [[ -n "${APP_ENCRYPTION_SALT}" ]]; then
    secret_literals+=("--from-literal=ENCRYPTION_SALT=${APP_ENCRYPTION_SALT}")
fi
# Go services with UI-configurable credential encryption: include the stable key.
if [[ -n "${APP_ENC_KEY_VAR}" && -n "${APP_ENC_KEY_VALUE}" ]]; then
    secret_literals+=("--from-literal=${APP_ENC_KEY_VAR}=${APP_ENC_KEY_VALUE}")
fi
# library-api: include the stable terminal/PIN JWT secret.
if [[ -n "${APP_TERMINAL_JWT_SECRET}" ]]; then
    secret_literals+=("--from-literal=TERMINAL_JWT_SECRET=${APP_TERMINAL_JWT_SECRET}")
fi
# library-api: include the shared S2S key (for treasury payment intents).
if [[ -n "${APP_INTERNAL_SERVICE_KEY}" ]]; then
    secret_literals+=("--from-literal=INTERNAL_SERVICE_KEY=${APP_INTERNAL_SERVICE_KEY}")
fi
# codevertex-website: include the stable session signing key (see above).
if [[ -n "${APP_SESSION_SECRET}" ]]; then
    secret_literals+=("--from-literal=SESSION_SECRET=${APP_SESSION_SECRET}")
fi

# ---------------------------------------------------------------------------------------------
# Write step: seal and commit, never patch.
#
# Every service Secret comes from a SealedSecret in manifests/sealed-secrets/<ns>/<name>.sealedsecret.yaml.
# The controller rewrites each owned Secret from git whenever it restarts (every node reboot), so a
# key written only to the live Secret is lost: pos-api lost TERMINAL_JWT_SECRET that way on
# 2026-11-07. This script therefore never runs kubectl patch, create or apply on a Secret:
#   1. the desired keys above are compared with the live Secret by value, in memory;
#   2. nothing differs: exit 0 (the normal deploy path; no commit, no restart);
#   3. something differs or the Secret does not exist yet: the whole Secret (live keys plus the
#      new or changed ones) is sealed into this devops-k8s checkout, committed and pushed with the
#      release-bot rebase loop, and the script waits for the controller to sync it.
# No plaintext copy is written anywhere (the old backups/ credentials file is gone; git holds the
# encrypted copy). DRY_RUN=1 prints the changed key names and stops.
# ---------------------------------------------------------------------------------------------
source "${SCRIPT_DIR}/../sealing/seal-lib.sh"

desired_secret_json() {
    kubectl create secret generic "${SECRET_NAME}" --namespace="${NAMESPACE}" \
        "${secret_literals[@]}" --dry-run=client -o json
}

# stdin: desired Secret JSON. $1 is the mode:
#   new     names of desired keys the live Secret lacks (one per line)
#   differs names of keys the live Secret has with another value (one per line)
#   merge   the full Secret to seal: live keys, plus the missing desired keys, plus the differing
#           ones only when SEAL_OVERWRITE=1; labels kept plus app/managed-by
# Generate-or-preserve: a value already in the Secret is never replaced by default, so a deploy
# cannot silently repoint a service (for example another DATABASE_HOST). Values never leave the pipe.
secret_merge() {
    SEAL_OVERWRITE="${SEAL_OVERWRITE:-0}" seal_python -c '
import json, os, subprocess, sys
mode, ns, name, app = sys.argv[1:5]
desired = json.load(sys.stdin).get("data") or {}
p = subprocess.run(["kubectl", "get", "secret", name, "-n", ns, "-o", "json"], capture_output=True, text=True)
live = json.loads(p.stdout) if p.returncode == 0 and p.stdout.strip() else {}
live_data = live.get("data") or {}
if mode == "new":
    print("\n".join(k for k in sorted(desired) if k not in live_data)); sys.exit(0)
if mode == "differs":
    print("\n".join(k for k in sorted(desired) if k in live_data and live_data[k] != desired[k])); sys.exit(0)
overwrite = os.environ.get("SEAL_OVERWRITE") == "1"
data = dict(live_data)
for k, v in desired.items():
    if k not in data or overwrite:
        data[k] = v
labels = dict((live.get("metadata") or {}).get("labels") or {})
labels.update({"app": app, "managed-by": "script"})
json.dump({"apiVersion": "v1", "kind": "Secret", "type": live.get("type", "Opaque"),
           "metadata": {"name": name, "namespace": ns, "labels": labels}, "data": data}, sys.stdout)
' "$1" "${NAMESPACE}" "${SECRET_NAME}" "${SERVICE_NAME}"
}

NEW_KEYS=$(desired_secret_json | secret_merge new | tr -d '\r' | xargs)
DIFF_KEYS=$(desired_secret_json | secret_merge differs | tr -d '\r' | xargs)
if [[ -n "${DIFF_KEYS}" && "${SEAL_OVERWRITE:-0}" != "1" ]]; then
    log_warning "${NAMESPACE}/${SECRET_NAME} keeps its current ${DIFF_KEYS} (differ from what this script would set; rerun with SEAL_OVERWRITE=1 to replace them)"
    DIFF_KEYS=""
fi
CHANGED_KEYS=$(echo "${NEW_KEYS} ${DIFF_KEYS}" | xargs)
SEALED_OWNER=$(sealed_owner "${NAMESPACE}" "${SECRET_NAME}")
LIVE_EXISTS=false
kubectl get secret "${SECRET_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 && LIVE_EXISTS=true

if [[ -z "${CHANGED_KEYS}" && "${LIVE_EXISTS}" == "true" ]]; then
    if [[ -n "${SEALED_OWNER}" ]]; then
        log_success "${NAMESPACE}/${SECRET_NAME} (SealedSecret ${SEALED_OWNER}) already holds every standard key; nothing to write"
    else
        log_success "${NAMESPACE}/${SECRET_NAME} already holds every standard key; nothing to write (not sealed yet: scripts/sealing/seal-from-live.sh adopts it)"
    fi
    exit 0
fi

log_info "Keys to seal into ${NAMESPACE}/${SECRET_NAME}: ${CHANGED_KEYS:-<new Secret>}"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "DRY_RUN=1: nothing sealed or committed"
    exit 0
fi

ensure_kubeseal
SEALED_FILE="$(sealed_file_path "${NAMESPACE}" "${SECRET_NAME}")"
desired_secret_json | secret_merge merge | seal_secret_json "${SEALED_FILE}"
log_info "Sealed ${SECRET_NAME} ($(sealed_key_count "${SEALED_FILE}") keys) into ${SEALED_FILE#"${SEAL_REPO_ROOT}/"}"

# An existing Secret that no SealedSecret owns yet is adopted (data is replaced by the identical
# or updated sealed data; the annotation itself changes no value).
if [[ "${LIVE_EXISTS}" == "true" && -z "${SEALED_OWNER}" ]]; then
    mark_adoptable "${NAMESPACE}" "${SECRET_NAME}"
fi

if ! git_commit_push "${SEAL_REPO_ROOT}" "secrets(${SERVICE_NAME}): seal ${CHANGED_KEYS:-new Secret}" "${SEALED_FILE}"; then
    log_error "Could not push ${SEALED_FILE#"${SEAL_REPO_ROOT}/"}; nothing changed in the cluster"
    exit 1
fi
refresh_sealed_app || true
if wait_synced "${NAMESPACE}" "${SECRET_NAME}"; then
    log_success "Secret ${NAMESPACE}/${SECRET_NAME} synced from git"
else
    log_error "${NAMESPACE}/${SECRET_NAME} did not sync; check: kubectl get sealedsecret ${SECRET_NAME} -n ${NAMESPACE} -o yaml"
    exit 1
fi

log_section "Secret Summary"
echo "Namespace: ${NAMESPACE}"
echo "Secret Name: ${SECRET_NAME}"
echo "Database: ${DB_NAME}"
echo "Database User: ${DB_USER}"
echo "Sealed file: ${SEALED_FILE#"${SEAL_REPO_ROOT}/"} (values are never printed)"
