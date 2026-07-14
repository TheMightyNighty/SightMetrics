#!/usr/bin/env python3
"""Erzeugt eine SYNTHETISCHE Geo-IP-CSV nur für den Demo-Stack.

Keine echten GeoIP-Daten (siehe docs/ingestion-runbook.md §3a für Produktivquellen) –
ordnet lediglich die 223 nutzbaren IPv4-Erst-Oktette reihum ein paar Ländercodes zu,
damit generate_logs.py-Beispieldaten (zufällige öffentliche IPs, siehe dort) im Demo-
Dashboard eine Länderverteilung zeigen. Selbst erstellt, keine Lizenzfragen.

Format: native (siehe ingestion/geo_sources/native.sql) – start,end,cc ohne Header.
"""
import argparse

DEMO_COUNTRIES = [
    "DE", "US", "FR", "GB", "NL", "ES", "IT", "PL",
    "AT", "CH", "SE", "NO", "DK", "BE", "IE", "PT",
    "CZ", "GR", "FI", "HU",
]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("-o", "--output", required=True)
    args = p.parse_args()

    rows = []
    for octet in range(1, 224):
        cc = DEMO_COUNTRIES[octet % len(DEMO_COUNTRIES)]
        start = octet * 16777216
        end = start + 16777215
        rows.append((start, end, cc))

    with open(args.output, "w") as f:
        for start, end, cc in rows:
            f.write(f"{start},{end},{cc}\n")
    print(f">> {len(rows)} synthetische Länder-Blöcke geschrieben nach {args.output}")


if __name__ == "__main__":
    main()
