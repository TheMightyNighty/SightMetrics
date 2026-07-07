<?php

declare(strict_types=1);

namespace SightMetrics\Domain\Repository;

use Doctrine\DBAL\ArrayParameterType;
use Doctrine\DBAL\ParameterType;
use TYPO3\CMS\Core\Cache\CacheManager;
use TYPO3\CMS\Core\Cache\Frontend\FrontendInterface;
use TYPO3\CMS\Core\Configuration\ExtensionConfiguration;
use TYPO3\CMS\Core\Database\ConnectionPool;
use TYPO3\CMS\Core\Database\Query\QueryBuilder;

/**
 * Liest die Cube-Tabellen ueber eine SEPARATE, read-only DB-Verbindung ('cube').
 * Kein Extbase, keine TCA – nur DBAL-SELECTs gegen aussenstehende Tabellen
 * (Abschnitt 11.1/11.4). Multi-Site: alle Lesezugriffe sind nach site_id gefiltert.
 *
 * daily()/cube() sind die Reads, deren Volumen mit Zeitfenster/Kardinalitaet waechst;
 * sie werden kurzlebig ueber den TYPO3-Cache "sight_metrics" gecacht (TTL per
 * Extension-Konfiguration, 0 = deaktiviert). meta()/sites() sind Einzelzeilen/kleine
 * Listen und bleiben bewusst live, damit z. B. eine neue Site sofort sichtbar ist.
 */
final class CubeRepository
{
    /**
     * Unterstuetzte Version des DB-Vertrags (Tabellen cube/daily/meta, siehe
     * docs/SCHEMA.md). Die Ingestion schreibt ihre Version nach meta.schema_version;
     * ist die Version dort NEUER, passen Leser und Schreiber nicht mehr zusammen.
     */
    public const SCHEMA_VERSION = 1;

    private const CONNECTION = 'cube';

    /**
     * Eltern|Kind-Trenner in dimkey-Werten (Drill-down-Dimensionen), exakt identisch zu
     * chr(31) in ingestion/transform.sql und der SEP-Konstante in dashboard.js.
     */
    private const CHILD_SEP = "\x1f";

    public function __construct(
        private readonly ConnectionPool $connectionPool,
        private readonly CacheManager $cacheManager,
        private readonly ExtensionConfiguration $extensionConfiguration,
    ) {}

    private function cache(): FrontendInterface
    {
        return $this->cacheManager->getCache('sight_metrics');
    }

    private function cacheLifetime(): int
    {
        try {
            $conf = $this->extensionConfiguration->get('sight_metrics');
            if (isset($conf['cacheLifetime']) && $conf['cacheLifetime'] !== '') {
                return max(0, (int)$conf['cacheLifetime']);
            }
        } catch (\Throwable) {
        }
        return 60;
    }

    /**
     * @param callable(): mixed $fetch
     */
    private function cached(string $identifier, callable $fetch): mixed
    {
        $lifetime = $this->cacheLifetime();
        if ($lifetime <= 0) {
            return $fetch();
        }
        // Cache-Konfiguration fehlt (z. B. Unit-/Functional-Tests ohne geladenes
        // ext_localconf.php) -> Caching ist ein reines Perf-Feature, kein
        // Korrektheitserfordernis, daher hier fehlertolerant auf Live-Query zurueckfallen.
        try {
            $cache = $this->cache();
        } catch (\Throwable) {
            return $fetch();
        }
        $entryIdentifier = md5($identifier);
        $value = $cache->get($entryIdentifier);
        if ($value !== false) {
            return $value;
        }
        $value = $fetch();
        $cache->set($entryIdentifier, $value, [], $lifetime);
        return $value;
    }

    private function qb(string $table): QueryBuilder
    {
        $qb = $this->connectionPool->getConnectionByName(self::CONNECTION)->createQueryBuilder();
        $qb->getRestrictions()->removeAll(); // Cube-Tabellen ohne TCA
        return $qb;
    }

    /**
     * Verfuegbare Sites (fuer die Auswahl).
     * $allowedIds: wenn gesetzt, nur diese site_ids zurueckgeben (TYPO3-Site-Mapping).
     * Leere Liste = kein Filter (alle Sites sichtbar, Rueckwaertskompatibilitaet).
     *
     * @param list<int>              $allowedIds
     * @return list<array<string,mixed>>
     */
    public function sites(array $allowedIds = []): array
    {
        $qb = $this->qb('meta')->select('site_id', 'site')->from('meta')->orderBy('site');
        if ($allowedIds !== []) {
            $qb->where($qb->expr()->in(
                'site_id',
                $qb->createNamedParameter(array_map('intval', $allowedIds), ArrayParameterType::INTEGER)
            ));
        }
        return $qb->executeQuery()->fetchAllAssociative();
    }

