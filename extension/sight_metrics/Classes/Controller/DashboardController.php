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
use TYPO3\CMS\Core\Page\PageRenderer;
use TYPO3\CMS\Core\Site\SiteFinder;

/**
 * Backend-Modul "SightMetrics".
 *
 * Liest ausschliesslich (read-only) aus der Cube-DB und reicht die Daten als
 * JSON an das Frontend (ECharts) durch. Die teure Aggregation hat die DuckDB-
 * Pipeline schon erledigt – hier passiert nur SELECT + Rendering.
 */
final class DashboardController implements LoggerAwareInterface
{
    use LoggerAwareTrait;

    public function __construct(
        private readonly ModuleTemplateFactory $moduleTemplateFactory,
        private readonly PageRenderer $pageRenderer,
        private readonly CubeRepository $cubeRepository,
        private readonly ExtensionConfiguration $extensionConfiguration,
        private readonly SiteFinder $siteFinder,
        private readonly UriBuilder $uriBuilder,
    ) {}

    public function handleRequest(ServerRequestInterface $request): ResponseInterface
    {
        $view = $this->moduleTemplateFactory->create($request);
        $view->setTitle('SightMetrics');

        $technical = null;
        $payload = ['meta' => new \stdClass(), 'daily' => [], 'cube' => [], 'sites' => [], 'siteId' => 0, 'window' => null];
        try {
            $params = $request->getQueryParams();
            // null = kein Site-Mapping konfiguriert -> filterlos (Rueckwaertskompatibilitaet).
            // [] = Mappings existieren, Benutzer darf nichts sehen -> leere Site-Liste
            // (NICHT filterlos, sonst Mandantentrennungs-Bypass, siehe SiteSelector).
            $allowedIds = SiteSelector::allowedSiteIds($this->siteFinder, $this->beUser());
            $sites = $allowedIds === [] ? [] : $this->cubeRepository->sites($allowedIds ?? []);
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
                // AJAX-Routen werden von TYPO3 automatisch mit "ajax_" praefixiert
                // (siehe Configuration/Backend/AjaxRoutes.php, AbstractServiceProvider).
                'topNUrl' => (string)$this->uriBuilder->buildUriFromRoute('ajax_sightmetrics_topn'),
                'sites' => $sites,
                'siteId' => $siteId,
                'window' => ['von' => $from, 'bis' => $bis],
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
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/JavaScript/dashboard.js');

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
