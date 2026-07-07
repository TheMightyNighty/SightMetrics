# ---------------------------------------------------------------------------
# Prometheus textfile-collector output (node_exporter), sourced by
# load_cube.sh / fetch_loki_logs.sh / run_all.sh.
#
# Writes one .prom file per site (or per run for run_all.sh) into STATE_DIR --
# point node_exporter's --collector.textfile.directory at STATE_DIR (or copy
# the *.prom files there). Files are written atomically (tmp + mv) so the
# collector never sees a partial file.
#
# prom_site_metrics SITE_ID WALL_S CPU_S NEW_BYTES OFFSET SOURCE
# prom_run_metrics  TOTAL PASS FAIL
# ---------------------------------------------------------------------------

prom_site_metrics() {
  local site_id="$1" wall="$2" cpu="$3" new_bytes="$4" offset="$5" source="$6"
  local f="${STATE_DIR}/sightmetrics_site_${site_id}.prom"
  local now; now=$(date +%s)
  {
    echo '# HELP sightmetrics_import_last_success_timestamp_seconds Unix time of the last successful import for this site.'
    echo '# TYPE sightmetrics_import_last_success_timestamp_seconds gauge'
    echo "sightmetrics_import_last_success_timestamp_seconds{site_id=\"${site_id}\",source=\"${source}\"} ${now}"
    echo '# HELP sightmetrics_import_duration_seconds Wall-clock duration of the last import.'
    echo '# TYPE sightmetrics_import_duration_seconds gauge'
    echo "sightmetrics_import_duration_seconds{site_id=\"${site_id}\",source=\"${source}\"} ${wall}"
    echo '# HELP sightmetrics_import_cpu_seconds CPU time (user+sys) of the last import.'
    echo '# TYPE sightmetrics_import_cpu_seconds gauge'
    echo "sightmetrics_import_cpu_seconds{site_id=\"${site_id}\",source=\"${source}\"} ${cpu:-0}"
    echo '# HELP sightmetrics_import_new_bytes Bytes of new log data processed by the last import.'
    echo '# TYPE sightmetrics_import_new_bytes gauge'
    echo "sightmetrics_import_new_bytes{site_id=\"${site_id}\",source=\"${source}\"} ${new_bytes:-0}"
    echo '# HELP sightmetrics_import_offset_bytes Current byte offset in the log file (file source only).'
    echo '# TYPE sightmetrics_import_offset_bytes gauge'
    echo "sightmetrics_import_offset_bytes{site_id=\"${site_id}\",source=\"${source}\"} ${offset:-0}"
  } > "${f}.tmp" && mv "${f}.tmp" "$f"
}

prom_run_metrics() {
  local total="$1" pass="$2" fail="$3"
  local f="${STATE_DIR}/sightmetrics_run.prom"
  local now; now=$(date +%s)
  {
    echo '# HELP sightmetrics_run_last_timestamp_seconds Unix time of the last run_all.sh completion.'
    echo '# TYPE sightmetrics_run_last_timestamp_seconds gauge'
    echo "sightmetrics_run_last_timestamp_seconds ${now}"
    echo '# HELP sightmetrics_run_sites_total Sites configured in the last run.'
    echo '# TYPE sightmetrics_run_sites_total gauge'
    echo "sightmetrics_run_sites_total ${total}"
    echo '# HELP sightmetrics_run_sites_ok Sites imported successfully in the last run.'
    echo '# TYPE sightmetrics_run_sites_ok gauge'
    echo "sightmetrics_run_sites_ok ${pass}"
    echo '# HELP sightmetrics_run_sites_failed Sites failed in the last run.'
    echo '# TYPE sightmetrics_run_sites_failed gauge'
    echo "sightmetrics_run_sites_failed ${fail}"
  } > "${f}.tmp" && mv "${f}.tmp" "$f"
}
