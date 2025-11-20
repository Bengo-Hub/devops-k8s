#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run only the Redis portion of the shared databases installer
ONLY_COMPONENT=redis "${SCRIPT_DIR}/install-databases.sh"


