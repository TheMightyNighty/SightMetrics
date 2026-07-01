# SightMetrics - Extension-Handbuch (Paket B)

TYPO3-Backend-Modul für Webzugriffsauswertung. Liest **ausschließlich read-only** die
Cube-DB (MariaDB, User `report_ro`); kein DuckDB, kein Schreiben.

---

## Inhaltsverzeichnis

1. [Dateistruktur](#1-dateistruktur)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Installation](#3-installation)
4. [Cube-Connection konfigurieren](#4-cube-connection-konfigurieren)
5. [TYPO3-Site ↔ Cube-Site zuordnen](#5-typo3-site--cube-site-zuordnen)
6. [Fehlerseite konfigurieren](#6-fehlerseite-konfigurieren)
7. [Mehrere Sites (eine Instanz)](#7-mehrere-sites-eine-instanz)
8. [TYPO3-Versionsmatrix](#8-typo3-versionsmatrix)
9. [Backend-Modul nutzen](#9-backend-modul-nutzen)
10. [Architektur & Erweiterung](#10-architektur--erweiterung)
11. [Tests & CI](#11-tests--ci)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Dateistruktur

```
extension/
├── lint.sh                         Linting-Runner: PHPStan + TYPO3 Coding Standards
├── run-tests.sh                    Lokaler Test-Runner (Suite 2a Unit, 2b Functional, 2c Smoke)
├── sync-to-demo.sh                 Sync extension/sight_metrics/ → demo/app/packages/sight_metrics/
│
└── sight_metrics/                  Composer-Paket sightmetrics/sight-metrics
    ├── composer.json               Paket-Metadaten + require-dev (phpstan, testing-framework …)
    ├── ext_emconf.php              TYPO3 Extension-Metadaten (Versions-Constraints offen für v14)
    ├── ext_conf_template.txt       Extension-Konfiguration (Fehlerseiten-Text, showTechnical, windowDays)
    ├── phpstan.neon                PHPStan-Konfiguration (lokal, Level 6)
    ├── phpstan.ci.neon             PHPStan-Konfiguration (CI, kein baselineExtensions-Noise)
    ├── phpunit.xml.dist            PHPUnit-Konfiguration für Unit-Tests
    ├── phpunit.functional.xml.dist PHPUnit-Konfiguration für Functional-Tests (SQLite)
    ├── .php-cs-fixer.dist.php      TYPO3 Coding Standards (php-cs-fixer)
    ├── .gitignore
    │
    ├── Classes/
    │   ├── Command/
    │   │   └── SmokeCommand.php    TYPO3-CLI: sightmetrics:smoke — prüft cube-Connection + Tabellen
    │   ├── Controller/
    │   │   └── DashboardController.php  Backend-Controller: lädt Daten, rendert Fluid-Template
    │   ├── Domain/
    │   │   └── Repository/
    │   │       └── CubeRepository.php   Alle Queries gegen die Cube-DB (sites/meta/daily/cube)
    │   └── Support/
    │       ├── ErrorPage.php       Rendert konfigurierbare Fehlerseite (DB weg)
    │       └── SiteSelector.php    Liest Site-Auswahl aus Request-Parameter + Session
    │
    ├── Configuration/
    │   ├── Backend/
    │   │   └── Modules.php         Backend-Modul-Registrierung (web_sightmetrics)
    │   ├── Commands.php            CLI-Kommando-Registrierung (sightmetrics:smoke)
    │   ├── Icons.php               Icon-Registrierung (EXT:sight_metrics/module.svg)
    │   └── Services.yaml           Symfony-DI-Konfiguration (CubeRepository als privater Service)
    │
    ├── Resources/
    │   ├── Private/
    │   │   ├── Language/
    │   │   │   └── locallang_mod.xlf   Modul-Überschrift (DE)
    │   │   └── Templates/
    │   │       └── Dashboard/
    │   │           └── Index.html  Fluid-Template: KPIs, Barlisten, Drill-down, Karte, Verlauf
    │   └── Public/
    │       ├── Css/
    │       │   └── dashboard.css   Modul-Styles (Barlisten, Karten-Panel, Drill-down, A11y)
    │       ├── Icons/
    │       │   └── module.svg      Backend-Modul-Icon
    │       ├── JavaScript/
    │       │   └── dashboard.js    Drill-down, Choropleth-Karte, ECharts-Initialisierung
    │       └── Vendor/
    │           ├── echarts.min.js  Apache ECharts (selbst-gehostet, kein CDN)
    │           └── world.js        ECharts Weltkarten-Datensatz
    │
    └── Tests/
        ├── bootstrap.php           PHPUnit-Bootstrap für Unit-Tests (ohne TYPO3-Core)
        ├── Functional/
        │   └── CubeRepositoryFunctionalTest.php  Functional-Tests (TYPO3+SQLite, 10 Tests)
        └── Unit/
            ├── ErrorPageTest.php   Unit-Tests für ErrorPage (konfigurierbare Meldungen)
            └── SiteSelectorTest.php  Unit-Tests für SiteSelector (Request-Parameter-Auswertung)
```

---

## 2. Voraussetzungen

| Komponente | Version |
|---|---|
| PHP | ^8.2 |
| TYPO3 CMS | ^13.4 oder ^14.0 |
| MariaDB | ≥ 10.5 (Cube-DB, write: `cube_rw`, read: `report_ro`) |
| Composer | v2 |

Die Extension enthält **kein** DuckDB und schreibt **nichts** in die Cube-DB.
Schreiben übernimmt ausschließlich Paket A (`ingestion/`).

---

## 3. Installation

### 3a. Composer (Produktionsbetrieb)

Die Extension kann als Composer-Paket aus dem lokalen Pfad eingebunden werden (bis zur
Veröffentlichung auf Packagist):

```json
// In der composer.json der TYPO3-Instanz:
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
# Extension in das Demo-TYPO3 synchronisieren (Demo-Stack muss laufen):
extension/sync-to-demo.sh

# Oder automatisch bei Änderungen (Demo):
cd demo && docker compose up -d
```

Die Demo nutzt einen `path`-Repository-Eintrag in `demo/app/composer.json`, sodass
`sync-to-demo.sh` genügt - kein `composer update` für Klassen-Änderungen nötig.

---

## 4. Cube-Connection konfigurieren

Die Extension erwartet eine TYPO3-DB-Connection mit dem Namen **`cube`** in
`$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube']`.

### additional.php (Produktionsbetrieb)

```php
// config/system/additional.php der TYPO3-Instanz
$GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['cube'] = [
    'driver'   => 'mysqli',
    'host'     => getenv('CUBE_RO_HOST') ?: 'db-host',
    'port'     => (int)(getenv('CUBE_RO_PORT') ?: 3306),
    'dbname'   => getenv('CUBE_RO_DB')   ?: 'analytics',
    'user'     => getenv('CUBE_RO_USER') ?: 'report_ro',
    'password' => getenv('CUBE_RO_PASSWORD'),   // nie im Klartext
    'charset'  => 'utf8mb4',
];
```

**Sicherheitshinweis:** Passwort immer aus Umgebungsvariable oder Secret-Datei lesen -
niemals im Klartext in `additional.php` hinterlegen. Für Container: Env-Var via
`docker-compose.yml` / Kubernetes Secret.

### Verbindung testen

```bash
vendor/bin/typo3 sightmetrics:smoke
```

Prüft: Connection `cube` existiert, Tabellen `cube`, `daily`, `meta` erreichbar.

---

## 5. TYPO3-Site ↔ Cube-Site zuordnen

In einer TYPO3-Instanz mit mehreren Sites (z. B. mehrere Behörden-Domains) kann
jede TYPO3-Site ihrer eigenen `site_id` im Cube zugeordnet werden.

### Konfiguration in `config/sites/<identifier>/config.yaml`

```yaml
# Beispiel: config/sites/behoerde_a/config.yaml
rootPageId: 1
base: 'https://behoerde-a.de/'
languages: ...

# SightMetrics: zugehörige site_id im Cube
sightmetrics_site_id: 1
```

```yaml
# Beispiel: config/sites/behoerde_b/config.yaml
rootPageId: 2
base: 'https://behoerde-b.de/'

sightmetrics_site_id: 2
```

### Verhalten

| Zustand | Modul-Verhalten |
|---|---|
| **Kein** `sightmetrics_site_id` in keiner TYPO3-Site | Alle Cube-Sites im Dropdown (Rückwärtskompatibilität) |
| **Eine** TYPO3-Site mit Mapping | Nur diese site_id sichtbar, automatisch ausgewählt |
| **Mehrere** TYPO3-Sites mit Mapping | Dropdown zeigt nur die zugeordneten Sites |

### Importer-Zuordnung (Kubernetes/Namespace)

Ein Importer pro Namespace schreibt mit einer festen `site_id`:

```bash
# Namespace A (Behörde A): site_id=1
CUBE_DSN="..." ./load_cube.sh /logs/access.log "Behörde A" 1

# Namespace B (Behörde B): site_id=2
CUBE_DSN="..." ./load_cube.sh /logs/access.log "Behörde B" 2
```

Beide schreiben in dieselbe `analytics`-Datenbank. TYPO3 zeigt im Modul
nur die Sites, die über `sightmetrics_site_id` zugeordnet sind - bei
Einzelzuordnung ohne Dropdown, bei mehreren mit Auswahl.

---

## 6. Fehlerseite konfigurieren

Wenn die Cube-DB nicht erreichbar ist, zeigt das Modul eine konfigurierbare Fehlerseite
statt einer PHP-Exception. Konfiguration im TYPO3-Backend unter
**Admin-Tools → Erweiterungen → sight_metrics**:

| Einstellung | Standard | Beschreibung |
|---|---|---|
| `errorTitle` | „Auswertung derzeit nicht verfügbar" | Überschrift der Fehlerseite |
| `errorMessage` | „Die Verbindung …" | Erläuterungstext |
| `showTechnical` | `0` | Technische Fehlermeldung anzeigen (nur für Admins/Debug) |
| `windowDays` | `92` | Serverseitiges Zeitfenster in Tagen: nur dieses Fenster wird aus der Cube-DB geladen (begrenzt das Transfervolumen unabhängig von der Retention). `0` = unbegrenzt. |

Die Cube-Connection ist von der TYPO3-Hauptverbindung vollständig getrennt - ein
Cube-DB-Ausfall nimmt das TYPO3-Backend nicht mit.

---

## 7. Mehrere Sites (eine Instanz)

Betriebsfall: **eine** TYPO3-Instanz mit mehreren Sites in **einem** Namespace, Cube in
**eurer** MariaDB. Alle Sites liegen in `analytics`, unterschieden durch `site_id`. Die
Zuordnung TYPO3-Site → Cube-`site_id` erfolgt über `sightmetrics_site_id` in der Site-
Config (§5); die GUI bietet die Site-Auswahl entsprechend an.

> Eine Mandanten-/DB-Isolation über getrennte Datenbanken pro Mandant ist für diesen
> Single-Instance-Betrieb **nicht nötig** und wurde bewusst nicht eingebaut. Sollte
> später echte Mehrmandantentrennung gefordert sein, wäre „eigene DB + eigene
> `cube`-Connection je Instanz" der Weg - die Extension bliebe unverändert.

---

## 8. TYPO3-Versionsmatrix

| sight_metrics | TYPO3 | PHP | Status |
|---|---|---|---|
| aktuell | ^13.4 | ^8.2 | aktiv getestet (Functional + Unit, CI) |
| aktuell | ^14.0 | ^8.2 | **verifiziert** gegen TYPO3 v14.3.4 + testing-framework 9.5 (Functional 13/13 + Unit 20/20); CI-Lane vorhanden |

emconf-Constraint: `13.4.0-14.99.99`. Die CI (`functional`-Job) testet beide
Hauptversionen in einer Matrix (TYPO3 `^13.4`/`^14.0` × PHP 8.2/8.3), mit der
jeweils passenden `typo3/testing-framework`-Version (8.x für v13, 9.x für v14).

Die Extension ist absichtlich schlank gehalten (kein TypoScript, kein Frontend,
kein TCA, keine Datenbank-Migrations-Skripte) um v14-Breaking-Changes minimal zu halten.
Modul-Labels kommen aus `Resources/Private/Language/locallang_mod.xlf` (kein
hartcodierter Text in `Modules.php`).

---

## 9. Backend-Modul nutzen

Modul: **Web → Logauswertung** (`web_sightmetrics`)

### Site-Auswahl

Bei mehreren Sites erscheint ein Dropdown. Die Auswahl wird per URL-Parameter `site`
übergeben und in der Nutzersitzung gespeichert.

### Zeitraum-Auswahl

Ein einziges Dropdown **„Zeitraum"** (Matomo-artig), nicht mehrere Felder nebeneinander:
- **Relativ:** Heute, Gestern, Letzte 7 / 30 / 90 Tage (Anker = neuester Datenstand, nie in die Zukunft).
- **Kalender:** Dieser/Letzter Monat, Dieses/Letztes Jahr.
- **Konkrete Jahre:** je ein Eintrag pro Jahr im Datenbestand (z. B. „Jahr 2025").
- **Gesamter Zeitraum** und **Benutzerdefiniert …**.

Erst bei **„Benutzerdefiniert …"** klappen die Felder `von`/`bis` (ISO-Datum) und ein
**Monats-Picker** auf; sonst bleiben sie eingeklappt. Der Default-Eintrag spiegelt den
initial geladenen Stand wider (siehe Zeitfenster unten) und löst kein Nachladen aus.

**Serverseitiges Zeitfenster (Skalierung):** Es wird nicht der gesamte Cube ins Frontend
geladen, sondern nur ein Fenster (Default 92 Tage, konfigurierbar via `windowDays`, 0 =
unbegrenzt). Auswahl **innerhalb** des Fensters filtert sofort clientseitig (inkl. Vergleich);
Auswahl **außerhalb** lädt das passende Fenster vom Server nach (Reload mit `?from=&to=`).
So bleibt das Transfervolumen unabhängig von der Retention der Cube-DB begrenzt.

### Dark Mode

Das Modul folgt dem TYPO3-Backend-Farbschema (Attribut `data-color-scheme`, sonst
`prefers-color-scheme`): Karten, Texte, Barlisten und die ECharts-Achsen/-Beschriftungen
werden im dunklen Schema lesbar umgefärbt. Die Umschaltung erfolgt clientseitig über die
Klasse `sm-dark` am Wurzel-Container.

### KPI-Leiste

Visits, Pageviews, Unique Visitors, Absprungrate, Gesamtbandbreite - immer für den
gewählten Zeitraum und die gewählte Site.

### Perioden-Vergleich

Checkbox **„Vorperiode vergleichen"** in der Leiste. Aktiviert, wird der gewählte
Zeitraum gegen die **unmittelbar vorausgehende Periode gleicher Länge** verglichen
(z. B. die 30 Tage davor). Jede KPI erhält ein Delta-Badge (▲/▼ ± %), richtungsgefärbt
(grün = besser, rot = schlechter; bei der Absprungrate ist „runter" gut). Im Verlauf
erscheint die Vorperiode als gestrichelte Referenzlinie (positionsweise Tag-zu-Tag).
Hinweis: Liegt die Vorperiode ganz oder teilweise vor dem ersten Datenstand
(`meta.von`), bleibt das Delta leer - verglichen wird nur über vollständig
vorhandene Zeiträume (keine verzerrten Teilvergleiche). Bei voll gewähltem
Gesamtzeitraum gibt es daher naturgemäß keine Vorperiode.

### Export

Zwei Buttons in der Leiste, rein clientseitig (kein Server-Roundtrip, CSP-konform):
- **CSV** - lädt den aktuellen Zeitraum als CSV herunter (UTF-8 mit BOM, `;`-getrennt,
  Excel-kompatibel): Kopf (Site/Zeitraum/Stand), Verlauf je Tag und alle Dimensions-
  Auswertungen (Land, Browser, OS, Gerät, Referrer, Suchbegriffe, Seiten, Ein-/Ausstieg,
  Downloads, Status, Methode, Stunde). Dateiname `sightmetrics_<site>_<von>_<bis>.csv`.
- **PDF** - öffnet den Browser-Druckdialog (》Als PDF speichern《). Ein Druck-Stylesheet
  blendet die Bedienleiste aus und legt die Panels für den Ausdruck um.

### Auswertungs-Panels

| Panel | Dimension (`dim`) |
|---|---|
| Verlaufsgrafik | Tages-Aggregat (`daily`-Tabelle) |
| Weltkarte (Choropleth) | `country` |
| Länder-Barliste | `country` |
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

### Drill-down

Klick auf eine Barlisten-Zeile öffnet eine Unterebene (z. B. Browser → Versionen,
OS → Versionen, Seitenbaum → Unterseiten). Tastatursteuerung über Enter/Space,
ARIA-konform (BITV 2.0 / WCAG 2.1 AA).

---

## 10. Architektur & Erweiterung

```
HTTP-Request (Admin-Browser)
        │
        ▼
DashboardController          ← lädt SiteSelector, ruft CubeRepository auf
        │                       fängt alle \Throwable → ErrorPage
        ▼
CubeRepository               ← TYPO3-ConnectionPool, Connection 'cube' (read-only)
        │                       Queries: sites() / meta() / daily() / cube()
        ▼
MariaDB analytics            ← Tabellen: cube, daily, meta
(report_ro, SELECT only)

Fluid-Template Index.html    ← rendert alle Panels; Daten als JSON-Block im HTML
        │
        ▼
dashboard.js                 ← ECharts-Initialisierung, Drill-down, Choropleth
```

### Neue Dimension hinzufügen

1. Ingestion-Seite: `transform.sql` — neuen `INSERT INTO cube_rows` Eintrag mit
   neuem `dim`-Schlüssel ergänzen.
2. Extension-Seite: `Index.html` — neuen Panel-Block analog zu bestehenden Panels
   einfügen (Fluid `<f:for>` auf `{cubeByDim.neuer_key}`).
3. Optional: `dashboard.js` — für Charts/Drill-down erweitern.

Kein PHP-Code muss für neue Dimensionen geändert werden; `CubeRepository::cube()`
liefert alle `dim`-Schlüssel unabhängig.

---

## 11. Tests & CI

### Lokal (Demo-Stack nötig für 2b + 2c)

```bash
./run-tests.sh          # alle Suiten: Lint + Unit + Functional + Smoke + E2E
extension/lint.sh       # nur Lint: PHPStan Level 6 + TYPO3 Coding Standards
```

### Suiten

| Suite | Befehl | Voraussetzung |
|---|---|---|
| **0 Lint** | `extension/lint.sh` | keiner |
| **2a Unit** | `phpunit -c phpunit.xml.dist` | keiner |
| **2b Functional** | `phpunit -c phpunit.functional.xml.dist` | kein Docker (SQLite) |
| **2c Smoke** | `typo3 sightmetrics:smoke` | Demo-Stack läuft |
| **3 E2E** | `e2e/run.sh` | Demo-Stack läuft, Puppeteer |

### CI (GitHub Actions)

Drei parallele Jobs (`.github/workflows/ci.yml`):

| Job | Was | Matrix |
|---|---|---|
| `lint-and-unit` | PHPStan + TYPO3 CS + PHPUnit Unit | PHP 8.2, 8.3 |
| `pipeline` | DuckDB transform.sql + Backup/Notify/Rotation/Lock | - |
| `functional` | PHPUnit Functional Tests (SQLite, kein Docker) | PHP 8.2, 8.3 |

Smoke- und E2E-Tests laufen nur lokal (brauchen Docker-Stack).

### Functional-Tests im Detail

`Tests/Functional/CubeRepositoryFunctionalTest.php` — 10 Tests:

| Test | Prüft |
|---|---|
| `testSitesReturnsEmptyWhenNoData` | Leere DB → leeres Array |
| `testSitesReturnsAllSitesOrdered` | Alphabetische Site-Sortierung |
| `testMetaReturnsCorrectAggregatesForSite` | KPI-Werte stimmen |
| `testMetaReturnsEmptyArrayForUnknownSite` | Unbekannte site_id → leer |
| `testDailyReturnsRowsForCorrectSite` | daily() filtert nach site_id |
| `testCubeReturnsRowsFilteredBySite` | cube() liefert nur eigene Dims |
| `testSiteIsolation` | Zwei Sites gegenseitig isoliert |
| `testDailyReturnsEmptyForSiteWithoutData` | Keine Daily-Daten → leer |
| `testCubeReturnsEmptyWhenNoDimensionRows` | Site ohne Cube-Zeilen → leer |
| `testCubeReturnsEmptyForUnknownSite` | Unbekannte site_id in cube() → leer |

---

## 12. Troubleshooting

### „Auswertung derzeit nicht verfügbar"

Die Cube-DB ist nicht erreichbar. Prüfschritte:

```bash
# 1. Connection-Parameter prüfen
vendor/bin/typo3 sightmetrics:smoke

# 2. MariaDB direkt testen
mysql -h <host> -P <port> -u report_ro -p analytics -e "SELECT 1 FROM meta LIMIT 1;"

# 3. TYPO3 Log prüfen
tail -f var/log/typo3_*.log
```

### CSP-Fehler (Content Security Policy)

Das Backend-Modul bettet JSON-Daten inline ein und nutzt selbst-gehostetes ECharts.
Wenn die TYPO3-Instanz eine strenge CSP setzt, kann es zu Konsolen-Fehlern kommen.

Lösung: In `additional.php` die CSP für das Backend-Modul explizit erweitern oder
ECharts + world.js in den TYPO3-eigenen Asset-Ordner verschieben und per
`PageRenderer::addJsFile()` einbinden.

### `trustedHostsPattern`-Fehler

Im Demo ist `trustedHostsPattern = '.*'` gesetzt (alle Hosts erlaubt).
Für Produktion: konkreten Hostnamen eintragen:

```php
$GLOBALS['TYPO3_CONF_VARS']['SYS']['trustedHostsPattern'] = 'auswertung\.behoerde\.de';
```

### Kein Zugriff auf das Modul

Das Backend-Modul `web_sightmetrics` benötigt Benutzergruppen-Rechte.
Im TYPO3-Backend unter **Admin-Tools → Benutzer → Benutzergruppen**: Modul
„Logauswertung" in die entsprechende Gruppe aufnehmen.

### Leere Auswertung obwohl Daten importiert

- `site_id` in `sites.conf` muss mit der im Dropdown gewählten Site übereinstimmen.
- Datums-Picker: Standard ist der aktuelle Monat - prüfen, ob Daten in diesem Zeitraum liegen.
- `SELECT COUNT(*) FROM meta;` auf der Cube-DB prüfen.
