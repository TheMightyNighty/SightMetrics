#!/usr/bin/env python3
"""Generator fuer realistische Webserver-Logs (Apache "combined") fuer die
Gruene-Wiese-/Weg-3-Pipeline.

Session-basiert: ein Besucher (oeffentliche IP + fester User-Agent) erzeugt
mehrere aufeinanderfolgende Pageviews innerhalb eines Zeitfensters -> echte
Visits mit >1 Pageview, Einstieg/Ausstieg, Besucherpfade. Wiederkehrende
Besucher aus einem Pool. KEINE privaten IPs (alles oeffentlich, damit GeoIP
greift). Tagesgang (diurnal) ueber die Zeit.

--clean : nur 2xx-Content-Hits (keine Assets/Bots/Redirects) -> muss NICHT
          mehr vorgefiltert werden. Ideal fuer schnelle Testlaeufe.

Beispiele:
    python3 generate_logs.py --clean -n 1000 --days 14 -o logs/example_1k.log
    python3 generate_logs.py -n 2000000 -o logs/access.log     # mit Rauschen
"""
import argparse
import datetime as dt
import gzip
import os
import random
import sys

# --- Behoerden-Seitenbaum (gut fuer Drill-down-Demo) -------------------------
# (Pfad, Gewicht) – Gewicht steuert die Popularitaet (Zipf-artig).
CONTENT_PATHS = [
    ("/", 30),
    ("/aktuelles", 12),
    ("/aktuelles/pressemitteilungen", 8),
    ("/aktuelles/pressemitteilungen/2026-haushalt", 5),
    ("/aktuelles/pressemitteilungen/2026-buergerbeteiligung", 4),
    ("/buergerservice", 18),
    ("/buergerservice/personalausweis", 12),
    ("/buergerservice/reisepass", 9),
    ("/buergerservice/anmeldung-wohnsitz", 11),
    ("/buergerservice/kfz-zulassung", 7),
    ("/buergerservice/termin-vereinbaren", 14),
    ("/formulare", 9),
    ("/formulare/antrag-wohngeld", 6),
    ("/formulare/antrag-elterngeld", 6),
    ("/amt/oeffnungszeiten", 13),
    ("/amt/kontakt", 10),
    ("/amt/organisation", 4),
    ("/bauen-umwelt", 5),
    ("/bauen-umwelt/bauantrag", 4),
    ("/bauen-umwelt/abfallkalender", 8),
    ("/suche", 6),
]
# Downloads (eigener Action-Typ, fuer "Downloads"-Top-Liste)
DOWNLOAD_PATHS = [
    ("/formulare/antrag-wohngeld.pdf", 5),
    ("/formulare/antrag-elterngeld.pdf", 5),
    ("/amt/abfallkalender-2026.pdf", 6),
    ("/aktuelles/haushaltsplan-2026.pdf", 3),
]
# Einstiegsseiten (typische Landing-Pages aus Suche/extern)
ENTRY_PATHS = ["/", "/buergerservice", "/buergerservice/termin-vereinbaren",
               "/amt/oeffnungszeiten", "/buergerservice/personalausweis",
               "/aktuelles", "/buergerservice/anmeldung-wohnsitz"]

ASSET_PATHS = ["/static/app.css", "/static/app.js", "/static/logo.svg",
               "/static/fonts/govsans.woff2", "/favicon.ico",
               "/static/hero.jpg", "/static/print.css"]

REFERRERS_EXT = [  # (Referrer, Gewicht) – erster Hit einer Session
    ("-", 38),                                         # Direkteinstieg
    ("https://www.google.com/", 26),
    ("https://www.google.com/search?q=personalausweis+amt", 9),
    ("https://www.bing.com/", 6),
    ("https://duckduckgo.com/", 5),
    ("https://www.service.bund.de/", 7),               # Behoerdenportal -> website
    ("https://t.co/abc123", 3),                        # social
    ("https://www.facebook.com/", 3),                  # social
]

USER_AGENTS = [  # (UA, Gewicht) – mobil-lastig, wie echte Behoerdenseiten
    ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1", 26),
    ("Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Mobile Safari/537.36", 22),
    ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36", 28),
    ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15", 12),
    ("Mozilla/5.0 (X11; Linux x86_64; rv:126.0) Gecko/20100101 Firefox/126.0", 12),
]
BOT_UA = "Googlebot/2.1 (+http://www.google.com/bot.html)"

# Diurnaler Tagesgang (relatives Gewicht je Stunde, lokal). Nachts wenig.
HOURLY = [2,1,1,1,1,2,4,7,11,13,14,13,12,12,13,14,13,11,9,8,7,6,4,3]


def weighted(rng, pairs):
    items, w = zip(*pairs)
    return rng.choices(items, weights=w, k=1)[0]


def random_public_ip(rng):
    """Oeffentliche, nicht-reservierte IPv4 (damit GeoIP greift)."""
    while True:
        a = rng.randint(1, 223)
        if a in (10, 127, 0):
            continue
        b, c, d = rng.randint(0, 255), rng.randint(0, 255), rng.randint(1, 254)
        if a == 172 and 16 <= b <= 31:   continue   # privat
        if a == 192 and b == 168:        continue   # privat
        if a == 169 and b == 254:        continue   # link-local
        if a == 100 and 64 <= b <= 127:  continue   # CGNAT
        if a == 198 and b in (18, 19):   continue   # benchmark
        return f"{a}.{b}.{c}.{d}"


def make_visitor(rng):
    return {"ip": random_public_ip(rng), "ua": weighted(rng, USER_AGENTS)}


