#!/usr/bin/env bash
# Wrapper entrypoint for preview/launch systems.
# Delegates to the robust ApplicationDatabase/startup.sh so we never invoke `postgres` directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_START_SCRIPT="${SCRIPT_DIR}/ApplicationDatabase/startup.sh"

if [[ ! -x "${DB_START_SCRIPT}" ]]; then
  echo "Making ApplicationDatabase/startup.sh executable..."
  chmod +x "${DB_START_SCRIPT}"
fi

echo "Launching ApplicationDatabase via ${DB_START_SCRIPT} ..."
exec "${DB_START_SCRIPT}"
