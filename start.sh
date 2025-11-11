#!/usr/bin/env bash
# Commonly-detected start script name for preview systems.
# Forwards to the ApplicationDatabase startup script.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DB_START_SCRIPT="${ROOT_DIR}/ApplicationDatabase/startup.sh"

if [[ ! -x "${DB_START_SCRIPT}" ]]; then
  chmod +x "${DB_START_SCRIPT}"
fi

exec "${DB_START_SCRIPT}"
