<?php

declare(strict_types=1);

namespace SightMetrics\Controller;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
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
 * Pipeline schon erledigt - hier passiert nur SELECT + Rendering.
 */
final class DashboardController
{
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
        }

        // Fehlerfall: konfigurierbare Fehlerseite rendern (kein Dashboard/keine Assets).
        if ($technical !== null) {
            $conf = [];
            try {
                $conf = $this->extensionConfiguration->get('sight_metrics');
            } catch (\Throwable) {
            }
            $view->assign('error', ErrorPage::resolve($conf, $technical));
            return $view->renderResponse('Dashboard/Index');
        }

        // Erfolgsfall: Daten als CSP-sicherer JSON-Datenblock + Assets.
        $json = json_encode(
            $payload,
            JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT
        );
        $this->pageRenderer->addCssFile('EXT:sight_metrics/Resources/Public/Css/dashboard.css');
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/Vendor/echarts.min.js');
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
