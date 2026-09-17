> 🇬🇧 [English version](extension-handbuch.md)

# SightMetrics – Extension-Handbuch (Paket B)

> **Hinweis:** Die maßgebliche, gepflegte Extension-Dokumentation ist die
> ReST-Dokumentation in
> [`extension/sight_metrics/Documentation/`](../extension/sight_metrics/Documentation/)
> (für docs.typo3.org). Dieses Handbuch besteht als zusätzlicher,
> betriebsorientierter Leitfaden fort; im Konfliktfall haben die
> ReST-Dokumentation und [`docs/SCHEMA.de.md`](SCHEMA.de.md) (für den
> DB-Contract) Vorrang.

TYPO3-Backend-Modul für die Webzugriffsanalyse. **Read-Only**-Zugriff auf
die Cube-DB (MariaDB, Benutzer `report_ro`); kein DuckDB, kein Schreiben.

---

## Inhaltsverzeichnis

1. [Dateistruktur](#1-dateistruktur)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Installation](#3-installation)
4. [Konfiguration der Cube-Verbindung](#4-konfiguration-der-cube-verbindung)
5. [Zuordnung einer TYPO3-Site zu einer Cube-Site](#5-zuordnung-einer-typo3-site-zu-einer-cube-site)
6. [Konfiguration der Fehlerseite](#6-konfiguration-der-fehlerseite)
7. [Mehrere Sites (eine Instanz)](#7-mehrere-sites-eine-instanz)
8. [TYPO3-Versionsmatrix](#8-typo3-versionsmatrix)
9. [Nutzung des Backend-Moduls](#9-nutzung-des-backend-moduls)
10. [Architektur & Erweiterung](#10-architektur--erweiterung)
11. [Tests & CI](#11-tests--ci)
12. [Fehlerbehebung](#12-fehlerbehebung)

---

## 1. Dateistruktur

```
extension/
├── lint.sh                         Lint-Runner: PHPStan + TYPO3-Coding-Standards
├── run-tests.sh                    Lokaler Test-Runner (2a Unit, 2b Functional, 2c Smoke, 2d JS)
│
└── sight_metrics/                  Composer-Paket sightmetrics/sight-metrics
    ├── composer.json               Paket-Metadaten + require-dev (phpstan, testing-framework, …)
    ├── ext_emconf.php               TYPO3-Extension-Metadaten (Versionsbeschränkungen offen für v14)
    ├── ext_localconf.php           Registriert den Cache "sight_metrics" (Cache-Framework)
    ├── ext_conf_template.txt       Extension-Konfiguration (Fehlerseite, windowDays, cacheLifetime)
    ├── package.json                Dev-Tooling: JS-Tests + versionsfixierte Vendor-Assets (npm)
    ├── package-lock.json           Versionsfixierung für Chart.js/Leaflet/jsdom
    ├── CHANGELOG.md                Änderungshistorie der Extension
    ├── ROADMAP.md                  Offene Punkte / Review-Erkenntnisse
    ├── REUSE.toml · LICENSES/      REUSE-konforme Lizenzstruktur
    ├── phpstan.neon                PHPStan-Konfiguration (lokal, Level 6)
    ├── phpstan.ci.neon             PHPStan-Konfiguration (CI, ohne baselineExtensions-Rauschen)
    ├── phpunit.xml.dist            PHPUnit-Konfiguration für Unit-Tests
    ├── phpunit.functional.xml.dist PHPUnit-Konfiguration für Functional-Tests (SQLite)
    ├── .php-cs-fixer.dist.php      TYPO3-Coding-Standards (php-cs-fixer)
    ├── .gitignore
    │
    ├── Classes/
    │   ├── Command/
    │   │   ├── SmokeCommand.php    TYPO3-CLI: sightmetrics:smoke — prüft Cube-Verbindung + Tabellen
    │   │   └── HealthCommand.php   TYPO3-CLI: sightmetrics:health — Datenaktualität, Nagios-Exit-Codes
    │   ├── Controller/
    │   │   ├── DashboardController.php  Backend-Controller: lädt Daten, rendert das Fluid-Template
    │   │   └── TopNAjaxController.php   Ajax: Top-N-Lazy-Loading ("+ N weitere", Drill-down)
    │   ├── Domain/
    │   │   └── Repository/
    │   │       └── CubeRepository.php   Alle Abfragen gegen die Cube-DB (inkl. topN/dimSummary, Caching)
    │   └── Support/
    │       ├── ErrorPage.php       Rendert eine konfigurierbare Fehlerseite (DB nicht erreichbar)
    │       ├── SiteSelector.php    Site-Auswahl + Webmount-basierte Mandantentrennung
    │       ├── TopNDims.php        Whitelists: welche Dimensionen serverseitig Top-N-begrenzt sind
    │       └── WindowResolver.php  Serverseitiges Zeitfenster (windowDays, from/to-Clamping)
    │
    ├── Configuration/
    │   ├── Backend/
    │   │   ├── Modules.php         Backend-Modul-Registrierung (web_sightmetrics)
    │   │   └── AjaxRoutes.php      Ajax-Route sightmetrics_topn (erbt Modulberechtigung)
    │   ├── Commands.php            CLI-Kommando-Registrierung (sightmetrics:smoke, :health)
    │   ├── Icons.php               Icon-Registrierung (EXT:sight_metrics/module.svg)
    │   └── Services.yaml            Symfony-DI-Konfiguration (Controller public, Rest private)
    │
    ├── Resources/
    │   ├── Private/
    │   │   ├── Language/
    │   │   │   └── locallang_mod.xlf   Modultitel (Standard: Englisch)
    │   │   └── Templates/
    │   │       └── Dashboard/
    │   │           └── Index.html  Fluid-Template: JSON-Datenblock + Panel-Gerüst
    │   └── Public/
    │       ├── Css/
    │       │   └── dashboard.css   Modul-Styles (Balkenlisten, Karten-Panel, Drill-down, Barrierefreiheit)
    │       ├── Icons/
    │       │   └── module.svg      Backend-Modul-Icon
    │       ├── JavaScript/
    │       │   └── dashboard.js    Rendering: Chart.js-Charts, Leaflet-Karte, Top-N/Drill-down
    │       └── Vendor/             (Herkunft/Prüfsummen: NOTICE.md; bezogen via npm run vendor:update)
    │           ├── chart.umd.min.js  Chart.js (MIT, selbst gehostet, kein CDN)
    │           ├── leaflet.js · leaflet.css · images/  Leaflet (BSD-2-Clause)
    │           ├── world.js        Weltkarten-GeoJSON (Natural Earth via world-atlas)
    │           └── NOTICE.md       Versionen, Lizenzen, SHA-256-Prüfsummen
    │
    ├── scripts/
    │   └── update-vendor.mjs       Kopiert Chart.js/Leaflet aus node_modules nach Vendor/
    │
    └── Tests/
        ├── bootstrap.php           PHPUnit-Bootstrap für Unit-Tests (ohne TYPO3-Core)
        ├── Functional/
        │   └── CubeRepositoryFunctionalTest.php  Functional-Tests (TYPO3+SQLite)
        ├── JavaScript/
        │   └── dashboard.smoke.test.mjs  DOM-Smoke-Test (jsdom, Chart.js/Leaflet-Fakes)
        └── Unit/
            ├── ErrorPageTest.php   Unit-Tests für ErrorPage (konfigurierbare Meldungen)
            ├── SiteSelectorTest.php  Unit-Tests für SiteSelector (inkl. Mandantentrennung)
            └── WindowResolverTest.php  Unit-Tests für das Zeitfenster (inkl. iso()-Validierung)
```

---

## 2. Voraussetzungen

| Komponente | Version |
|---|---|
| PHP | ^8.2 |
| TYPO3 CMS | ^13.4 oder ^14.0 |
| MariaDB | ≥ 10.5 (Cube-DB, Schreiben: `cube_rw`, Lesen: `report_ro`) |
| Composer | v2 |

Die Extension enthält **kein** DuckDB und schreibt **nichts** in die
Cube-DB. Das Schreiben erfolgt ausschließlich durch Paket A (`ingestion/`).

---

## 3. Installation

### 3a. Composer (Produktion)

Die Extension kann als Composer-Paket aus einem lokalen Pfad eingebunden
werden (solange sie noch nicht auf Packagist veröffentlicht ist):

```json
// in der composer.json der TYPO3-Instanz:
{
    "repositories": [
        {
            "type": "path",
            "url": "/opt/sightmetrics/extension/sight_metrics",
            "options": { "symlink": false }
        }
    ],
    "require": {
        "sightmetrics/sight-metrics": "*"
    }
}
```

```bash
composer require sightmetrics/sight-metrics
vendor/bin/typo3 extension:activate sight_metrics
```

### 3b. Lokale Entwicklung (Demo-Stack)

```bash
cd demo && docker compose up -d
```

Der `web`-Dienst bindmountet `extension/sight_metrics/` direkt als
`packages/sight_metrics` (siehe `demo/docker-compose.yaml`). Zusammen mit
dem `path`-Repository-Eintrag in `demo/app/composer.json` sind Änderungen
am Extension-Code sofort im Container sichtbar — kein Sync-/Kopierschritt
und kein `composer update` für Klassenänderungen nötig.

---

## 4. Konfiguration der Cube-Verbindung

Die Extension erwartet eine TYPO3-DB-Verbindung namens **`cube`** in
`$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube']`.

### additional.php (Produktion)

```php
// config/system/additional.php der TYPO3-Instanz
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube'] = [
    'driver'   => 'mysqli',
    'host'     => getenv('CUBE_RO_HOST') ?: 'db-host',
    'port'     => (int)(getenv('CUBE_RO_PORT') ?: 3306),
    'dbname'   => getenv('CUBE_RO_DB')   ?: 'analytics',
    'user'     => getenv('CUBE_RO_USER') ?: 'report_ro',
    'password' => getenv('CUBE_RO_PASSWORD'),   // niemals im Klartext
    'charset'  => 'utf8mb4',
];
```

**Sicherheitshinweis:** Das Passwort stets aus einer Umgebungsvariable oder
einer Secret-Datei lesen — niemals im Klartext in `additional.php`
hinterlegen. Bei Containern: Einbindung über `docker-compose.yaml` /
ein Kubernetes-Secret.

### Verbindung testen

```bash
vendor/bin/typo3 sightmetrics:smoke
```

Prüft: Die `cube`-Verbindung existiert, die Tabellen `cube`, `daily`, `meta`
sind erreichbar.

### Produktionshärtung: Abweichung von den Demo-Standardwerten

Die Demo-Umgebung (`demo/`) ist bewusst freizügig konfiguriert, damit der
lokale Docker-Compose-Stack ohne feste IPs/Hostnamen funktioniert. **Diese
beiden Standardwerte dürfen nicht unverändert in die Produktion übernommen
werden:**

- **`trustedHostsPattern`**: `demo/app/config/system/additional.php` setzt
  `$GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = '.*'`
  (akzeptiert jeden `Host`-Header → Risiko von Host-Header-Injection). In
  der Produktion stets auf den tatsächlichen Domainnamen einschränken,
  z. B. `'^(www\.)?my-domain\.example$'` (siehe die
  [TYPO3-Dokumentation zu `trustedHostsPattern`](https://docs.typo3.org/permalink/t3coreapi:trustedhostspattern)).
- **DB-Grant-Host für `report_ro`**: `demo/initdb/01-analytics.sh` legt
  den Cube-DB-Benutzer mit `'report_ro'@'%'` an (jeder Host darf sich als
  dieser Benutzer verbinden). In der Produktion den Grant auf das
  tatsächliche Web-Subnetz/den Host einschränken, z. B.
  `CREATE USER 'report_ro'@'10.0.1.0/255.255.255.0' ...` oder, bei einer
  festen IP, `'report_ro'@'10.0.1.42'`. Zusätzlich die Verbindung über
  Netzsegmentierung/Firewalling absichern — MySQL-Host-Grants allein sind
  keine vollständige Netzwerksicherung.
- **Cache-Garbage-Collection einrichten**: Die Tabelle
  `cache_sight_metrics` (TYPO3-DB) wächst ohne Bereinigung unbegrenzt —
  den Core-Task "Caching-Framework-Garbage-Collection" einrichten (z. B.
  täglich) mit ausgewähltem `sight_metrics`-Cache. Details in §10
  "Bekannte Grenzen: Skalierung & Caching".

---

## 5. Zuordnung einer TYPO3-Site zu einer Cube-Site

In einer TYPO3-Instanz mit mehreren Sites (z. B. mehreren
Behörden-Domains) kann jede TYPO3-Site einer eigenen `site_id` im Cube
zugeordnet werden.

### Konfiguration in `config/sites/<identifier>/config.yaml`

```yaml
# Beispiel: config/sites/authority_a/config.yaml
rootPageId: 1
base: 'https://authority-a.example/'
languages: ...

# SightMetrics: zugehörige site_id im Cube
sightmetrics_site_id: 1
```

```yaml
# Beispiel: config/sites/authority_b/config.yaml
rootPageId: 2
base: 'https://authority-b.example/'

sightmetrics_site_id: 2
```

### Verhalten

| Zustand | Modul-Verhalten |
|---|---|
| **Keine** `sightmetrics_site_id` auf irgendeiner TYPO3-Site | Alle Cube-Sites erscheinen im Dropdown (Abwärtskompatibilität) |
| **Eine** TYPO3-Site mit Zuordnung | Nur diese site_id ist sichtbar, automatisch ausgewählt (bei vorhandenem Webmount-Zugriff) |
| **Mehrere** TYPO3-Sites mit Zuordnungen | Das Dropdown zeigt nur Sites, auf die der Benutzer Webmount-Zugriff hat (basierend auf rootPageId); Administratoren sehen alle zugeordneten Sites |
| Eine Zuordnung existiert, aber der Benutzer hat auf **keine** der zugeordneten Sites Webmount-Zugriff | **Leeres Dashboard** — bewusst kein Fallback auf "alle Sites" (Mandantentrennung) |

> **Wichtig für den Mandantenbetrieb:** Die Mandantentrennung greift nur,
> wenn Sites zugeordnet sind. Ohne jegliche Zuordnung (erste Zeile) sieht
> **jeder** Benutzer mit Modulzugriff **alle** Cube-Sites — in einer
> Mandanten-Installation stets jeder Site eine `sightmetrics_site_id`
> zuweisen.

### Zuordnung der Importer (Kubernetes/Namespace)

Ein Importer pro Namespace schreibt mit fester `site_id`:

```bash
# Namespace A (Behörde A): site_id=1
CUBE_DSN="..." ./load_cube.sh /logs/access.log "Authority A" 1

# Namespace B (Behörde B): site_id=2
CUBE_DSN="..." ./load_cube.sh /logs/access.log "Authority B" 2
```

Beide schreiben in dieselbe `analytics`-Datenbank. TYPO3 zeigt im Modul
nur die über `sightmetrics_site_id` zugeordneten Sites — ohne Dropdown bei
einer einzelnen Zuordnung, mit Auswahl bei mehreren.

---

## 6. Konfiguration der Fehlerseite

Ist die Cube-DB nicht erreichbar, zeigt das Modul eine konfigurierbare
Fehlerseite statt einer PHP-Exception. Konfiguration im TYPO3-Backend unter
**Admin-Tools → Erweiterungen → sight_metrics**:

| Einstellung | Standard | Beschreibung |
|---|---|---|
| `errorTitle` | "Analytics currently unavailable" | Überschrift der Fehlerseite |
| `errorMessage` | "The connection …" | Erläuternder Text |
| `showTechnical` | `0` | technische Fehlermeldung anzeigen (nur Administratoren/Debug) |
| `windowDays` | `92` | Serverseitiges Zeitfenster in Tagen: Nur dieses Fenster wird aus der Cube-DB geladen (begrenzt das Übertragungsvolumen unabhängig von der Retention). `0` = unbegrenzt. |
| `cacheLifetime` | `21600` | Cache-TTL in Sekunden für Cube-DB-Lesezugriffe (TYPO3-Cache-Framework, Cache `sight_metrics`). `0` = kein Caching, jeder Aufruf liest live. Betrieb: siehe "Cache-Bereinigung ist Betreiberverantwortung" (§10). |

Die Cube-Verbindung ist vollständig von der TYPO3-Hauptverbindung
getrennt — ein Ausfall der Cube-DB legt das TYPO3-Backend nicht lahm.

---

## 7. Mehrere Sites (eine Instanz)

Anwendungsfall: **eine** TYPO3-Instanz mit mehreren Sites in **einem**
Namespace, Cube in **der eigenen** MariaDB. Alle Sites leben in
`analytics`, unterschieden über `site_id`. Die Zuordnung von einer
TYPO3-Site zu einer Cube-`site_id` erfolgt über `sightmetrics_site_id` in
der Site-Konfiguration (§5); die Oberfläche bietet entsprechend die
Site-Auswahl an.

> Mandanten-/DB-Isolation über getrennte Datenbanken je Mandant ist für
> dieses Single-Instance-Setup **nicht erforderlich** und wurde bewusst
> nicht eingebaut. Sollte später eine echte Mandantentrennung nötig sein,
> wäre "eigene DB + eigene `cube`-Verbindung je Instanz" der Weg — die
> Extension selbst würde unverändert bleiben.

---

## 8. TYPO3-Versionsmatrix

| sight_metrics | TYPO3 | PHP | Status |
|---|---|---|---|
| aktuell | ^13.4 | ^8.2 | aktiv getestet (Functional + Unit, CI) |
| aktuell | ^14.0 | ^8.2 | **verifiziert** gegen TYPO3 v14.3.4 + testing-framework 9.5 (Functional 13/13 + Unit 20/20); CI-Lane vorhanden |

emconf-Beschränkung: `13.4.0-14.99.99`. CI (der `functional`-Job) testet
beide Hauptversionen in einer Matrix (TYPO3 `^13.4`/`^14.0` × PHP
8.2/8.3), mit der passenden `typo3/testing-framework`-Version (8.x für
v13, 9.x für v14).

Die Extension wird bewusst schlank gehalten (kein TypoScript, kein
Frontend, keine TCA, keine Datenbank-Migrationsskripte), um die
Angriffsfläche für Breaking Changes in v14 zu minimieren. Modul-Labels
stammen aus `Resources/Private/Language/locallang_mod.xlf` (kein fest
verdrahteter Text in `Modules.php`).

---

## 9. Nutzung des Backend-Moduls

Modul: **Web → Web Analytics** (`web_sightmetrics`)

### Site-Auswahl

Ein Dropdown erscheint, wenn mehrere Sites vorhanden sind. Die Auswahl
wird über den URL-Parameter `site` übergeben und in der Benutzersitzung
gespeichert.

### Zeitraum-Auswahl

Ein einzelnes Dropdown **"Zeitraum"** (im Matomo-Stil), nicht mehrere
Felder nebeneinander:
- **Relativ:** Heute, Gestern, Letzte 7/30/90 Tage (verankert am neuesten
  verfügbaren Datenstand, nie in der Zukunft).
- **Kalendarisch:** Dieser/letzter Monat, dieses/letztes Jahr.
- **Bestimmte Jahre:** ein Eintrag je in den Daten vorhandenem Jahr (z. B.
  "Jahr 2025").
- **Gesamter Zeitraum** und **Individuell …**.

Nur **"Individuell …"** klappt die Felder `from`/`to` (ISO-Datum) und
einen **Monatspicker** auf; ansonsten bleiben sie eingeklappt. Der
Standardeintrag spiegelt den initial geladenen Zustand wider (siehe das
Zeitfenster unten) und löst kein erneutes Laden aus.

**Serverseitiges Zeitfenster (Skalierung):** Der gesamte Cube wird nicht
ins Frontend geladen — nur ein Fenster (Standard 92 Tage, konfigurierbar
über `windowDays`, 0 = unbegrenzt). Eine Auswahl **innerhalb** des
Fensters filtert sofort clientseitig (einschließlich Vergleich); eine
Auswahl **außerhalb** des Fensters lädt das passende Fenster vom Server
nach (Reload mit `?from=&to=`). Das hält das Übertragungsvolumen unabhängig
von der Retention der Cube-DB begrenzt.

### Dark Mode

Das Modul folgt dem Farbschema des TYPO3-Backends
(`data-color-scheme`-Attribut, mit Rückfall auf `prefers-color-scheme`):
Karten, Text, Balkenlisten sowie die Chart.js-Achsen/-Beschriftungen
werden für Lesbarkeit im dunklen Schema umgefärbt. Die Umschaltung
geschieht clientseitig über die Klasse `sm-dark` am Wurzel-Container.

### KPI-Leiste

Besuche, Seitenaufrufe, eindeutige Besucher, Absprungrate,
Gesamtbandbreite — stets für den gewählten Zeitraum und die gewählte Site.

### Zeitraumvergleich

Eine Checkbox **"Mit vorherigem Zeitraum vergleichen"** in der Leiste. Bei
Aktivierung wird der gewählte Zeitraum mit dem **unmittelbar vorangehenden
Zeitraum gleicher Länge** verglichen (z. B. die 30 Tage davor). Jede KPI
erhält ein Delta-Badge (▲/▼ ± %), farbcodiert nach Richtung (grün =
besser, rot = schlechter; bei der Absprungrate ist "runter" gut). Im
Trend-Chart erscheint der vorherige Zeitraum als gestrichelte
Referenzlinie (positionsweise, Tag zu Tag). Hinweis: Liegt der vorherige
Zeitraum ganz oder teilweise vor den ersten verfügbaren Daten
(`meta.von`), bleibt das Delta leer — Vergleiche laufen nur über
vollständig vorhandene Zeiträume (keine verzerrten Teilvergleiche). Bei
gewähltem gesamtem Zeitraum gibt es entsprechend naturgemäß keinen
vorherigen Zeitraum.

### Export

Zwei Schaltflächen in der Leiste, rein clientseitig (kein
Server-Roundtrip, CSP-konform):
- **CSV** – lädt den aktuellen Zeitraum als CSV herunter (UTF-8 mit BOM,
  `;`-getrennt, Excel-kompatibel): ein Kopfbereich (Site/Zeitraum/Stand),
  der Tagesverlauf und alle Dimensions-Aufschlüsselungen (Land, Browser,
  OS, Gerät, Referrer, Suchbegriffe, Seiten, Einstieg/Ausstieg,
  Downloads, Status, Methode, Stunde). Dateiname
  `sightmetrics_<site>_<from>_<to>.csv`.
- **PDF** – öffnet den Druckdialog des Browsers ("Als PDF speichern").
  Ein Druck-Stylesheet blendet die Steuerleiste aus und ordnet die Panels
  für den Druck neu an.

### Analyse-Panels

| Panel | Dimension (`dim`) |
|---|---|
| Trend-Chart | Tagesaggregat (Tabelle `daily`) |
| Weltkarte (Choroplethen) | `country` |
| Länder-Balkenliste | `country` |
| Browser | `browser` |
| Betriebssysteme | `os` |
| Gerätetypen | `device` |
| Referrer-Typen | `referrer_type` |
| Referrer-URLs | `referrer` |
| Suchbegriffe | `keyword` |
| Einstiegsseiten | `entry` |
| Ausstiegsseiten | `exit` |
| Downloads | `download` |
| Statuscodes | `status` |
| HTTP-Methoden | `method` |
| Seitenbaum | `url` (mit Drill-down) |
| Besuchszeiten (Stunde) | `hour` |

Hinweise zur Semantik (Details: Ingestion-Runbook §3/§8):

- **Statuscodes** enthalten auch 4xx/5xx (Fehlerdiagnose); `v` ist dort
  die Anzahl der *betroffenen Besucher*, nicht der Besuche. Alle anderen
  Panels zählen nur erfolgreiche Anfragen (Status < 400).
- **Bots/Crawler** werden bereits während der Ingestion über eine
  User-Agent-Heuristik herausgefiltert (`SM_BOT_FILTER`).
- **Tagesgrenzen und Besuchszeiten** werden seit Schema v2 in der
  Ingestion-Zeitzone `SM_TZ` berechnet (in `meta.tz` gespeichert, Standard
  UTC; für deutsche Installationen z. B. `SM_TZ=Europe/Berlin` setzen).
  Relative Zeitraum-Presets ("Heute", "Letzte 7 Tage") verankern sich in
  dieser Zone.
- Ein Tag erscheint erst, **wenn er vollständig ist**
  (Tagesgrenzen-Cut des inkrementellen Imports) — ein nächtlicher Lauf
  zeigt daher stets den Vortag.

### Drill-down

Ein Klick auf eine Zeile der Balkenliste öffnet eine Unterebene (z. B.
Browser → Versionen, OS → Versionen, Seitenbaum → Unterseiten). Per
Tastatur bedienbar über Enter/Leertaste, ARIA-konform (WCAG 2.1 AA).

---

## 10. Architektur & Erweiterung

```
HTTP-Request (Admin-Browser)
        │
        ▼
DashboardController          ← lädt SiteSelector, ruft CubeRepository
        │                       fängt alle \Throwable → ErrorPage
        ▼
CubeRepository               ← TYPO3 ConnectionPool, Verbindung 'cube' (read-only)
        │                       Abfragen: sites() / meta() / daily() / cube()
        ▼
MariaDB analytics            ← Tabellen: cube, daily, meta
(report_ro, nur SELECT)

Fluid-Template Index.html    ← rendert alle Panels; Daten als JSON-Block im HTML
        │
        ▼
dashboard.js                 ← Chart.js (Trend/Stunden), Leaflet (Choroplethen-Karte), Drill-down
```

### Bekannte Grenzen: Skalierung & Caching

**Serverseitiges Caching.** `daily()`/`cube()`/`topN()`/`dimSummary()`
(die Lesezugriffe, deren Volumen/Aufrufhäufigkeit mit Zeitfenster/
Kardinalität wächst) laufen über den Cache `sight_metrics` des
TYPO3-Cache-Frameworks (`VariableFrontend` + `Typo3DatabaseBackend`,
registriert in `ext_localconf.php`; die Tabelle `cache_sight_metrics`
wird von TYPO3 selbst via `extension:setup`/DB-Compare angelegt). Die TTL
wird über die Extension-Konfiguration `cacheLifetime` gesetzt (Standard
21600 s, 0 = deaktiviert — jeder Aufruf liest dann wieder live).
`sites()`/`meta()` bleiben bewusst ungecacht (kleine Einzelzeilen/Listen;
eine neue Site oder ein frischer Ingestion-Lauf sollen unverzüglich
sichtbar sein). Fehlt die Cache-Konfiguration (z. B. bei Unit-/
Functional-Tests ohne geladene `ext_localconf.php`), fällt
`CubeRepository::cached()` fehlerfrei auf die Live-Abfrage zurück.

**Cache-Bereinigung ist Betreiberverantwortung.** `Typo3DatabaseBackend`
löscht abgelaufene Einträge **nicht** selbstständig — sie bleiben als tote
Zeilen in `cache_sight_metrics` liegen, bis ein
Garbage-Collection-Lauf stattfindet. Die Cache-Keys sind
hochkardinal (jede Kombination aus Zeitraum, Dimension, Offset und
Drill-down-Parent-Kategorie erzeugt einen eigenen Eintrag), sodass die Tabelle im laufenden Betrieb kontinuierlich wächst. Zwei
Optionen:

- **Mit EXT:scheduler:** den Core-Task
  "Caching-Framework-Garbage-Collection" einrichten (z. B. täglich) und
  den Cache `sight_metrics` auswählen.
- **Ohne Scheduler (Cron/SQL):** abgelaufene Zeilen direkt auf der
  TYPO3-DB löschen, z. B. täglich per Cron:

  ```sql
  DELETE FROM cache_sight_metrics WHERE expires < UNIX_TIMESTAMP();
  ```

  (Die zugehörige Tabelle `cache_sight_metrics_tags` bleibt leer — die
  Extension setzt keine Cache-Tags — und benötigt keine eigene
  Bereinigung.)

Der Aufruf von `vendor/bin/typo3 cache:flush` leert die Tabelle ebenfalls
(grobschlächtig, aber unschädlich — der Cache füllt sich beim nächsten
Modulaufruf wieder).

**Serverseitige Kardinalitätsbegrenzung.** `windowDays` begrenzt nur die
Zeitachse (wie viele Tage geladen werden). Für jede Dimension mit
potenziell unbegrenzten unterschiedlichen Werten — Suchbegriffe,
Einstiegs-/Ausstiegsseiten, Downloads, Statuscodes, HTTP-Methoden,
Browser, OS, Gerätetyp sowie Referrer-Typ/-Name/-URL samt ihrer
Versions-/Modell-Unterkategorien — liefert `CubeRepository::topN()`
serverseitig nur die Top-N-Zeilen (Standard 8,
`TopNDims::DEFAULT_LIMIT`; Referrer-URLs 10), zusammen mit einer Summe
(`dimSummary()`) für die Prozentanzeige und "+ N weitere". Lazy Loading
(eine Änderung des Zeitraums im Picker, ein Klick auf "+ N weitere", das
Aufklappen einer Drill-down-Zeile) läuft über die Ajax-Route
`ajax_sightmetrics_topn` (`TopNAjaxController`,
`Configuration/Backend/AjaxRoutes.php`). Drill-down-Kinder (z. B.
Browser-Versionen unter "Chrome") werden nie vorab geladen — sie werden
erst beim Aufklappen über den Parameter `parentKey` angefragt
(`CubeRepository::applyParentFilter()`, ein Gleichheitsabgleich auf die
Spalte `parent` seit Schema v2, der die frühere
`chr(31)`-Präfix-Logik ersetzt — siehe [`docs/SCHEMA.de.md`](SCHEMA.de.md)).
Country bleibt bewusst unbegrenzt (die Choroplethen-Karte benötigt alle
Länder, und ISO-Codes sind ohnehin auf ca. 250 Werte beschränkt).

Der **Seitenbaum** (Dimension `url`) wird ebenfalls serverseitig
begrenzt, aber über ein eigenes Schema: `CubeRepository::urlTree()`
segmentiert die URL-Pfade in SQL (portable `SUBSTR`/`INSTR`-Ausdrücke,
lauffähig sowohl auf MariaDB als auch auf SQLite) und liefert nur die
obersten 8 Segmente je Ebene mit Teilbaumsummen. Die initiale Nutzlast
enthält die ersten zwei Ebenen (erste Ebene aufgeklappt, wie zuvor);
tiefere Zweige und "+ N weitere" werden von `dashboard.js` per Ajax-Route
`ajax_sightmetrics_tree` (`TreeAjaxController`, Pfadpräfix als
`path`-Parameter) nachgeladen. Das bedeutet: Kein Panel hängt mehr vom
vollständigen Zeilenbestand einer Dimension mit hoher Kardinalität ab —
die initiale `cube`-Nutzlast enthält jetzt nur noch die kleinen
Dimensionen (Country, Stunde).

### Eine neue Dimension hinzufügen

1. **Ingestion-Seite:** `transform.sql` — einen neuen `UNION ALL
   SELECT ...`-Zweig im Cube-Aufbau mit einem neuen `dim`-Schlüssel
   ergänzen (für Drill-down-Dimensionen den Parent/Child-Separator
   `chr(31)` in `dimkey` verwenden, siehe bestehende Zweige wie
   `browser_version`).
2. **Extension-Seite, Template:** `Index.html` — einen neuen Panel-Block
   mit leerem Container ergänzen (z. B. `<div id="bl-new-key"
   class="barlist"></div>`); das Template enthält nur das Gerüst, die
   Daten kommen als JSON-Block und werden clientseitig gerendert.
3. **Extension-Seite, JavaScript:** `dashboard.js` — die Dimension
   registrieren:
   - **Unbegrenzte Kardinalität** (URLs, Suchbegriffe etc.): einen Eintrag
     zu `TOPN_ROOT` hinzufügen (Container-ID + Metrik `pv`/`v`; bei einem
     Drill-down-Kind zusätzlich `child` sowie den Kind-Eintrag zu
     `TOPN_CHILD` ergänzen).
   - **Kleine, feste Wertemenge** (wie Country): ein klassischer
     `barlist()`-Aufruf in `render()` — die Zeilen kommen dann vollständig
     in der initialen Nutzlast.
4. **Extension-Seite, PHP (nur Top-N-Dimensionen):**
   `Classes/Support/TopNDims.php` — die Dimension zu
   `ROOT_METRIC_BY_DIM` (bzw. `CHILD_METRIC_BY_DIM`/`CHILD_OF_ROOT`)
   hinzufügen. **Ohne diesen Eintrag** liefert der Ajax-Endpunkt für die
   Dimension 400 (Whitelist), und der `DashboardController` lädt kein
   Top-N vor; ohne den Eintrag landet die Dimension stattdessen
   unbegrenzt in der initialen Nutzlast (`cube()` liefert jeden
   `dim`-Schlüssel zurück, der nicht in
   `TopNDims::excludedFromFullPayload()` gelistet ist).
5. Optional: die Dimension zu `EXPORT_DIMS` in `dashboard.js` für den
   CSV-Export hinzufügen und den JS-Smoke-Test (`Tests/JavaScript/`) um
   sie erweitern.

---

## 11. Tests & CI

### Lokal (Demo-Stack für 2b + 2c nötig)

```bash
./run-tests.sh          # alle Suiten: Lint + Unit + Functional + Smoke + E2E
extension/lint.sh       # nur Lint: PHPStan Level 6 + TYPO3-Coding-Standards
```

### Suiten

| Suite | Kommando | Voraussetzung |
|---|---|---|
| **0 Lint** | `extension/lint.sh` | keine |
| **2a Unit** | `phpunit -c phpunit.xml.dist` | keine |
| **2b Functional** | `phpunit -c phpunit.functional.xml.dist` | kein Docker (SQLite) |
| **2c Smoke** | `typo3 sightmetrics:smoke` | Demo-Stack läuft |
| **2d JS Smoke** | `npm test` (in `sight_metrics/`) | Node.js, kein Docker |
| **3 E2E** | `e2e/run.sh` | Demo-Stack läuft, Puppeteer |

### CI (GitHub Actions)

Drei parallele Jobs (`.github/workflows/ci.yml`):

| Job | Was | Matrix |
|---|---|---|
| `lint-and-unit` | PHPStan + TYPO3 CS + PHPUnit Unit | PHP 8.2, 8.3 |
| `pipeline` | DuckDB transform.sql + Backup/Notify/Rotation/Lock | – |
| `functional` | PHPUnit Functional-Tests (SQLite, kein Docker) | PHP 8.2, 8.3 |

Smoke- und E2E-Tests laufen nur lokal (benötigen den Docker-Stack).

### Functional-Tests im Detail

`Tests/Functional/CubeRepositoryFunctionalTest.php` — 10 Tests:

| Test | Prüft |
|---|---|
| `testSitesReturnsEmptyWhenNoData` | leere DB → leeres Array |
| `testSitesReturnsAllSitesOrdered` | alphabetische Site-Sortierreihenfolge |
| `testMetaReturnsCorrectAggregatesForSite` | KPI-Werte sind korrekt |
| `testMetaReturnsEmptyArrayForUnknownSite` | unbekannte site_id → leer |
| `testDailyReturnsRowsForCorrectSite` | daily() filtert nach site_id |
| `testCubeReturnsRowsFilteredBySite` | cube() liefert nur eigene Dimensionen |
| `testSiteIsolation` | zwei Sites sind gegenseitig isoliert |
| `testDailyReturnsEmptyForSiteWithoutData` | keine Tagesdaten → leer |
| `testCubeReturnsEmptyWhenNoDimensionRows` | Site ohne Cube-Zeilen → leer |
| `testCubeReturnsEmptyForUnknownSite` | unbekannte site_id in cube() → leer |

---

## 12. Fehlerbehebung

### "Analytics currently unavailable"

Die Cube-DB ist nicht erreichbar. Diagnoseschritte:

```bash
# 1. Verbindungsparameter prüfen
vendor/bin/typo3 sightmetrics:smoke

# 2. MariaDB direkt testen
mysql -h <host> -P <port> -u report_ro -p analytics -e "SELECT 1 FROM meta LIMIT 1;"

# 3. TYPO3-Log prüfen
tail -f var/log/typo3_*.log
```

### CSP-Fehler (Content Security Policy)

Das Backend-Modul bettet JSON-Daten inline ein (ein CSP-sicherer
`<script type="application/json">`-Block) und verwendet selbst
gehostetes Chart.js/Leaflet, geladen über den TYPO3-`PageRenderer`
(`addJsFooterFile`/`addCssFile`). Setzt die TYPO3-Instanz eine strikte
CSP, können dennoch Konsolenfehler auftreten (z. B. durch die
`style`-Attribute der Balkenlisten).

Lösung: die Backend-CSP gezielt in `additional.php` oder
`Configuration/ContentSecurityPolicies.php` erweitern, statt sie global
zu lockern.

### `trustedHostsPattern`-Fehler

Die Demo setzt `trustedHostsPattern = '.*'` (alle Hosts erlaubt). Für die
Produktion: den tatsächlichen Hostnamen setzen:

```php
$GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = 'analytics\.authority\.example';
```

### Kein Zugriff auf das Modul

Das Backend-Modul `web_sightmetrics` erfordert Benutzergruppen-
berechtigungen. Im TYPO3-Backend unter **Admin-Tools → Benutzer →
Benutzergruppen**: das Modul "Web Analytics" der relevanten Gruppe
hinzufügen.

### Leere Analyse trotz importierter Daten

- Die `site_id` in `sites.conf` muss mit der im Dropdown gewählten Site
  übereinstimmen.
- Datumsauswahl: Der Standard ist das initial geladene Zeitfenster
  (`windowDays`, Standard die letzten 92 Tage verfügbarer Daten) —
  prüfen, ob die Daten in diesen Bereich fallen; bei Bedarf "Gesamter
  Zeitraum" wählen.
- `SELECT COUNT(*) FROM meta;` auf der Cube-DB prüfen.
