# ApplicationDatabase

This container provides a PostgreSQL instance for the Cloud Manager application. It uses a robust startup script (startup.sh) that:
- Discovers PostgreSQL binaries (pg_ctl, initdb, pg_isready)
- Initializes the data directory if missing
- Configures listen_addresses = '0.0.0.0' and port = 5001
- Updates pg_hba.conf to allow connections with md5
- Creates the application role and database if absent
- Performs readiness checks using pg_isready against 127.0.0.1:5001

How to run (Docker):
1. Build
   docker build -t cloud-manager-db ./unified-cloud-resource-manager-185730-185789/ApplicationDatabase
2. Run
   docker run --name cloud-manager-db -p 5001:5001 -e DB_NAME=myapp -e DB_USER=appuser -e DB_PASSWORD=dbuser123 -e DB_PORT=5001 cloud-manager-db
3. Verify readiness
   docker exec -it cloud-manager-db bash -lc "sudo -u postgres $(ls -d /usr/lib/postgresql/*/bin | sort -Vr | head -1)/pg_isready -h 127.0.0.1 -p 5001"

Connection string:
psql postgresql://appuser:dbuser123@127.0.0.1:5001/myapp

Notes:
- The container does not invoke `postgres` directly; it uses pg_ctl/initdb/pg_isready internally via startup.sh.
- Logs are written to /var/lib/postgresql/startup.log inside the container.
