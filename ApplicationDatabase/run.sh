#!/usr/bin/env bash
# Wrapper entrypoint within ApplicationDatabase directory for preview systems
# that resolve commands relative to this service folder.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
START_SCRIPT="${SCRIPT_DIR}/startup.sh"

if [[ ! -x "${START_SCRIPT}" ]]; then
  echo "Making startup.sh executable..."
  chmod +x "${START_SCRIPT}"
fi

echo "Starting PostgreSQL via startup.sh..."
exec "${START_SCRIPT}"
