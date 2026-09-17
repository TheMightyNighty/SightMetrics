> 🇬🇧 [English version](SECURITY.md)

# Sicherheitsrichtlinie

## Unterstützte Versionen

| Version | Unterstützt |
|---|---|
| 2.1.x | ✅ |
| 2.0.x | ✅ (nur Sicherheitsfixes) |
| < 2.0 | ❌ (bitte aktualisieren; mit 2.0 hat sich das Cube-Schema geändert) |

Unterstützter Plattformbereich: TYPO3 13.4 LTS / 14, PHP 8.2–8.4 (siehe
`extension/sight_metrics/composer.json`).

## Eine Schwachstelle melden

Bitte **kein** öffentliches GitHub-Issue für Sicherheitsprobleme eröffnen.

- Bevorzugt: [GitHub Private Vulnerability Reporting](https://github.com/TheMIghtyNighty/SightMetrics/security/advisories/new)
- Alternativ per E-Mail: robert.schleiermacher@gmail.com (Betreff-Präfix `[SECURITY]`)

Bitte angeben: betroffene Komponente (TYPO3-Extension `sight_metrics` oder
die Ingestion-Pipeline), Version/Commit, Reproduktionsschritte und
Einschätzung der Auswirkung. Mit einer ersten Rückmeldung ist innerhalb von
7 Tagen zu rechnen. Koordinierte Offenlegung ist erwünscht; Namensnennung im
Changelog erfolgt, sofern nicht anders gewünscht.

Für Schwachstellen in der veröffentlichten TYPO3-Extension gilt zusätzlich
der Prozess des [TYPO3 Security Teams](https://typo3.org/community/teams/security),
sobald die Extension über TER verfügbar ist.

## Hinweise zum Geltungsbereich

- Die Extension greift **nur lesend** auf die Cube-Datenbank zu
  (`report_ro`, nur SELECT); die Ingestion ist der einzige Schreibzugriff
  (`cube_rw`). Meldungen zur Rechtetrennung zwischen den beiden Paketen
  fallen in den Geltungsbereich.
- Der Demo-Stack (`demo/`) ist ausdrücklich **nicht für den Produktivbetrieb**
  gedacht; darin fest hinterlegte Demo-Zugangsdaten gelten nicht als
  Schwachstellen.
