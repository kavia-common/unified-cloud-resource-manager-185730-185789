#!/bin/bash
set -euo pipefail

# Minimal PostgreSQL startup script with robust path handling and pg_ctl
# Ensures DB initializes if needed, listens on 0.0.0.0:5001 and waits for readiness.
DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5001}"  # Required port per environment
DATA_DIR="${PGDATA:-/var/lib/postgresql/data}"
LOG_DIR="${PGLOGDIR:-/var/lib/postgresql}"
LOG_FILE="${LOG_DIR}/startup.log"

echo "Starting PostgreSQL setup on port ${DB_PORT}..."

# Find postgres binaries: prefer /usr/lib/postgresql/<ver>/bin, fallback to which
PG_BIN=""
if [ -d /usr/lib/postgresql ]; then
  PG_VERSION=$(ls -1 /usr/lib/postgresql | sort -Vr | head -1 || true)
  if [ -n "${PG_VERSION:-}" ] && [ -x "/usr/lib/postgresql/${PG_VERSION}/bin/postgres" ]; then
    PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
  fi
fi
if [ -z "${PG_BIN}" ]; then
  # Try which for postgres and derive bin dir
  if command -v postgres >/dev/null 2>&1; then
    POSTGRES_PATH="$(command -v postgres)"
    PG_BIN="$(dirname "${POSTGRES_PATH}")"
  fi
fi
if [ -z "${PG_BIN}" ] || [ ! -x "${PG_BIN}/postgres" ]; then
  echo "ERROR: PostgreSQL binaries not found. Ensure PostgreSQL is installed in the container image."
  exit 1
fi

echo "Using PostgreSQL binaries at ${PG_BIN}"
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown -R postgres:postgres "${DATA_DIR}" "${LOG_DIR}"
chmod 700 "${DATA_DIR}"

# Initialize database directory if needed with UTF8 locale
if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
  echo "Initializing database cluster at ${DATA_DIR}..."
  # initdb may fail if locale not present; default to C.UTF-8 if en_US.UTF-8 missing
  if locale -a 2>/dev/null | grep -qi '^en_US\.utf-8$'; then
    sudo -u postgres "${PG_BIN}/initdb" -D "${DATA_DIR}" --encoding=UTF8 --locale=en_US.UTF-8
  else
    sudo -u postgres "${PG_BIN}/initdb" -D "${DATA_DIR}" --encoding=UTF8 --locale=C.UTF-8
  fi
fi

# Ensure postgresql.conf and pg_hba.conf are configured properly
configure_postgres_conf() {
  # Set listen_addresses and port in postgresql.conf
  if ! grep -qE "^[[:space:]]*port[[:space:]]*=" "${DATA_DIR}/postgresql.conf" 2>/dev/null; then
    echo "port = ${DB_PORT}" | sudo -u postgres tee -a "${DATA_DIR}/postgresql.conf" >/dev/null
  else
    sudo -u postgres sed -i "s/^[#[:space:]]*port[[:space:]]*=.*/port = ${DB_PORT}/" "${DATA_DIR}/postgresql.conf" || true
  fi
  if ! grep -qE "^[[:space:]]*listen_addresses[[:space:]]*=" "${DATA_DIR}/postgresql.conf" 2>/dev/null; then
    echo "listen_addresses = '0.0.0.0'" | sudo -u postgres tee -a "${DATA_DIR}/postgresql.conf" >/dev/null
  else
    sudo -u postgres sed -i "s/^[#[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '0.0.0.0'/" "${DATA_DIR}/postgresql.conf" || true
  fi

  # Ensure pg_hba.conf allows local and external connections
  # Local connections
  if ! grep -qE "^local[[:space:]]+all[[:space:]]+all" "${DATA_DIR}/pg_hba.conf" 2>/dev/null; then
    echo "local   all             all                                     peer" | sudo -u postgres tee -a "${DATA_DIR}/pg_hba.conf" >/dev/null
  fi
  # IPv4 host connections with md5
  if ! grep -qE "^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+0\.0\.0\.0/0" "${DATA_DIR}/pg_hba.conf" 2>/dev/null; then
    echo "host    all             all             0.0.0.0/0               md5" | sudo -u postgres tee -a "${DATA_DIR}/pg_hba.conf" >/dev/null
  fi
  # IPv6 host connections with md5
  if ! grep -qE "^[[:space:]]*host[[:space:]]+all[[:space:]]+all[[:space:]]+::0/0" "${DATA_DIR}/pg_hba.conf" 2>/dev/null; then
    echo "host    all             all             ::0/0                   md5" | sudo -u postgres tee -a "${DATA_DIR}/pg_hba.conf" >/dev/null
  fi
}

