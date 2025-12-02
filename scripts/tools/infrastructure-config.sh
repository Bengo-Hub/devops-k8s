#!/usr/bin/env bash
# Centralized Infrastructure Configuration
# This file defines standard URLs and configuration for all shared infrastructure
# All scripts should source this file to ensure consistency

# =============================================================================
# INFRASTRUCTURE NAMESPACE
# =============================================================================
export INFRA_NAMESPACE="${INFRA_NAMESPACE:-infra}"

# =============================================================================
# POSTGRESQL CONFIGURATION (Shared Database Service)
# =============================================================================
export PG_NAMESPACE="${PG_NAMESPACE:-${INFRA_NAMESPACE}}"
export PG_SERVICE="${PG_SERVICE:-postgresql}"
export PG_HOST="${PG_HOST:-postgresql.${INFRA_NAMESPACE}.svc.cluster.local}"
export PG_PORT="${PG_PORT:-5432}"

# PostgreSQL Users
export PG_ADMIN_USER="${POSTGRES_ADMIN_USER:-admin_user}"
export PG_SUPERUSER="${POSTGRES_SUPERUSER:-postgres}"

# PostgreSQL Pod Labels (for custom manifests)
export PG_POD_LABEL_CUSTOM="app=postgresql"
export PG_POD_LABEL_HELM="app.kubernetes.io/name=postgresql"
export PG_CONTAINER_NAME="postgresql"

# =============================================================================
# REDIS CONFIGURATION (Shared Cache/Session Service)
# =============================================================================
export REDIS_NAMESPACE="${REDIS_NAMESPACE:-${INFRA_NAMESPACE}}"
export REDIS_SERVICE="${REDIS_SERVICE:-redis-master}"
export REDIS_HOST="${REDIS_HOST:-redis-master.${INFRA_NAMESPACE}.svc.cluster.local}"
export REDIS_PORT="${REDIS_PORT:-6379}"

# Redis Pod Labels
export REDIS_POD_LABEL_CUSTOM="app=redis"
export REDIS_POD_LABEL_HELM="app.kubernetes.io/name=redis"
export REDIS_CONTAINER_NAME="redis"

# Redis Database Numbers (for service isolation)
export REDIS_DB_CACHE="${REDIS_DB_CACHE:-0}"
export REDIS_DB_CELERY="${REDIS_DB_CELERY:-1}"
export REDIS_DB_SESSION="${REDIS_DB_SESSION:-2}"

# =============================================================================
# RABBITMQ CONFIGURATION (Shared Message Broker)
# =============================================================================
export RABBITMQ_NAMESPACE="${RABBITMQ_NAMESPACE:-${INFRA_NAMESPACE}}"
export RABBITMQ_SERVICE="${RABBITMQ_SERVICE:-rabbitmq}"
export RABBITMQ_HOST="${RABBITMQ_HOST:-rabbitmq.${INFRA_NAMESPACE}.svc.cluster.local}"
export RABBITMQ_PORT_AMQP="${RABBITMQ_PORT_AMQP:-5672}"
export RABBITMQ_PORT_MANAGEMENT="${RABBITMQ_PORT_MANAGEMENT:-15672}"
export RABBITMQ_PORT_METRICS="${RABBITMQ_PORT_METRICS:-15692}"

# RabbitMQ Pod Labels
export RABBITMQ_POD_LABEL_CUSTOM="app=rabbitmq"
export RABBITMQ_POD_LABEL_HELM="app.kubernetes.io/name=rabbitmq"
export RABBITMQ_CONTAINER_NAME="rabbitmq"

# RabbitMQ Default Credentials
export RABBITMQ_DEFAULT_USER="${RABBITMQ_USER:-user}"
export RABBITMQ_DEFAULT_VHOST="${RABBITMQ_VHOST:-/}"

# =============================================================================
# CONNECTION STRING TEMPLATES
# =============================================================================

# Function to generate PostgreSQL connection string
generate_postgres_url() {
    local db_user="$1"
    local db_password="$2"
    local db_name="$3"
    local ssl_mode="${4:-disable}"
    echo "postgresql://${db_user}:${db_password}@${PG_HOST}:${PG_PORT}/${db_name}?sslmode=${ssl_mode}"
}

# Function to generate Redis connection string
generate_redis_url() {
    local redis_password="$1"
    local redis_db="${2:-0}"
    if [[ -n "$redis_password" ]]; then
        echo "redis://:${redis_password}@${REDIS_HOST}:${REDIS_PORT}/${redis_db}"
    else
        echo "redis://${REDIS_HOST}:${REDIS_PORT}/${redis_db}"
    fi
}