def fmt_line(ts, ip, method, path, status, size, referrer, ua):
    tstr = ts.strftime("%d/%b/%Y:%H:%M:%S +0000")
    return (f'{ip} - - [{tstr}] "{method} {path} HTTP/1.1" {status} {size} '
            f'"{referrer}" "{ua}"\n')


def sample_time(rng, start, end):
    """Zufaelliger Zeitpunkt im Fenster, nach Tagesgang gewichtet."""
    span_days = max((end - start).days, 1)
    day = start + dt.timedelta(days=rng.randint(0, span_days - 1))
    hour = rng.choices(range(24), weights=HOURLY, k=1)[0]
    return day.replace(hour=hour, minute=rng.randint(0, 59),
                       second=rng.randint(0, 59), microsecond=0)


def build_session(rng, visitor, t0, clean):
    """Erzeugt die Zeilen genau EINER Session (Liste von (ts, line))."""
    lines = []
    # Pageview-Anzahl: Bounce-lastig, langer Tail.
    r = rng.random()
    n = 1 if r < 0.42 else 2 if r < 0.66 else 3 if r < 0.82 \
        else rng.randint(4, 7) if r < 0.95 else rng.randint(8, 16)

    ip, ua = visitor["ip"], visitor["ua"]
    ts = t0
    referrer = weighted(rng, REFERRERS_EXT)        # nur Einstieg hat Ext-Referrer
    # Einstiegsseite bevorzugt aus ENTRY_PATHS
    first_path = rng.choice(ENTRY_PATHS)
    paths = [first_path] + [weighted(rng, CONTENT_PATHS) for _ in range(n - 1)]

    for i, path in enumerate(paths):
        # gelegentlich ein Download als "Pageview"
        if i > 0 and rng.random() < 0.06:
            path = weighted(rng, DOWNLOAD_PATHS)
        method = "POST" if path in ("/buergerservice/termin-vereinbaren",
                                    "/suche") and rng.random() < 0.5 else "GET"
        status = 200
        if not clean:
            # etwas realistisches Rauschen
            rr = rng.random()
            status = 404 if rr < 0.02 else 301 if rr < 0.05 else 500 if rr < 0.055 else 200
        size = rng.randint(800, 60000) if status == 200 else rng.randint(0, 700)
        ref = referrer if i == 0 else "-"             # Folge-Hits: intern
        lines.append((ts, fmt_line(ts, ip, method, path, status, size, ref, ua)))

        # Assets nur im "noisy"-Modus (muessten sonst vorgefiltert werden)
        if not clean and status == 200 and rng.random() < 0.7:
            for _ in range(rng.randint(1, 3)):
                a = rng.choice(ASSET_PATHS)
                ats = ts + dt.timedelta(seconds=rng.randint(0, 2))
                lines.append((ats, fmt_line(ats, ip, "GET", a, 200,
                                            rng.randint(300, 8000), path, ua)))
        ts += dt.timedelta(seconds=rng.randint(4, 240))    # Verweildauer
    return lines


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-n", "--num", type=int, default=1000,
                   help="Ziel-Anzahl Log-Zeilen (Default: 1000)")
    p.add_argument("-o", "--output", default="logs/example_1k.log")
    p.add_argument("--days", type=int, default=14, help="Zeitraum rueckwirkend")
    p.add_argument("--clean", action="store_true",
                   help="nur 2xx-Content (keine Assets/Bots/Redirects) -> kein Vorfiltern")
    p.add_argument("--regulars", type=int, default=0,
                   help="Pool wiederkehrender Besucher (0 = auto ~ num/12)")
    p.add_argument("--gzip", action="store_true")
    p.add_argument("--seed", type=int, default=42)
    args = p.parse_args()

    rng = random.Random(args.seed)
    out_path = args.output + (".gz" if args.gzip and not args.output.endswith(".gz") else "")
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)

    end = dt.datetime.now(dt.timezone.utc).replace(hour=0, minute=0, second=0,
                                                   microsecond=0, tzinfo=None)
    start = end - dt.timedelta(days=args.days)

    n_reg = args.regulars or max(args.num // 12, 5)
    regulars = [make_visitor(rng) for _ in range(n_reg)]

    print(f"Erzeuge ~{args.num:,} Zeilen ({'clean' if args.clean else 'mit Rauschen'}) "
          f"-> {out_path}", file=sys.stderr)
    print(f"Zeitraum: {start.date()} .. {end.date()} | Stamm-Besucher: {n_reg}",
          file=sys.stderr)

    rows = []
    while len(rows) < args.num:
        # 40 % wiederkehrend (power-law: kleiner Index = haeufiger), sonst neu
        if rng.random() < 0.40:
            idx = int(n_reg * (rng.random() ** 2.2))
            visitor = regulars[min(idx, n_reg - 1)]
        else:
            visitor = make_visitor(rng)
        t0 = sample_time(rng, start, end)
        rows.extend(build_session(rng, visitor, t0, args.clean))

    rows = rows[:args.num]
    rows.sort(key=lambda x: x[0])                  # wie ein echtes Access-Log

    opener = gzip.open if args.gzip else open
    with opener(out_path, "wt", encoding="utf-8") as fh:
        fh.writelines(line for _, line in rows)

    size_kb = os.path.getsize(out_path) / 1024
    print(f"Fertig: {len(rows):,} Zeilen, {size_kb:.0f} KB", file=sys.stderr)


if __name__ == "__main__":
    main()
