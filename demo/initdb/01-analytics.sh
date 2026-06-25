#!/usr/bin/env bash
# Cube-DB anlegen + User mit konfigurierbaren Passwörtern erstellen.
# Ersetzt 01-analytics.sql; liest Passwörter aus Umgebungsvariablen.
# Für Produktion: CUBE_RW_PASSWORD und CUBE_RO_PASSWORD in demo/.env setzen.
set -euo pipefail

RW="${CUBE_RW_PASSWORD:-cube_rw}"
RO="${CUBE_RO_PASSWORD:-report_ro}"

mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS analytics CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'cube_rw'@'%'   IDENTIFIED BY '${RW}';
GRANT ALL PRIVILEGES ON analytics.* TO 'cube_rw'@'%';

CREATE USER IF NOT EXISTS 'report_ro'@'%' IDENTIFIED BY '${RO}';
GRANT SELECT ON analytics.* TO 'report_ro'@'%';

FLUSH PRIVILEGES;
SQL