# Function to generate RabbitMQ connection string
generate_rabbitmq_url() {
    local rabbitmq_user="$1"
    local rabbitmq_password="$2"
    local vhost="${3:-/}"
    echo "amqp://${rabbitmq_user}:${rabbitmq_password}@${RABBITMQ_HOST}:${RABBITMQ_PORT_AMQP}${vhost}"
}

# =============================================================================
# POD LOOKUP FUNCTIONS
# =============================================================================

# Get PostgreSQL pod name (tries custom manifest label first, then Helm)
get_postgresql_pod() {
    local namespace="${1:-${PG_NAMESPACE}}"
    local pod_name=""
    
    # Try custom manifest label first
    pod_name=$(kubectl get pod -n "$namespace" -l "$PG_POD_LABEL_CUSTOM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    # Fallback to Helm label
    if [[ -z "$pod_name" ]]; then
        pod_name=$(kubectl get pod -n "$namespace" -l "$PG_POD_LABEL_HELM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    echo "$pod_name"
}

# Get Redis pod name
get_redis_pod() {
    local namespace="${1:-${REDIS_NAMESPACE}}"
    local pod_name=""
    
    # Try custom manifest label first
    pod_name=$(kubectl get pod -n "$namespace" -l "$REDIS_POD_LABEL_CUSTOM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    # Fallback to Helm label
    if [[ -z "$pod_name" ]]; then
        pod_name=$(kubectl get pod -n "$namespace" -l "$REDIS_POD_LABEL_HELM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    echo "$pod_name"
}

# Get RabbitMQ pod name
get_rabbitmq_pod() {
    local namespace="${1:-${RABBITMQ_NAMESPACE}}"
    local pod_name=""
    
    # Try custom manifest label first
    pod_name=$(kubectl get pod -n "$namespace" -l "$RABBITMQ_POD_LABEL_CUSTOM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    # Fallback to Helm label
    if [[ -z "$pod_name" ]]; then
        pod_name=$(kubectl get pod -n "$namespace" -l "$RABBITMQ_POD_LABEL_HELM" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    fi
    
    echo "$pod_name"
}

# =============================================================================
# MASTER PASSWORD SYSTEM
# =============================================================================

# All infrastructure uses POSTGRES_PASSWORD as the master password
# Priority: POSTGRES_PASSWORD (GitHub secret) > service-specific password > generate

export MASTER_PASSWORD_SOURCE="POSTGRES_PASSWORD"

# Function to get master password
get_master_password() {
    local password=""
    
    # Try POSTGRES_PASSWORD first (master password)
    if [[ -n "${POSTGRES_PASSWORD:-}" ]]; then
        password="$POSTGRES_PASSWORD"
    # Try from PostgreSQL secret
    elif kubectl get secret postgresql -n "${INFRA_NAMESPACE}" >/dev/null 2>&1; then
        password=$(kubectl get secret postgresql -n "${INFRA_NAMESPACE}" -o jsonpath="{.data.postgres-password}" 2>/dev/null | base64 -d || echo "")
    fi
    
    echo "$password"
}

# =============================================================================
# STANDARD INFRASTRUCTURE URLS
# =============================================================================

# These are the canonical URLs that all services should use
export STANDARD_POSTGRES_HOST="postgresql.infra.svc.cluster.local"
export STANDARD_POSTGRES_PORT="5432"
export STANDARD_REDIS_HOST="redis-master.infra.svc.cluster.local"
export STANDARD_REDIS_PORT="6379"
export STANDARD_RABBITMQ_HOST="rabbitmq.infra.svc.cluster.local"
export STANDARD_RABBITMQ_PORT="5672"
export STANDARD_RABBITMQ_MGMT_PORT="15672"

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Check if PostgreSQL is ready
is_postgresql_ready() {
    local namespace="${1:-${PG_NAMESPACE}}"
    local pod_name=$(get_postgresql_pod "$namespace")
    
    if [[ -n "$pod_name" ]]; then
        kubectl get pod -n "$namespace" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"
        return $?
    fi
    return 1
}

# Check if Redis is ready
is_redis_ready() {
    local namespace="${1:-${REDIS_NAMESPACE}}"
    local pod_name=$(get_redis_pod "$namespace")
    
    if [[ -n "$pod_name" ]]; then
        kubectl get pod -n "$namespace" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"
        return $?
    fi
    return 1
}

# Check if RabbitMQ is ready
is_rabbitmq_ready() {
    local namespace="${1:-${RABBITMQ_NAMESPACE}}"
    local pod_name=$(get_rabbitmq_pod "$namespace")
    
    if [[ -n "$pod_name" ]]; then
        kubectl get pod -n "$namespace" "$pod_name" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Running"
        return $?
    fi
    return 1
}

