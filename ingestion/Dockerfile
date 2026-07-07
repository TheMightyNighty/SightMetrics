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
COPY transform.sql cube_to_mysql.sql matomo_to_cube.sql sink_mysql.sql day_cut.sql ./
COPY geo_sources/ ./geo_sources/
COPY log_formats/ ./log_formats/

# Betriebs-Skripte (Orchestrator + Einzelimport + Wartung/Alarm)
COPY run_all.sh load_cube.sh fetch_loki_logs.sh purge_cube.sh backup_cube.sh \
     notify.sh rotate_cube_secret.sh matomo_import.sh generate_logs.py \
     lib_geo.sh lib_logformat.sh lib_healthcheck.sh lib_bots.sh ./
# Betreiber-Werkzeuge (z. B. fetch_bot_list.sh: device-detector-Bot-Liste bauen;
# die Liste selbst ist lizenzbedingt NICHT im Image -> zur Laufzeit mounten).
COPY tools/ ./tools/

# Vorlage (eigentliche sites.conf wird zur Laufzeit gemountet/übergeben)
COPY sites.conf.example ./

RUN chmod +x bin/duckdb *.sh

# ---- Non-root + readOnlyRootFilesystem-Tauglichkeit (Pod-Security "restricted") ----
# Fester UID/GID 10001 (kein Host-User-Mapping); Schreibpfade zur Laufzeit:
#   /state  -> PVC (Pflicht, Offsets)   /tmp -> emptyDir   alles andere read-only.
RUN useradd --system --uid 10001 --user-group --create-home \
      --home-dir /home/sightmetrics sightmetrics

# State (Byte-Offsets je Site) MUSS persistent sein, sonst Voll-Reimport je Lauf.
# Als Volume deklariert -> zur Laufzeit ein persistentes Volume/PVC daraufmounten.
# LOG_DIR liegt bewusst mit im State-Volume (einziger garantiert beschreibbarer Pfad).
ENV STATE_DIR=/state \
    LOG_DIR=/state/import-logs \
    HOME=/home/sightmetrics
RUN mkdir -p /state && chown 10001:10001 /state
VOLUME ["/state"]

# DuckDB-MySQL-Extension ins Image backen: zur Laufzeit ist 'INSTALL mysql' dann
# ein No-op (kein Netz-Download, kein Schreibzugriff -> readOnlyRootFilesystem ok).
# a+rX: auch fuer abweichende Laufzeit-UIDs lesbar (Demo-Bind-Mounts, OpenShift).
USER 10001:10001
RUN /app/bin/duckdb -c "INSTALL mysql;" \
 && chmod -R a+rX /home/sightmetrics/.duckdb

# Kein Secret im Image: CUBE_DSN/CUBE_DSN_FILE wird zur Laufzeit injiziert.
# Standard-Lauf importiert alle Sites; für Einzelimport:
#   docker run --rm … sightmetrics-ingestion load_cube.sh /logs/x.log "Site" 1
ENTRYPOINT ["bash"]
CMD ["run_all.sh"]
