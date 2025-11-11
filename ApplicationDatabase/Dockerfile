# Minimal Dockerfile to run PostgreSQL via robust startup.sh without calling postgres directly
# Uses Ubuntu base and installs PostgreSQL server, relies on startup.sh to manage init and readiness.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV DB_NAME=myapp
ENV DB_USER=appuser
ENV DB_PASSWORD=dbuser123
ENV DB_PORT=5001
ENV PGDATA=/var/lib/postgresql/data
ENV PGLOGDIR=/var/lib/postgresql

# Create postgres user and install required packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      locales \
      sudo \
      ca-certificates \
      curl \
      gnupg \
      lsb-release && \
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen && \
    # Install PostgreSQL from Ubuntu repo
    apt-get install -y --no-install-recommends postgresql postgresql-contrib && \
    # ensure postgres user exists and has home
    usermod -d /var/lib/postgresql postgres && \
    mkdir -p /var/lib/postgresql && chown -R postgres:postgres /var/lib/postgresql && \
    # clean up
    rm -rf /var/lib/apt/lists/*

# Create working directory and copy app files
WORKDIR /app/ApplicationDatabase

# Copy only ApplicationDatabase folder content
COPY . /app

# Ensure data directories exist with proper owner
RUN mkdir -p ${PGDATA} ${PGLOGDIR} && \
    chown -R postgres:postgres ${PGDATA} ${PGLOGDIR} && \
    chmod 700 ${PGDATA} || true

# Ensure startup.sh is executable
RUN chmod +x /app/ApplicationDatabase/startup.sh

EXPOSE 5001

# The entrypoint uses pg_ctl/initdb/pg_isready as implemented in startup.sh
ENTRYPOINT ["/app/ApplicationDatabase/startup.sh"]
