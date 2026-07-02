#!/usr/bin/env bash
# Cube-DB anlegen + User mit konfigurierbaren Passwörtern erstellen.
# Ersetzt 01-analytics.sql; liest Passwörter aus Umgebungsvariablen.
#
# ACHTUNG NUR FUER DIESE LOKALE DEMO, NICHT PRODUKTIV UEBERNEHMEN:
# Die Grants unten nutzen 'user'@'%' (jeder Host darf sich verbinden), damit der lokale
# Docker-Compose-Stack ohne feste Container-IP funktioniert. Produktiv den Host auf das
# tatsaechliche Web-Subnetz/den Web-Host einschraenken (z. B. 'report_ro'@'10.0.1.0/255.255.255.0'
# oder eine feste IP) und zusaetzlich per Netzwerksegmentierung/Firewall absichern — siehe
# docs/extension-handbuch.md Abschnitt "Produktions-Haertung".
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
