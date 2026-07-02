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
use SightMetrics\Support\WindowResolver;
use TYPO3\CMS\Backend\Template\ModuleTemplateFactory;
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
    ) {}

    public function handleRequest(ServerRequestInterface $request): ResponseInterface
    {
        $view = $this->moduleTemplateFactory->create($request);
        $view->setTitle('SightMetrics');

        $technical = null;
        $payload = ['meta' => new \stdClass(), 'daily' => [], 'cube' => [], 'sites' => [], 'siteId' => 0, 'window' => null];
        try {
            $params = $request->getQueryParams();
            $allowedIds = SiteSelector::allowedSiteIds($this->siteFinder);
            $sites = $this->cubeRepository->sites($allowedIds);
            $siteId = SiteSelector::resolve($sites, (int)($params['site'] ?? 0));
            $meta = $this->cubeRepository->meta($siteId);

            // Serverseitiges Zeitfenster: nur dieses Fenster wird aus dem Cube gelesen,
            // damit das Transfervolumen nicht mit der Retention waechst.
            [$from, $bis] = WindowResolver::resolve(
                isset($meta['von']) ? (string)$meta['von'] : null,
                isset($meta['bis']) ? (string)$meta['bis'] : null,
                $this->windowDays(),
                isset($params['from']) ? (string)$params['from'] : null,
                isset($params['to']) ? (string)$params['to'] : null,
            );

            $payload = [
                'meta' => $meta,
                'daily' => $this->cubeRepository->daily($siteId, $from, $bis),
                'cube' => $this->cubeRepository->cube($siteId, $from, $bis),
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
