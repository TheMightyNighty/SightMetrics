# Paket A – Ingestion-Container: DuckDB-Auswertung als nächtlicher one-shot/CronJob.
# Liest die Webserver-Logs, schreibt den Cube in die (externe) MariaDB-Cube-DB und
# beendet sich wieder. Standard-Lauf = run_all.sh (alle Sites aus sites.conf).
FROM debian:bookworm-slim

# default-mysql-client liefert mysql + mysqldump (für backup_cube.sh / rotate_cube_secret.sh).
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash python3 ca-certificates time gettext-base default-mysql-client \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Daten/Engine
COPY bin/ ./bin/
COPY geo/ ./geo/

# SQL-Logik
COPY transform.sql cube_to_mysql.sql matomo_to_cube.sql sink_mysql.sql ./
COPY geo_sources/ ./geo_sources/
COPY log_formats/ ./log_formats/

# Betriebs-Skripte (Orchestrator + Einzelimport + Wartung/Alarm)
COPY run_all.sh load_cube.sh fetch_loki_logs.sh purge_cube.sh backup_cube.sh \
     notify.sh rotate_cube_secret.sh matomo_import.sh generate_logs.py \
     lib_geo.sh lib_logformat.sh lib_healthcheck.sh ./

# Vorlage (eigentliche sites.conf wird zur Laufzeit gemountet/übergeben)
COPY sites.conf.example ./

RUN chmod +x bin/duckdb *.sh

# State (Byte-Offsets je Site) MUSS persistent sein, sonst Voll-Reimport je Lauf.
# Als Volume deklariert -> zur Laufzeit ein persistentes Volume/PVC daraufmounten.
ENV STATE_DIR=/state
RUN mkdir -p /state
VOLUME ["/state"]

# Kein Secret im Image: CUBE_DSN/CUBE_DSN_FILE wird zur Laufzeit injiziert.
# Standard-Lauf importiert alle Sites; für Einzelimport:
#   docker run --rm … sightmetrics-ingestion load_cube.sh /logs/x.log "Site" 1
ENTRYPOINT ["bash"]
CMD ["run_all.sh"]
