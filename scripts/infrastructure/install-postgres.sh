#!/usr/bin/env bash
set -euo pipefail

# Production-ready PostgreSQL Installation with pgvector Extension
# Installs PostgreSQL with pgvector extension enabled for vector similarity search
# This script calls install-databases.sh with PostgreSQL-only component

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run only the PostgreSQL portion of the shared databases installer
ONLY_COMPONENT=postgres "${SCRIPT_DIR}/install-databases.sh"

