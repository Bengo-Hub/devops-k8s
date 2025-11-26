#!/usr/bin/env bash
set -euo pipefail

# Production-ready Redis Installation
# Installs Redis with production configurations
# This script calls install-databases.sh with Redis-only component

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run only the Redis portion of the shared databases installer
ONLY_COMPONENT=redis "${SCRIPT_DIR}/install-databases.sh"

