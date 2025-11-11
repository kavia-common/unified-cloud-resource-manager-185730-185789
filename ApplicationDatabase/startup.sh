#!/bin/bash
set -euo pipefail

# Minimal PostgreSQL startup script with robust path handling and pg_ctl
# Configurable via environment variables but defaults provided below
DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PASSWORD="${DB_PASSWORD:-dbuser123}"
DB_PORT="${DB_PORT:-5001}"  # Required port per environment
DATA_DIR="${PGDATA:-/var/lib/postgresql/data}"
LOG_DIR="${PGLOGDIR:-/var/lib/postgresql}"
LOG_FILE="${LOG_DIR}/startup.log"

echo "Starting PostgreSQL setup on port ${DB_PORT}..."

# Discover installed PostgreSQL and set bin path
if [ -d /usr/lib/postgresql ]; then
  PG_VERSION=$(ls -1 /usr/lib/postgresql | sort -Vr | head -1)
  PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
else
  echo "ERROR: /usr/lib/postgresql not found. PostgreSQL packages are missing."
  echo "Please ensure postgresql is installed in the container image."
  exit 1
fi

if [ ! -x "${PG_BIN}/postgres" ]; then
  echo "ERROR: postgres binary not found at ${PG_BIN}/postgres"
  exit 1
fi

echo "Using PostgreSQL ${PG_VERSION} binaries at ${PG_BIN}"
mkdir -p "${DATA_DIR}" "${LOG_DIR}"
chown -R postgres:postgres "${DATA_DIR}" "${LOG_DIR}"
chmod 700 "${DATA_DIR}"

# Ensure postgresql.conf and pg_hba.conf will be created/updated
configure_postgres_conf() {
  # Set port and listen addresses
  if ! grep -qE "^[[:space:]]*port[[:space:]]*=" "${DATA_DIR}/postgresql.conf" 2>/dev/null; then
    echo "port = ${DB_PORT}" | sudo -u postgres tee -a "${DATA_DIR}/postgresql.conf" >/dev/null
  else
    sudo -u postgres sed -i "s/^[#]*[[:space:]]*port[[:space:]]*=.*/port = ${DB_PORT}/" "${DATA_DIR}/postgresql.conf" || true
  fi
  if ! grep -qE "^[[:space:]]*listen_addresses[[:space:]]*=" "${DATA_DIR}/postgresql.conf" 2>/dev/null; then
    echo "listen_addresses = '*'" | sudo -u postgres tee -a "${DATA_DIR}/postgresql.conf" >/dev/null
  else
    sudo -u postgres sed -i "s/^[#]*[[:space:]]*listen_addresses[[:space:]]*=.*/listen_addresses = '*'/ " "${DATA_DIR}/postgresql.conf" || true
  fi

  # pg_hba: allow md5 over tcp
  if ! grep -q "0.0.0.0/0" "${DATA_DIR}/pg_hba.conf" 2>/dev/null; then
    echo "host all all 0.0.0.0/0 md5" | sudo -u postgres tee -a "${DATA_DIR}/pg_hba.conf" >/dev/null
  fi
  if ! grep -q "::0/0" "${DATA_DIR}/pg_hba.conf" 2>/dev/null; then
    echo "host all all ::0/0 md5" | sudo -u postgres tee -a "${DATA_DIR}/pg_hba.conf" >/dev/null
  fi
  if ! grep -q "^local[[:space:]]\+all[[:space:]]\+all" "${DATA_DIR}/pg_hba.conf" 2>/dev/null; then
    echo "local all all peer" | sudo -u postgres tee -a "${DATA_DIR}/pg_hba.conf" >/dev/null
  fi
}

# If instance already ready on port, skip starting
if sudo -u postgres "${PG_BIN}/pg_isready" -h 0.0.0.0 -p "${DB_PORT}" > /dev/null 2>&1; then
  echo "PostgreSQL is already running on port ${DB_PORT}"
else
  # Initialize database if needed
  if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
    echo "Initializing database cluster at ${DATA_DIR}..."
    sudo -u postgres "${PG_BIN}/initdb" -D "${DATA_DIR}"
  fi

  configure_postgres_conf

  # Prefer pg_ctl to manage the server
  echo "Starting PostgreSQL with pg_ctl..."
  sudo -u postgres "${PG_BIN}/pg_ctl" -D "${DATA_DIR}" -l "${LOG_FILE}" -o "-p ${DB_PORT} -h 0.0.0.0" start

  # Wait until server is ready
  for i in {1..30}; do
    if sudo -u postgres "${PG_BIN}/pg_isready" -h 0.0.0.0 -p "${DB_PORT}" > /dev/null 2>&1; then
      echo "PostgreSQL is ready on port ${DB_PORT}"
      break
    fi
    echo "Waiting for PostgreSQL to become ready... (${i}/30)"
    sleep 1
  done

  if ! sudo -u postgres "${PG_BIN}/pg_isready" -h 0.0.0.0 -p "${DB_PORT}" > /dev/null 2>&1; then
    echo "ERROR: PostgreSQL failed to start. Tail of log:"
    tail -n 200 "${LOG_FILE}" || true
    exit 1
  fi
fi

# Create database and role
echo "Ensuring database '${DB_NAME}' and user '${DB_USER}' exist..."
if ! sudo -u postgres "${PG_BIN}/psql" -h 0.0.0.0 -p "${DB_PORT}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
  sudo -u postgres "${PG_BIN}/createdb" -h 0.0.0.0 -p "${DB_PORT}" "${DB_NAME}"
fi

sudo -u postgres "${PG_BIN}/psql" -h 0.0.0.0 -p "${DB_PORT}" -d postgres << EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

# Schema-level privileges
sudo -u postgres "${PG_BIN}/psql" -h 0.0.0.0 -p "${DB_PORT}" -d "${DB_NAME}" << EOF
GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Save connection strings/files
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo "To connect: $(cat db_connection.txt)"
