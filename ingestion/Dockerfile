# Paket A - Ingestion-Container: DuckDB-Auswertung als nächtlicher one-shot/CronJob.
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
COPY transform.sql cube_to_mysql.sql ./

# Betriebs-Skripte (Orchestrator + Einzelimport + Wartung/Alarm)
COPY run_all.sh load_cube.sh purge_cube.sh backup_cube.sh \
     notify.sh rotate_cube_secret.sh generate_logs.py ./

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
#   docker run --rm … weg3-ingestion load_cube.sh /logs/x.log "Site" 1
ENTRYPOINT ["bash"]
CMD ["run_all.sh"]
