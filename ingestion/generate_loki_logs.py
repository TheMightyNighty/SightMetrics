#!/usr/bin/env python3
"""Erzeugt realistische Dummy-Logs im nginx-ECS-JSON-Format und schiebt sie
direkt in Grafana Loki.

Verbindliche Formatvorlage ist die nginx-log_format `elastic_common_schema`
(escape=json) in demo/nginx-log-format.conf – ecs_record() bildet exakt dieses
Schema ab (kein alternatives Layout). Passend dazu liest der Ingestion-Pfad
(fetch_loki_logs.sh -> log_formats/json_ecs.sql) genau dieselben JSON-Pfade.

Damit laesst sich der alternative Ingestion-Weg testen:

    generate_loki_logs.py  ->  Loki  ->  fetch_loki_logs.sh (SM_LOG_FORMAT=json_ecs)  ->  Cube

Fachlich identische Besucher-/Session-Logik wie generate_logs.py (dieselben
Seitenbaeume, User-Agents, Referrer, Tagesgang) – nur die Ausgabe ist eine
verschachtelte JSON-Zeile je Request statt Apache-Combined, und das Ziel ist
die Loki-Push-API statt einer Datei.

Die Zeitstempel liegen bewusst in der juengsten Vergangenheit (Fenster
`--hours`, Standard 6 h), damit Loki sie annimmt (Standard-Reject fuer >7 Tage)
und der erste `fetch_loki_logs.sh`-Lauf sie im 24-h-Lookback findet.

Beispiele:
    # In den demo-Stack pushen (Loki auf localhost:3100):
    python3 generate_loki_logs.py -n 2000

    # Aus dem ingestion-Container (Loki per Compose-DNS):
    python3 generate_loki_logs.py --loki-url http://loki:3100 -n 2000

    # Nur ansehen, nicht pushen:
    python3 generate_loki_logs.py -n 5 --stdout
"""
import argparse
import datetime as dt
import json
import os
import random
import sys
import time
import urllib.error
import urllib.request

# Bausteine (Seitenbaum, User-Agents, Referrer, Besucher, Tagesgang) aus dem
# bestehenden Datei-Generator wiederverwenden – gleiche Testdaten-Fachlichkeit.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import generate_logs as gl  # noqa: E402


# --- ECS-Feld-Helfer ---------------------------------------------------------
def _res_content_type(path, status):
    p = path.split("?", 1)[0]
    if status in (301, 302):
        return "text/html"
    for ext, ct in ((".pdf", "application/pdf"), (".css", "text/css"),
                    (".js", "application/javascript"), (".svg", "image/svg+xml"),
                    (".woff2", "font/woff2"), (".jpg", "image/jpeg"),
                    (".jpeg", "image/jpeg"), (".ico", "image/x-icon")):
        if p.endswith(ext):
            return ct
    return "text/html; charset=utf-8"


def _upstream(rng, status, sent):
    # xlog_origin=proxycache -> Cache-Treffer kontaktieren keinen Upstream.
    cache = rng.choices(["HIT", "MISS", "EXPIRED", ""], weights=[55, 30, 8, 7])[0]
    if cache == "HIT":
        return {"cache_status": "HIT", "status": "", "addr": "",
                "response_time": "", "response_length": ""}
    return {"cache_status": cache, "status": str(status), "addr": "127.0.0.1:8080",
            "response_time": f"{rng.uniform(0.003, 0.35):.3f}",
            "response_length": str(sent)}


def _hexid(rng, n=32):
    return "".join(rng.choice("0123456789abcdef") for _ in range(n))