    /**
     * Hoechste in meta abgelegte Schema-Version des DB-Vertrags.
     * null = Spalte fehlt oder ist leer (Legacy-Ingestion vor der Versionierung) --
     * wird als kompatibel behandelt, nur eine NEUERE Version als SCHEMA_VERSION
     * ist ein harter Fehler (siehe DashboardController::assertSchemaCompatible()).
     */
    public function schemaVersion(): ?int
    {
        try {
            $qb = $this->qb('meta');
            $value = $qb->addSelectLiteral('MAX(schema_version)')->from('meta')
                ->executeQuery()->fetchOne();
            return $value === null ? null : (int)$value;
        } catch (\Throwable) {
            return null; // Spalte existiert nicht: Bestands-DB einer aelteren Ingestion
        }
    }

    /**
     * @return array<string,mixed>
     */
    public function meta(int $siteId): array
    {
        $qb = $this->qb('meta');
        $row = $qb->select('*')->from('meta')
            ->where($qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)))
            ->setMaxResults(1)->executeQuery()->fetchAssociative();
        return $row ?: [];
    }

    /**
     * Tages-Aggregate, auf das Zeitfenster [$from, $bis] begrenzt (serverseitig).
     * Begrenzt das Transfervolumen unabhaengig von der Retention der Cube-DB.
     *
     * @return list<array<string,mixed>>
     */
    public function daily(int $siteId, string $from, string $bis): array
    {
        return $this->cached("daily:$siteId:$from:$bis", function () use ($siteId, $from, $bis) {
            $qb = $this->qb('daily');
            return $qb->select('datum', 'visits', 'pageviews', 'uniques', 'bounces', 'bytes')
                ->from('daily')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                )
                ->orderBy('datum')
                ->executeQuery()->fetchAllAssociative();
        });
    }

    /**
     * Cube-Zeilen, auf das Zeitfenster [$from, $bis] begrenzt (serverseitig).
     * $excludeDims: Dimensionen, die NICHT komplett mitgeliefert werden (siehe TopNDims) --
     * fuer die liefert stattdessen topN() nur die Top-N-Zeilen, um das Transfervolumen bei
     * hoher Kardinalitaet zu begrenzen.
     *
     * @param list<string> $excludeDims
     * @return list<array<string,mixed>>
     */
    public function cube(int $siteId, string $from, string $bis, array $excludeDims = []): array
    {
        $excludeKey = $excludeDims === [] ? '' : ':ex=' . implode(',', $excludeDims);
        return $this->cached("cube:$siteId:$from:$bis$excludeKey", function () use ($siteId, $from, $bis, $excludeDims) {
            $qb = $this->qb('cube');
            $qb->select('datum', 'dim', 'dimkey', 'pv', 'v')
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                );
            if ($excludeDims !== []) {
                $qb->andWhere($qb->expr()->notIn(
                    'dim',
                    $qb->createNamedParameter($excludeDims, ArrayParameterType::STRING)
                ));
            }
            return $qb->executeQuery()->fetchAllAssociative();
        });
    }

    /**
     * Beschraenkt eine Cube-Query auf Zeilen, deren dimkey mit "$parentKey . CHILD_SEP"
     * beginnt (Drill-down: Kind-Zeilen einer Eltern-Kategorie). $parentKey ist ein
     * gebundener Parameter (kein Injection-Risiko); nur die per PHP berechnete Praefix-
     * LAENGE wird als Literal in die Query eingebettet. SUBSTR() zaehlt sowohl bei MySQL/
     * MariaDB (nicht-binaere Spalten) als auch bei SQLite Unicode-Codepoints, daher
     * mb_strlen() statt strlen() -- sonst wuerden mehrbyte-UTF-8-Labels falsch abgeschnitten.
     */
    private function applyParentPrefix(QueryBuilder $qb, ?string $parentKey): void
    {
        if ($parentKey === null) {
            return;
        }
        $prefix = $parentKey . self::CHILD_SEP;
        // Kein $qb->expr()->eq() hier: das quotet sein erstes Argument als Identifier
        // (Connection::quoteIdentifier()), was den SUBSTR(...)-Ausdruck kaputt macht.
        // andWhere() akzeptiert rohe SQL-Fragmente direkt.
        $qb->andWhere(
            'SUBSTR(dimkey, 1, ' . mb_strlen($prefix, 'UTF-8') . ') = ' . $qb->createNamedParameter($prefix)
        );
    }

    /**
     * Top-N-Zeilen einer Dimension, absteigend nach $metric ('pv' oder 'v') sortiert.
     * Fuer serverseitiges Top-N + Nachladen bei hochkardinalen Dimensionen (siehe
     * TopNDims/ROADMAP.md). $parentKey: wenn gesetzt, nur Kind-Zeilen dieser Eltern-Kategorie
     * (Drill-down, dimkey-Praefix vor CHILD_SEP) -- siehe applyParentPrefix().
     *
     * @return list<array{dimkey: string, pv: int, v: int}>
     */
    public function topN(int $siteId, string $from, string $bis, string $dim, string $metric, int $limit, int $offset = 0, ?string $parentKey = null): array
    {
        if (!in_array($metric, ['pv', 'v'], true)) {
            throw new \InvalidArgumentException('Ungueltige Metrik: ' . $metric);
        }
        $cacheKey = "topN:$siteId:$from:$bis:$dim:$metric:$limit:$offset:" . ($parentKey ?? '');
        return $this->cached($cacheKey, function () use ($siteId, $from, $bis, $dim, $metric, $limit, $offset, $parentKey) {
            $qb = $this->qb('cube');
            $qb->select('dimkey')
                ->addSelectLiteral('SUM(pv) AS pv', 'SUM(v) AS v')
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->eq('dim', $qb->createNamedParameter($dim)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                    // Leere Keys nicht anzeigen (frueher client-seitig in agg() gefiltert);
                    // '<>' schliesst NULL-dimkeys gleich mit aus.
                    $qb->expr()->neq('dimkey', $qb->createNamedParameter('')),
                );
            $this->applyParentPrefix($qb, $parentKey);
            $rows = $qb->groupBy('dimkey')
                ->orderBy($metric, 'DESC')
                ->setMaxResults($limit)
                ->setFirstResult($offset)
                ->executeQuery()->fetchAllAssociative();
            // mysqli liefert Aggregat-Summen als String -- fuer einen sauberen JSON-Vertrag
            // (Client rechnet mit Zahlen) hier explizit casten.
            return array_map(static fn(array $r): array => [
                'dimkey' => (string)$r['dimkey'],
                'pv' => (int)$r['pv'],
                'v' => (int)$r['v'],
            ], $rows);
        });
    }

    /**
     * Gesamtsumme + Anzahl unterschiedlicher dimkeys einer Dimension (optional unter einem
     * $parentKey-Praefix) im Zeitfenster -- Basis fuer die Prozentanzeige und "+ N weitere"
     * bei serverseitigem Top-N.
     *
     * @return array{pv: int, v: int, count: int}
     */
    public function dimSummary(int $siteId, string $from, string $bis, string $dim, ?string $parentKey = null): array
    {
        $cacheKey = "dimSummary:$siteId:$from:$bis:$dim:" . ($parentKey ?? '');
        return $this->cached($cacheKey, function () use ($siteId, $from, $bis, $dim, $parentKey) {
            $qb = $this->qb('cube');
            $qb->addSelectLiteral(
                'COALESCE(SUM(pv), 0) AS pv',
                'COALESCE(SUM(v), 0) AS v',
                'COUNT(DISTINCT dimkey) AS cnt'
            )
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->eq('dim', $qb->createNamedParameter($dim)),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                    // Konsistent zu topN(): leere Keys zaehlen weder in die Prozentbasis
                    // noch in "+ N weitere".
                    $qb->expr()->neq('dimkey', $qb->createNamedParameter('')),
                );
            $this->applyParentPrefix($qb, $parentKey);
            $row = $qb->executeQuery()->fetchAssociative();
            return [
                'pv' => (int)($row['pv'] ?? 0),
                'v' => (int)($row['v'] ?? 0),
                'count' => (int)($row['cnt'] ?? 0),
            ];
        });
    }

    /**
     * Direkte Kind-Segmente eines Pfad-Praefixes im Seitenbaum ('url'-Dimension), mit
     * Unterbaum-Summen. $path = '' (Wurzel) oder '/seg(/seg)*'. Pro Segment werden alle
     * Zeilen aggregiert, deren dimkey unterhalb von "$path/" liegt — die Summe eines
     * Segments enthaelt damit sowohl die Seite selbst (z. B. '/a/b') als auch alle
     * tieferen Pfade ('/a/b/c'), identisch zur frueheren client-seitigen buildTree()-
     * Aggregation. 'hasChildren' zeigt an, ob unterhalb des Segments weitere Ebenen
     * existieren (fuers Aufklappen im Frontend).
     *
     * Portables SQL: SUBSTR/INSTR/CASE existieren in MariaDB/MySQL und SQLite; die
     * Segment-Extraktion laeuft komplett in SQL, damit an der Wurzel grosser Sites nicht
     * alle URL-Zeilen uebertragen werden muessen. SUBSTR zaehlt Unicode-Codepoints
     * (siehe applyParentPrefix), daher mb_strlen() fuer die Praefix-Laenge.
     *
     * @return array{
     *   rows: list<array{seg: string, path: string, pv: int, v: int, hasChildren: bool}>,
     *   total: array{count: int}
     * }
     */
    public function urlTreeChildren(int $siteId, string $from, string $bis, string $path, int $limit, int $offset = 0): array
    {
        $cacheKey = "urlTree:$siteId:$from:$bis:$limit:$offset:$path";
        return $this->cached($cacheKey, function () use ($siteId, $from, $bis, $path, $limit, $offset) {
            $prefix = $path . '/';
            $plen = mb_strlen($prefix, 'UTF-8');
            // Pfadrest hinter dem Praefix; daraus das erste Segment (bis zum naechsten '/').
            $rest = 'SUBSTR(dimkey, ' . ($plen + 1) . ')';
            $seg = "CASE WHEN INSTR($rest, '/') > 0 THEN SUBSTR($rest, 1, INSTR($rest, '/') - 1) ELSE $rest END";
            // Kind-Ebenen vorhanden? Nur wenn hinter dem '/' auch noch etwas kommt
            // (schuetzt vor Pseudo-Kindern durch trailing slashes wie '/a/').
            $hasChildren = "MAX(CASE WHEN INSTR($rest, '/') > 0 AND SUBSTR($rest, INSTR($rest, '/') + 1) <> '' THEN 1 ELSE 0 END)";

            $qb = $this->qb('cube');
            $qb->addSelectLiteral("$seg AS seg", 'SUM(pv) AS pv', 'SUM(v) AS v', "$hasChildren AS has_children")
                ->from('cube')
                ->where(
                    $qb->expr()->eq('site_id', $qb->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qb->expr()->eq('dim', $qb->createNamedParameter('url')),
                    $qb->expr()->gte('datum', $qb->createNamedParameter($from)),
                    $qb->expr()->lte('datum', $qb->createNamedParameter($bis)),
                )
                // Praefix-Filter wie applyParentPrefix (rohes Fragment, expr()->eq()
                // wuerde den SUBSTR-Ausdruck als Identifier quoten).
                ->andWhere("SUBSTR(dimkey, 1, $plen) = " . $qb->createNamedParameter($prefix))
                ->groupBy('seg')
                ->having("seg <> ''")
                ->orderBy('pv', 'DESC')
                ->setMaxResults($limit)
                ->setFirstResult($offset);
            $rows = array_map(static fn(array $r): array => [
                'seg' => (string)$r['seg'],
                'path' => $path . '/' . (string)$r['seg'],
                'pv' => (int)$r['pv'],
                'v' => (int)$r['v'],
                'hasChildren' => (bool)$r['has_children'],
            ], $qb->executeQuery()->fetchAllAssociative());

            // Gesamtzahl unterschiedlicher Segmente (fuer "+ N weitere"); CASE ohne ELSE
            // liefert NULL fuer leere Segmente -> COUNT DISTINCT zaehlt sie nicht mit.
            $qbCount = $this->qb('cube');
            $qbCount->addSelectLiteral("COUNT(DISTINCT CASE WHEN $seg <> '' THEN $seg END) AS cnt")
                ->from('cube')
                ->where(
                    $qbCount->expr()->eq('site_id', $qbCount->createNamedParameter($siteId, ParameterType::INTEGER)),
                    $qbCount->expr()->eq('dim', $qbCount->createNamedParameter('url')),
                    $qbCount->expr()->gte('datum', $qbCount->createNamedParameter($from)),
                    $qbCount->expr()->lte('datum', $qbCount->createNamedParameter($bis)),
                )
                ->andWhere("SUBSTR(dimkey, 1, $plen) = " . $qbCount->createNamedParameter($prefix));
            $count = (int)$qbCount->executeQuery()->fetchOne();

            return ['rows' => $rows, 'total' => ['count' => $count]];
        });
    }

    /**
     * Seitenbaum bis $depth Ebenen tief (1 oder 2). Bei depth=2 wird fuer jedes Kind der
     * ersten Ebene direkt dessen Kind-Ebene mitgeladen ('children'/'childTotal') — der
     * Initial-Payload zeigt so wie bisher die ersten beiden Ebenen ohne Nachladen.
     *
     * @return array{rows: list<array<string,mixed>>, total: array{count: int}}
     */
    public function urlTree(int $siteId, string $from, string $bis, string $path, int $depth, int $limit, int $offset = 0): array
    {
        $level = $this->urlTreeChildren($siteId, $from, $bis, $path, $limit, $offset);
        if ($depth >= 2) {
            foreach ($level['rows'] as $i => $row) {
                if (!$row['hasChildren']) {
                    continue;
                }
                $child = $this->urlTreeChildren($siteId, $from, $bis, $row['path'], $limit);
                $level['rows'][$i]['children'] = $child['rows'];
                $level['rows'][$i]['childTotal'] = $child['total'];
            }
        }
        return $level;
    }
}
