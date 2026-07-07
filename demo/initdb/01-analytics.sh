#!/usr/bin/env bash
# Create the cube DB + create users with configurable passwords.
# Replaces 01-analytics.sql; reads passwords from environment variables.
#
# WARNING: FOR THIS LOCAL DEMO ONLY, DO NOT USE IN PRODUCTION:
# The grants below use 'user'@'%' (any host may connect), so the local
# Docker Compose stack works without a fixed container IP. In production, restrict
# the host to the actual web subnet/web host (e.g. 'report_ro'@'10.0.1.0/255.255.255.0'
# or a fixed IP) and additionally secure it via network segmentation/firewall — see
# docs/extension-handbuch.md section "Production hardening".
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