def ecs_record(rng, ts, r):
    """Baut das verschachtelte JSON-Objekt EXAKT nach der nginx-log_format
    `elastic_common_schema`. Leere Variablen -> "" (wie nginx escape=json)."""
    is_post = r["method"] == "POST"
    body_bytes = r["body"]
    sent_bytes = body_bytes + rng.randint(150, 400)          # + Header ~ $bytes_sent
    direct = r["referer"] in ("", "-")
    return {
        "@timestamp": ts.strftime("%Y-%m-%dT%H:%M:%S+00:00"),   # $time_iso8601
        "client": {"ip": r["ip"], "port": str(r["port"])},
        "user": {"name": ""},
        "server": {"ip": r["server_ip"], "port": "443"},
        "http": {
            "version": "HTTP/2.0",
            "request": {
                "duration": f"{rng.uniform(0.002, 0.4):.3f}",
                "bytes": str(rng.randint(300, 1200)),
                "method": r["method"],
                "body": {"bytes": str(rng.randint(20, 4000)) if is_post else ""},
            },
            "response": {
                "status_code": str(r["status"]),
                "bytes": str(sent_bytes),
                "body": {"bytes": str(body_bytes)},
            },
            "tls": {
                "protocol": "TLSv1.3",
                "cipher": "TLS_AES_256_GCM_SHA384",
                "fingerprint": "",
            },
        },
        "user_agent": {"original": r["ua"]},
        "HTTP": {
            "url_path": r["path"],                              # $request_uri (inkl. Query)
            "req": {
                "host": r["host"],
                "cookie": "",
                "referer": r["referer"],                        # "-" = Direkteinstieg
                "content_type": "application/x-www-form-urlencoded" if is_post else "",
                "origin": "",
                "x_forwarded_for": "",
                "upgrade": "",
                "sec_websocket_extensions": "",
                "sec_fetch_dest": "document",
                "sec_fetch_mode": "navigate",
                "sec_fetch_site": "none" if direct else "cross-site",
                "sec_fetch_user": "?1",
            },
            "res": {
                "set_cookie": "",
                "content_type": _res_content_type(r["path"], r["status"]),
                "upgrade": "",
                "sec_websocket_extensions": "",
            },
        },
        "NGINX": {"upstream": _upstream(rng, r["status"], sent_bytes)},
        "trace": {"id": _hexid(rng)},
        "file": {"path": "/var/www/html" + r["path"].split("?", 1)[0]},
        "xlog_origin": "proxycache",
        "xlog_properties": ["web_server", "nginx", "containerized", "internet_service"],
    }


# --- Session-Aufbau (Felder statt fertiger Zeile; Logik wie gl.build_session) -
def build_session_records(rng, visitor, t0, clean, host, server_ip):
    recs = []
    x = rng.random()
    n = 1 if x < 0.42 else 2 if x < 0.66 else 3 if x < 0.82 \
        else rng.randint(4, 7) if x < 0.95 else rng.randint(8, 16)

    ip, ua = visitor["ip"], visitor["ua"]
    port = rng.randint(1024, 65535)
    ts = t0
    referrer = gl.weighted(rng, gl.REFERRERS_EXT)          # nur Einstieg -> Ext-Referrer
    paths = [rng.choice(gl.ENTRY_PATHS)] \
        + [gl.weighted(rng, gl.CONTENT_PATHS) for _ in range(n - 1)]

    for i, path in enumerate(paths):
        if i > 0 and rng.random() < 0.06:
            path = gl.weighted(rng, gl.DOWNLOAD_PATHS)
        method = "POST" if path in ("/buergerservice/termin-vereinbaren", "/suche") \
            and rng.random() < 0.5 else "GET"
        status = 200
        if not clean:
            rr = rng.random()
            status = 404 if rr < 0.02 else 301 if rr < 0.05 else 500 if rr < 0.055 else 200
        body = rng.randint(800, 60000) if status == 200 else rng.randint(0, 700)
        if path == "/suche":                               # interne Suche mit Query
            path += "?q=" + rng.choice(["personalausweis", "wohngeld", "termin",
                                        "reisepass", "abfallkalender"])
        recs.append((ts, dict(ip=ip, port=port, method=method, path=path,
                              status=status, body=body,
                              referer=(referrer if i == 0 else "-"),
                              ua=ua, host=host, server_ip=server_ip)))
        ts += dt.timedelta(seconds=rng.randint(4, 240))
    return recs


# --- Loki-Push ---------------------------------------------------------------
def push_to_loki(loki_url, labels, entries, batch=1000):
    """entries: aufsteigend sortierte Liste (ns_str, line). Pusht in Batches.
    Bei HTTP 429 (Loki-Ingest-Ratelimit) wird mit Backoff wiederholt, damit der
    Push auch gegen eine Loki-Instanz mit Standard-Limit (4 MB/s) durchlaeuft."""
    url = loki_url.rstrip("/") + "/loki/api/v1/push"
    sent = 0
    for i in range(0, len(entries), batch):
        chunk = entries[i:i + batch]
        payload = json.dumps({"streams": [{"stream": labels,
                                           "values": [[ns, line] for ns, line in chunk]}]}
                             ).encode("utf-8")
        for attempt in range(8):
            req = urllib.request.Request(url, data=payload, method="POST",
                                         headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req) as resp:
                    if resp.status not in (200, 204):
                        print(f"Loki-Push HTTP {resp.status}: {resp.read().decode()}",
                              file=sys.stderr)
                        sys.exit(1)
                break
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < 7:
                    # Retry-After respektieren, sonst exponentieller Backoff (max 10 s).
                    wait = float(e.headers.get("Retry-After") or 0) or min(0.5 * 2 ** attempt, 10)
                    print(f"   Loki-Ratelimit (429), warte {wait:.1f}s und wiederhole ...",
                          file=sys.stderr)
                    time.sleep(wait)
                    continue
                print(f"Loki-Push fehlgeschlagen (HTTP {e.code}): {e.read().decode()}",
                      file=sys.stderr)
                sys.exit(1)
            except urllib.error.URLError as e:
                print(f"Loki nicht erreichbar ({url}): {e.reason}", file=sys.stderr)
                sys.exit(1)
        sent += len(chunk)
    return sent


