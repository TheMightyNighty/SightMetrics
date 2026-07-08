<?php

declare(strict_types=1);

namespace SightMetrics\Controller;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Log\LoggerAwareInterface;
use Psr\Log\LoggerAwareTrait;
use SightMetrics\Domain\Repository\CubeRepository;
use SightMetrics\Support\ErrorPage;
use SightMetrics\Support\Params;
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
 * Backend module "SightMetrics".
 *
 * Reads exclusively (read-only) from the cube DB and passes the data through as
 * JSON to the frontend (dashboard.js: Chart.js + Leaflet). The DuckDB pipeline
 * already did the expensive aggregation -- only SELECT + rendering happens
 * here.
 */
final class DashboardController implements LoggerAwareInterface
{
    use LoggerAwareTrait;

    private const LL = 'LLL:EXT:sight_metrics/Resources/Private/Language/locallang_mod.xlf:';

    /**
     * Label keys that dashboard.js needs (prefix js. in locallang_mod.xlf).
     * Resolved server-side and put into the JSON payload as a 'lang' map --
     * the JS stays free of TYPO3 APIs and falls back to English without the map.
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
        // Always load CSS: error/onboarding/no-access pages are also styled via
        // classes (no inline style attributes) -- this way the module works
        // without style-src 'unsafe-inline' (CSP hardening).
        $this->pageRenderer->addCssFile('EXT:sight_metrics/Resources/Public/Css/dashboard.css');

        $technical = null;
        $noAccess = false;
        $payload = ['meta' => new \stdClass(), 'daily' => [], 'cube' => [], 'sites' => [], 'siteId' => 0, 'window' => null];
        try {
            $params = $request->getQueryParams();
            // null = no site mapping configured -> unfiltered (backward compatibility).
            // [] = mappings exist, user may see nothing -> empty site list
            // (NOT unfiltered, otherwise tenant-separation bypass, see SiteSelector).
            $allowedIds = SiteSelector::allowedSiteIds($this->siteFinder, $this->beUser());
            $noAccess = ($allowedIds === []);
            $sites = $noAccess ? [] : $this->cubeRepository->sites($allowedIds ?? []);
            // Empty cube (onboarding) has no version to check yet.
            if ($sites !== []) {
                $this->assertSchemaCompatible();
            }
            $siteId = SiteSelector::resolve($sites, Params::toInt($params['site'] ?? null));
            // Empty site list (no access or cube empty): don't query meta(0),
            // so a cube with an actual site_id of 0 doesn't leak through anyway.
            $meta = $sites === [] ? [] : $this->cubeRepository->meta($siteId);

            // Server-side time window: only this window is read from the cube,
            // so the transfer volume doesn't grow with the retention.
            [$from, $bis] = WindowResolver::resolve(
                Params::toStringOrNull($meta['von'] ?? null),
                Params::toStringOrNull($meta['bis'] ?? null),
                $this->windowDays(),
                Params::toStringOrNull($params['from'] ?? null),
                Params::toStringOrNull($params['to'] ?? null),
            );

            // Root dims (see TopNDims): Top-N is preloaded. Child dims (drill-down,
            // e.g. browser_version) are NEVER in the initial payload -- these are only
            // fetched via Ajax lazy-loading (parentKey) when the user expands a row.
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
                // Page tree: 2 levels upfront (first level expanded + its children
                // visible, like the earlier client-side setup); deeper levels are
                // lazy-loaded by dashboard.js via the tree Ajax route on expand.
                'tree' => $this->cubeRepository->urlTree($siteId, $from, $bis, '', 2, TopNDims::DEFAULT_LIMIT),
                // AJAX routes are automatically prefixed by TYPO3 with "ajax_"
                // (see Configuration/Backend/AjaxRoutes.php, AbstractServiceProvider).
                'topNUrl' => (string)$this->uriBuilder->buildUriFromRoute('ajax_sightmetrics_topn'),
                'treeUrl' => (string)$this->uriBuilder->buildUriFromRoute('ajax_sightmetrics_tree'),
                'sites' => $sites,
                'siteId' => $siteId,
                'window' => ['von' => $from, 'bis' => $bis],
                // Bucketing timezone of the ingestion (meta.tz, SCHEMA v2):
                // the frontend anchors "today" for relative presets in this zone.
                'tz' => Params::toString($meta['tz'] ?? null, 'UTC'),
                // UI language of the backend user: label map + locale (number format,
                // Intl.DisplayNames country names) for dashboard.js.
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

        // Error case: render the configurable error page (no dashboard/no assets).
        if ($technical !== null) {
            $conf = [];
            try {
                $raw = $this->extensionConfiguration->get('sight_metrics');
                $conf = \is_array($raw) ? $raw : [];
            } catch (\Throwable) {
            }
            // Technical message (may contain DB host/user/paths) only to admins,
            // even if showTechnical is enabled for all module users.
            $beUser = $GLOBALS['BE_USER'] ?? null;
            $isAdmin = $beUser instanceof BackendUserAuthentication && $beUser->isAdmin();
            $view->assign('error', ErrorPage::resolve($conf, $technical, $isAdmin));
            return $view->renderResponse('Dashboard/Index');
        }

        // Empty site list but no error: instead of an empty dashboard, render a
        // guided page -- either "no access" (mappings exist, user has no
        // webmount) or onboarding (cube DB still without data, typically:
        // extension installed, ingestion not yet set up).
        if ($payload['sites'] === []) {
            $view->assign('error', null);
            $view->assign('noAccess', $noAccess);
            $view->assign('onboarding', !$noAccess);
            return $view->renderResponse('Dashboard/Index');
        }

        // Success case: data as a CSP-safe JSON data block + assets.
        // JSON_INVALID_UTF8_SUBSTITUTE: url/referrer/ua come raw from webserver logs
        // and can contain invalid UTF-8 bytes (e.g. bots); without this flag
        // json_encode() returns false, outside the try/catch above.
        $json = json_encode(
            $payload,
            JSON_UNESCAPED_UNICODE | JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT
                | JSON_INVALID_UTF8_SUBSTITUTE
        );
        if ($json === false) {
            $this->logger?->error('SightMetrics: JSON-Encoding fehlgeschlagen', ['jsonError' => json_last_error_msg()]);
            // conf=[] -> showTechnical doesn't apply here anyway, isAdmin value therefore irrelevant.
            $view->assign('error', ErrorPage::resolve([], 'JSON-Encoding fehlgeschlagen: ' . json_last_error_msg(), false));
            return $view->renderResponse('Dashboard/Index');
        }
        $this->pageRenderer->addCssFile('EXT:sight_metrics/Resources/Public/Vendor/leaflet.css');
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/Vendor/chart.umd.min.js');
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/Vendor/leaflet.js');
        $this->pageRenderer->addJsFooterFile('EXT:sight_metrics/Resources/Public/Vendor/world.js');
        // Dashboard as a native ES module (Configuration/JavaScriptModules.php);
        // modules are deferred and thus run AFTER the classic vendor scripts
        // above -- Chart/L/SM_WORLD are available as globals when the module starts.
        $this->pageRenderer->loadJavaScriptModule('@sightmetrics/dashboard.js');

        $view->assign('payload', $json);
        $view->assign('error', null);
        return $view->renderResponse('Dashboard/Index');
    }

    /**
     * Backend user from the global TYPO3 context. If missing (should practically never
     * happen in the backend module context), this is treated as an error instead of
     * silently assuming "no access" or "full access" -- ends up in the existing catch
     * block including logging and error page.
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
     * Check the DB contract (docs/SCHEMA.md): if an ingestion writes a NEWER
     * version into the cube DB than this extension understands, abort hard with
     * a clear message (ends up on the error page; details for admins) instead of
     * continuing with cryptic query errors or silently wrong numbers.
     * Older/missing version (legacy) stays compatible.
     */
    private function assertSchemaCompatible(): void
    {
        $found = $this->cubeRepository->schemaVersion();
        if ($found === CubeRepository::SCHEMA_VERSION) {
            return;
        }
        if ($found === null || $found < CubeRepository::SCHEMA_VERSION) {
            throw new \RuntimeException(sprintf(
                'Cube schema version %s found, this extension requires version %d. Run the migration (ingestion/migrations/v1_to_v2.sql) or re-import the logs (see docs/SCHEMA.md).',
                $found === null ? 'none/legacy' : (string)$found,
                CubeRepository::SCHEMA_VERSION
            ));
        }
        throw new \RuntimeException(sprintf(
            'Incompatible cube schema: ingestion writes schema version %d, this extension supports %d. Update the sight_metrics extension (see docs/SCHEMA.md).',
            $found,
            CubeRepository::SCHEMA_VERSION
        ));
    }

    /**
     * Resolves the js.*-labels in the backend user's language. Fault-tolerant:
     * without a language service (tests) the map stays empty, dashboard.js then
     * uses its English fallbacks.
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
     * Language/locale identifier of the backend user (e.g. 'de'), 'en' as fallback --
     * for toLocaleString()/Intl.DisplayNames in the frontend.
     */
    private function beUserLocale(): string
    {
        try {
            $lang = Params::toString($this->beUser()->user['lang'] ?? null);
        } catch (\Throwable) {
            $lang = '';
        }
        return $lang !== '' && $lang !== 'default' ? $lang : 'en';
    }

    /**
     * Default time window in days from the extension configuration (default 92 ~ 3 months).
     * 0 = unbounded (load the entire dataset).
     */
    private function windowDays(): int
    {
        try {
            $conf = $this->extensionConfiguration->get('sight_metrics');
            if (\is_array($conf) && isset($conf['windowDays']) && $conf['windowDays'] !== '') {
                return max(0, Params::toInt($conf['windowDays']));
            }
        } catch (\Throwable) {
        }
        return 92;
    }
}
