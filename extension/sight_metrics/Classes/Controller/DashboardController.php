<?php

declare(strict_types=1);

namespace SightMetrics\Controller;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Log\LoggerAwareInterface;
use Psr\Log\LoggerAwareTrait;
use SightMetrics\Domain\Repository\CubeRepository;
use SightMetrics\Support\ErrorPage;
use SightMetrics\Support\SiteSelector;
use SightMetrics\Support\TopNDims;
use SightMetrics\Support\WindowResolver;
use TYPO3\CMS\Backend\Routing\UriBuilder;
use TYPO3\CMS\Backend\Template\ModuleTemplateFactory;
use TYPO3\CMS\Core\Authentication\BackendUserAuthentication;
use TYPO3\CMS\Core\Configuration\ExtensionConfiguration;
use TYPO3\CMS\Core\Localization\LanguageServiceFactory;
use TYPO3\CMS\Core\Page\PageRenderer;
use TYPO3\CMS\Core\Site\SiteFinder;

/**
 * Backend-Modul "SightMetrics".
 *
 * Liest ausschliesslich (read-only) aus der Cube-DB und reicht die Daten als
 * JSON an das Frontend (dashboard.js: Chart.js + Leaflet) durch. Die teure
 * Aggregation hat die DuckDB-Pipeline schon erledigt – hier passiert nur
 * SELECT + Rendering.
 */
final class DashboardController implements LoggerAwareInterface
{
    use LoggerAwareTrait;

    private const LL = 'LLL:EXT:sight_metrics/Resources/Private/Language/locallang_mod.xlf:';

    /**
     * Label-Schluessel, die dashboard.js braucht (Praefix js. in locallang_mod.xlf).
     * Werden serverseitig aufgeloest und als 'lang'-Map in den JSON-Payload gelegt --
     * das JS bleibt frei von TYPO3-APIs und faellt ohne Map auf Englisch zurueck.
     */
    private const JS_LABEL_KEYS = [
        'loading', 'more', 'noData', 'new', 'asOf',
        'visits', 'pageviews', 'uniques', 'pageviewsPrev', 'unknown',
        'ref.direct', 'ref.search', 'ref.social', 'ref.website',
        'csv.website', 'csv.period', 'csv.to', 'csv.daily', 'csv.date', 'csv.bounces',
        'csv.bytes', 'csv.value', 'csv.partial', 'csv.pages', 'csv.path',
        'dim.country', 'dim.browser', 'dim.os', 'dim.device', 'dim.refTypes', 'dim.refUrls',
        'dim.keywords', 'dim.entry', 'dim.exit', 'dim.downloads', 'dim.status', 'dim.methods', 'dim.hours',
        'preset.all', 'preset.window', 'preset.today', 'preset.yesterday',
        'preset.last7', 'preset.last30', 'preset.last90',
        'preset.thisMonth', 'preset.lastMonth', 'preset.thisYear', 'preset.lastYear',
        'preset.year', 'preset.custom',
    ];

    public function __construct(
        private readonly ModuleTemplateFactory $moduleTemplateFactory,
        private readonly PageRenderer $pageRenderer,
        private readonly CubeRepository $cubeRepository,
        private readonly ExtensionConfiguration $extensionConfiguration,
        private readonly SiteFinder $siteFinder,
        private readonly UriBuilder $uriBuilder,
        private readonly LanguageServiceFactory $languageServiceFactory,
    ) {}