def _parse_labels(pairs):
    out = {}
    for p in pairs or []:
        if "=" not in p:
            sys.exit(f"--label erwartet key=value, nicht: {p}")
        k, v = p.split("=", 1)
        out[k] = v
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-n", "--num", type=int, default=1000, help="Anzahl Log-Zeilen (Default: 1000)")
    p.add_argument("--hours", type=float, default=6.0,
                   help="Zeitfenster rueckwirkend ab jetzt (Default: 6 h)")
    p.add_argument("--loki-url", default=os.environ.get("LOKI_URL", "http://localhost:3100"),
                   help="Loki-Basis-URL (Default: $LOKI_URL oder http://localhost:3100)")
    p.add_argument("--job", default="nginx", help='Loki-Label "job" (Default: nginx)')
    p.add_argument("--label", action="append", metavar="k=v",
                   help="zusaetzliches Loki-Stream-Label (mehrfach moeglich)")
    p.add_argument("--host", default="amt.example.gov", help="http_host im Log (Default: amt.example.gov)")
    p.add_argument("--server-ip", default="10.0.0.10", help="server_addr im Log")
    p.add_argument("--noisy", action="store_true",
                   help="Rauschen (404/301/500) statt nur sauberer 2xx-Content")
    p.add_argument("--regulars", type=int, default=0, help="Pool wiederkehrender Besucher (0 = auto)")
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--stdout", action="store_true",
                   help="JSON-Zeilen nach stdout schreiben statt nach Loki pushen")
    args = p.parse_args()

    rng = random.Random(args.seed)
    clean = not args.noisy

    now = dt.datetime.now(dt.timezone.utc)
    latest = now - dt.timedelta(seconds=60)                 # nicht in die Zukunft/creation grace
    earliest = now - dt.timedelta(hours=args.hours)
    window_s = max((latest - earliest).total_seconds(), 1.0)

    n_reg = args.regulars or max(args.num // 12, 5)
    regulars = [gl.make_visitor(rng) for _ in range(n_reg)]

    # Sessions erzeugen, bis genug Records zusammenkommen
    records = []
    while len(records) < args.num:
        if rng.random() < 0.40:                            # 40 % wiederkehrend (power-law)
            visitor = regulars[min(int(n_reg * (rng.random() ** 2.2)), n_reg - 1)]
        else:
            visitor = gl.make_visitor(rng)
        t0 = earliest + dt.timedelta(seconds=rng.uniform(0, window_s))
        for ts, r in build_session_records(rng, visitor, t0, clean, args.host, args.server_ip):
            records.append((min(ts, latest), r))           # nie in die Zukunft
    records = records[:args.num]
    records.sort(key=lambda x: x[0])

    # ECS-JSON bauen + ns-Zeitstempel
    entries = [(str(int(ts.timestamp() * 1_000_000_000)),
                json.dumps(ecs_record(rng, ts, r), ensure_ascii=False, separators=(",", ":")))
               for ts, r in records]

    if args.stdout:
        for _, line in entries:
            print(line)
        return

    labels = {"job": args.job}
    labels.update(_parse_labels(args.label))
    print(f"Pushe {len(entries):,} Zeilen nach {args.loki_url} "
          f"(Labels {json.dumps(labels)}), Fenster {earliest:%H:%M}–{latest:%H:%M} UTC ...",
          file=sys.stderr)
    sent = push_to_loki(args.loki_url, labels, entries)
    print(f"Fertig: {sent:,} Zeilen in Loki.", file=sys.stderr)


if __name__ == "__main__":
    main()
