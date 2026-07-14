# --- Build-Stage: passendes DuckDB-CLI-Binary von GitHub Releases laden --------
# dpkg --print-architecture liefert amd64/arm64 == DuckDB-Asset-Namen und folgt
# beim Multi-Plattform-Build automatisch der Ziel-Architektur.
FROM debian:bookworm-slim AS duckdb
ARG DUCKDB_VERSION=1.5.4
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl unzip ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    curl -fsSL -o /tmp/duckdb.zip \
      "https://github.com/duckdb/duckdb/releases/download/v${DUCKDB_VERSION}/duckdb_cli-linux-${arch}.zip"; \
    mkdir -p /out; \
    unzip -o -q /tmp/duckdb.zip -d /out; \
    chmod +x /out/duckdb; \
    rm /tmp/duckdb.zip

# --- Runtime-Stage ------------------------------------------------------------
# Package A – ingestion container: DuckDB analysis as a nightly one-shot/CronJob.
# Reads the webserver logs, writes the cube to the (external) MariaDB cube DB and
# then exits. Default run = run_all.sh (all sites from sites.conf).
FROM debian:bookworm-slim

# default-mysql-client provides mysql + mysqldump (for backup_cube.sh / rotate_cube_secret.sh).
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash python3 ca-certificates time gettext-base default-mysql-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Data/engine
COPY --from=duckdb /out/duckdb /usr/local/bin/duckdb
COPY geo/ ./geo/

# SQL logic
COPY transform.sql cube_to_mysql.sql matomo_to_cube.sql sink_mysql.sql day_cut.sql ua_lookup.sql ./
COPY geo_sources/ ./geo_sources/
COPY log_formats/ ./log_formats/

# Operational scripts (orchestrator + single import + maintenance/alerting)
COPY run_all.sh load_cube.sh fetch_loki_logs.sh purge_cube.sh backup_cube.sh \
     notify.sh rotate_cube_secret.sh matomo_import.sh generate_logs.py \
     lib_geo.sh lib_logformat.sh lib_healthcheck.sh lib_bots.sh lib_prom.sh lib_ua.sh ./
# Operator tools (e.g. fetch_bot_list.sh: build the device-detector bot list;
# the list itself is NOT in the image for license reasons -> mount at runtime).
COPY tools/ ./tools/

# Template (the actual sites.conf is mounted/provided at runtime)
COPY sites.conf.example ./

RUN chmod +x *.sh

# ---- Non-root + readOnlyRootFilesystem compatibility (Pod Security "restricted") ----
# Fixed UID/GID 10001 (no host user mapping); writable paths at runtime:
#   /state  -> PVC (required, offsets)   /tmp -> emptyDir   everything else read-only.
RUN useradd --system --uid 10001 --user-group --create-home \
      --home-dir /home/sightmetrics sightmetrics

# State (byte offsets per site) MUST be persistent, otherwise a full reimport every run.
# Declared as a volume -> mount a persistent volume/PVC onto it at runtime.
# LOG_DIR deliberately lives inside the state volume (the only guaranteed writable path).
ENV STATE_DIR=/state \
    LOG_DIR=/state/import-logs \
    HOME=/home/sightmetrics
RUN mkdir -p /state && chown 10001:10001 /state
VOLUME ["/state"]

# Bake the DuckDB MySQL extension into the image: at runtime 'INSTALL mysql' is
# then a no-op (no network download, no write access -> readOnlyRootFilesystem ok).
# a+rX: also readable for differing runtime UIDs (demo bind mounts, OpenShift).
USER 10001:10001
RUN duckdb -c "INSTALL mysql; INSTALL inet;" \
 && chmod -R a+rX /home/sightmetrics/.duckdb

# No secret in the image: CUBE_DSN/CUBE_DSN_FILE is injected at runtime.
# Default run imports all sites; for a single import:
#   docker run --rm … sightmetrics-ingestion load_cube.sh /logs/x.log "Site" 1
ENTRYPOINT ["bash"]
CMD ["run_all.sh"]