    public function handleRequest(ServerRequestInterface $request): ResponseInterface
    {
        $view = $this->moduleTemplateFactory->create($request);
        $view->setTitle('SightMetrics');

        $technical = null;
        $noAccess = false;
        $payload = ['meta' => new \stdClass(), 'daily' => [], 'cube' => [], 'sites' => [], 'siteId' => 0, 'window' => null];
        try {
            $params = $request->getQueryParams();
            // null = kein Site-Mapping konfiguriert -> filterlos (Rueckwaertskompatibilitaet).
            // [] = Mappings existieren, Benutzer darf nichts sehen -> leere Site-Liste
            // (NICHT filterlos, sonst Mandantentrennungs-Bypass, siehe SiteSelector).
            $allowedIds = SiteSelector::allowedSiteIds($this->siteFinder, $this->beUser());
            $noAccess = ($allowedIds === []);
            $sites = $noAccess ? [] : $this->cubeRepository->sites($allowedIds ?? []);
            $this->assertSchemaCompatible();
            $siteId = SiteSelector::resolve($sites, (int)($params['site'] ?? 0));
            // Leere Site-Liste (kein Zugriff oder Cube leer): meta(0) nicht abfragen,
            // damit ein Cube mit tatsaechlicher site_id 0 nicht doch durchsickert.
            $meta = $sites === [] ? [] : $this->cubeRepository->meta($siteId);

            // Serverseitiges Zeitfenster: nur dieses Fenster wird aus dem Cube gelesen,
            // damit das Transfervolumen nicht mit der Retention waechst.
            [$from, $bis] = WindowResolver::resolve(
                isset($meta['von']) ? (string)$meta['von'] : null,
                isset($meta['bis']) ? (string)$meta['bis'] : null,
                $this->windowDays(),
                isset($params['from']) ? (string)$params['from'] : null,
                isset($params['to']) ? (string)$params['to'] : null,
            );

            // Root-Dims (siehe TopNDims): Top-N wird vorab geladen. Kind-Dims (Drill-down,
            // z. B. browser_version) stehen NIE im Initial-Payload -- die werden erst per
            // Ajax-Nachladen (parentKey) geholt, wenn der Nutzer eine Zeile aufklappt.
            $topN = [];
            foreach (TopNDims::ROOT_METRIC_BY_DIM as $dim => $metric) {
                $limit = TopNDims::defaultLimitFor($dim);
                $topN[$dim] = [
                    'metric' => $metric,
                    'limit' => $limit,
                    'rows' => $this->cubeRepository->topN($siteId, $from, $bis, $dim, $metric, $limit),
                    'total' => $this->cubeRepository->dimSummary($siteId, $from, $bis, $dim),
                ];
            }

            $payload = [
                'meta' => $meta,
                'daily' => $this->cubeRepository->daily($siteId, $from, $bis),
                'cube' => $this->cubeRepository->cube($siteId, $from, $bis, TopNDims::excludedFromFullPayload()),
                'topN' => $topN,
                // Seitenbaum: 2 Ebenen vorab (erste Ebene aufgeklappt + deren Kinder
                // sichtbar, wie beim frueheren client-seitigen Aufbau); tiefere Ebenen
                // laedt dashboard.js beim Aufklappen ueber die tree-Ajax-Route nach.
                'tree' => $this->cubeRepository->urlTree($siteId, $from, $bis, '', 2, TopNDims::DEFAULT_LIMIT),
                // AJAX-Routen werden von TYPO3 automatisch mit "ajax_" praefixiert
                // (siehe Configuration/Backend/AjaxRoutes.php, AbstractServiceProvider).
                'topNUrl' => (string)$this->uriBuilder->buildUriFromRoute('ajax_sightmetrics_topn'),
                'treeUrl' => (string)$this->uriBuilder->buildUriFromRoute('ajax_sightmetrics_tree'),
                'sites' => $sites,
                'siteId' => $siteId,
                'window' => ['von' => $from, 'bis' => $bis],
                // UI-Sprache des BE-Benutzers: Label-Map + Locale (Zahlenformat,
                // Intl.DisplayNames-Laendernamen) fuer dashboard.js.
                'lang' => $this->jsLabels(),
                'locale' => $this->beUserLocale(),
            ];
        } catch (\Throwable $e) {
            $technical = $e->getMessage();
            $this->logger?->error('SightMetrics: Dashboard-Aufbau fehlgeschlagen', [
                'exception' => $e,
                'siteParam' => $request->getQueryParams()['site'] ?? null,
            ]);
        }

        // Fehlerfall: konfigurierbare Fehlerseite rendern (kein Dashboard/keine Assets).
        if ($technical !== null) {
            $conf = [];
            try {
                $conf = $this->extensionConfiguration->get('sight_metrics');
            } catch (\Throwable) {
            }
            // Technische Meldung (kann DB-Host/User/Pfade enthalten) nur an Admins,
            // auch wenn showTechnical fuer alle Modul-Nutzer aktiviert ist.
            $isAdmin = ($GLOBALS['BE_USER'] ?? null)?->isAdmin() ?? false;
            $view->assign('error', ErrorPage::resolve($conf, $technical, $isAdmin));
            return $view->renderResponse('Dashboard/Index');
        }

        // Leere Site-Liste, aber kein Fehler: statt eines leeren Dashboards eine
        // gefuehrte Seite rendern -- entweder "kein Zugriff" (Mappings existieren,
        // Benutzer hat keinen Webmount) oder Onboarding (Cube-DB noch ohne Daten,
        // typisch: Extension installiert, Ingestion noch nicht eingerichtet).
        if ($payload['sites'] === []) {
            $view->assign('error', null);
            $view->assign('noAccess', $noAccess);
            $view->assign('onboarding', !$noAccess);
            return $view->renderResponse('Dashboard/Index');
        }

        // Erfolgsfall: Daten als CSP-sicherer JSON-Datenblock + Assets.
        // JSON_INVALID_UTF8_SUBSTITUTE: url/referrer/ua stammen roh aus Webserver-Logs
        // und koennen ungueltige UTF-8-Bytes enthalten (z. B. Bots); ohne dieses Flag
        // liefert json_encode() false, ausserhalb des obigen try/catch.
        $json = json_encode(
            $payload,
            JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT
                | JSON_INVALID_UTF8_SUBSTITUTE
        );
        if ($json === false) {
            $this->logger?->error('SightMetrics: JSON-Encoding fehlgeschlagen', ['jsonError' => json_last_error_msg()]);
            // conf=[] -> showTechnical greift hier ohnehin nicht, isAdmin-Wert daher irrelevant.
            $view->assign('error', ErrorPage::resolve([], 'JSON-Encoding fehlgeschlagen: ' . json_last_error_msg(), false));
            return $view->renderResponse('Dashboard/Index');
        }
        $this->pageRenderer->addCssFile('EXT:sight_metrics/Resources/Public/Css/dashboard.css');
        $this->pageRenderer->addCssFile('EXT:sight_metrics/Resources/Public/Vendor/leaflet.css');
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/Vendor/chart.umd.min.js');
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/Vendor/leaflet.js');
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/Vendor/world.js');
        // Dashboard als natives ES-Modul (Configuration/JavaScriptModules.php);
        // Module sind deferred und laufen daher NACH den klassischen Vendor-Skripten
        // oben -- Chart/L/SM_WORLD sind beim Modulstart als Globals verfuegbar.
        $this->pageRenderer->loadJavaScriptModule('@sightmetrics/dashboard.js');

        $view->assign('payload', $json);
        $view->assign('error', null);
        return $view->renderResponse('Dashboard/Index');
    }