configure_postgres_conf

# Start server with explicit -o flags to enforce port and host
echo "Starting PostgreSQL with pg_ctl..."
sudo -u postgres "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -l "${LOG_FILE}" -o "-p ${DB_PORT} -h 0.0.0.0" start || {
  echo "ERROR: pg_ctl failed to start PostgreSQL"
  tail -n 200 "${LOG_FILE}" || true
  exit 1
}

# Wait until server is ready using 127.0.0.1
READY=0
for i in {1..60}; do
  if sudo -u postgres "${PG_BIN}/pg_isready" -h 127.0.0.1 -p "${DB_PORT}" > /dev/null 2>&1; then
    READY=1
    echo "PostgreSQL is ready on 0.0.0.0:${DB_PORT}"
    break
  fi
  if (( i % 5 == 0 )); then
    echo "Waiting for PostgreSQL to become ready... (${i}/60)"
  fi
  sleep 1
done

if [ "${READY}" -ne 1 ]; then
  echo "ERROR: PostgreSQL failed to become ready on 127.0.0.1:${DB_PORT}. Recent logs:"
  tail -n 200 "${LOG_FILE}" || true
  # Attempt to show socket/lock info
  ls -la "${DATA_DIR}" || true
  exit 1
fi

# Create role and database if missing
echo "Ensuring database '${DB_NAME}' and user '${DB_USER}' exist..."
# Ensure role
sudo -u postgres "${PG_BIN}/psql" -h 127.0.0.1 -p "${DB_PORT}" -d postgres -v ON_ERROR_STOP=1 -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 || \
sudo -u postgres "${PG_BIN}/psql" -h 127.0.0.1 -p "${DB_PORT}" -d postgres -v ON_ERROR_STOP=1 -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';"
# Always ensure password matches desired
sudo -u postgres "${PG_BIN}/psql" -h 127.0.0.1 -p "${DB_PORT}" -d postgres -v ON_ERROR_STOP=1 -c "ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"

# Ensure database
if ! sudo -u postgres "${PG_BIN}/psql" -h 127.0.0.1 -p "${DB_PORT}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  sudo -u postgres "${PG_BIN}/createdb" -h 127.0.0.1 -p "${DB_PORT}" -O "${DB_USER}" "${DB_NAME}"
fi

# Schema-level privileges
sudo -u postgres "${PG_BIN}/psql" -h 127.0.0.1 -p "${DB_PORT}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 << EOF
GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Save connection strings/files with 127.0.0.1 host
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@127.0.0.1:${DB_PORT}/${DB_NAME}" > db_connection.txt
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://127.0.0.1:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

# Final readiness check and log pointer
if ! sudo -u postgres "${PG_BIN}/pg_isready" -h 127.0.0.1 -p "${DB_PORT}" >/dev/null 2>&1; then
  echo "ERROR: Final readiness check failed on 127.0.0.1:${DB_PORT}"
  tail -n 200 "${LOG_FILE}" || true
  exit 1
fi

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo "To connect: $(cat db_connection.txt)"
echo "Logs: ${LOG_FILE}"
