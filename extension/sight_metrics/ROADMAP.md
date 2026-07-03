# Roadmap

Offene Punkte (Stand 2026-07-03). Behobene Findings wurden entfernt — Details zu
abgeschlossenen Themen stehen in `CHANGELOG.md` (Version 1.2.0) und der Git-Historie.
Zuletzt abgeschlossen: alle 12 Findings der Projektpruefung vom 2026-07-02 (zweiter
Durchgang: Mandantentrennung, Ajax-Modul-Berechtigung, Top-N-Detailfixes, Cache-GC-Doku,
Doku-Aktualisierung).

## Architektur

- **Seitenbaum (`url`-Dimension) ohne Nachlade-Konzept** — der rekursive Pfad-Baum
  (`buildTree()`/`renderTree()` in `dashboard.js`) wird weiterhin client-seitig aus dem
  vollstaendigen `url`-Datensatz des Zeitfensters gebaut; bei Sites mit sehr vielen
  unterschiedlichen URLs waechst der Initial-Payload entsprechend (unabhaengig von
  `windowDays`). Alle uebrigen hochkardinalen Dimensionen sind seit dem Top-N-Umbau
  serverseitig begrenzt — der Seitenbaum wurde dabei **bewusst ausgeklammert**: er ist
  strukturell anders (Pfadsegmente statt fester Eltern-Kind-Dimensionen mit
  `chr(31)`-Trenner) und braucht ein eigenes Baum-Nachlade-Konzept (z. B. Aufklappen
  eines Astes laedt die Kinder des Pfad-Praefixes nach, analog `parentKey`, aber mit
  `LIKE 'praefix/%'`-Semantik auf Pfadebene und Aggregation der Unterbaum-Summen).
  Fuer die bisherigen Einsatzgroessen (einzelne Behoerden-Websites) unkritisch; vor dem
  Einsatz auf sehr grossen Portalen die tatsaechliche URL-Kardinalitaet pruefen
  (siehe `docs/extension-handbuch.md`, "Bekannte Grenzen").