    /**
     * Backend-Benutzer aus dem globalen TYPO3-Kontext. Fehlt er (sollte im Backend-Modul-
     * Kontext praktisch nie vorkommen), wird das als Fehler behandelt statt stillschweigend
     * "kein Zugriff" oder "voller Zugriff" anzunehmen – landet im bestehenden Catch-Block
     * inkl. Logging und Fehlerseite.
     */
    private function beUser(): BackendUserAuthentication
    {
        $beUser = $GLOBALS['BE_USER'] ?? null;
        if (!$beUser instanceof BackendUserAuthentication) {
            throw new \RuntimeException('Kein Backend-Benutzer im Request-Kontext.');
        }
        return $beUser;
    }

    /**
     * DB-Vertrag pruefen (docs/SCHEMA.md): Schreibt eine NEUERE Ingestion in die
     * Cube-DB, als diese Extension versteht, wird hart mit klarer Meldung
     * abgebrochen (landet auf der Fehlerseite; Details fuer Admins) statt mit
     * kryptischen Query-Fehlern oder still falschen Zahlen weiterzulaufen.
     * Aeltere/fehlende Version (Legacy) bleibt kompatibel.
     */
    private function assertSchemaCompatible(): void
    {
        $found = $this->cubeRepository->schemaVersion();
        if ($found !== null && $found > CubeRepository::SCHEMA_VERSION) {
            throw new \RuntimeException(sprintf(
                'Incompatible cube schema: ingestion writes schema version %d, this extension supports up to %d. Update the sight_metrics extension (see docs/SCHEMA.md).',
                $found,
                CubeRepository::SCHEMA_VERSION
            ));
        }
    }

    /**
     * Loest die js.*-Labels in der Sprache des BE-Benutzers auf. Fehlertolerant:
     * ohne Language-Service (Tests) bleibt die Map leer, dashboard.js nutzt dann
     * seine englischen Fallbacks.
     *
     * @return array<string,string>
     */
    private function jsLabels(): array
    {
        $labels = [];
        try {
            $languageService = $this->languageServiceFactory->createFromUserPreferences($this->beUser());
            foreach (self::JS_LABEL_KEYS as $key) {
                $label = $languageService->sL(self::LL . 'js.' . $key);
                if ($label !== '') {
                    $labels[$key] = $label;
                }
            }
        } catch (\Throwable) {
        }
        return $labels;
    }

    /**
     * Sprach-/Locale-Kennung des BE-Benutzers (z. B. 'de'), 'en' als Fallback --
     * fuer toLocaleString()/Intl.DisplayNames im Frontend.
     */
    private function beUserLocale(): string
    {
        try {
            $lang = (string)($this->beUser()->user['lang'] ?? '');
        } catch (\Throwable) {
            $lang = '';
        }
        return $lang !== '' && $lang !== 'default' ? $lang : 'en';
    }

    /**
     * Standard-Zeitfenster in Tagen aus der Extension-Konfiguration (Default 92 ~ 3 Monate).
     * 0 = unbegrenzt (gesamter Datenbestand laden).
     */
    private function windowDays(): int
    {
        try {
            $conf = $this->extensionConfiguration->get('sight_metrics');
            if (isset($conf['windowDays']) && $conf['windowDays'] !== '') {
                return max(0, (int)$conf['windowDays']);
            }
        } catch (\Throwable) {
        }
        return 92;
    }
}
