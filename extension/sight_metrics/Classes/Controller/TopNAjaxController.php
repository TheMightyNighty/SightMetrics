<?php

declare(strict_types=1);

namespace SightMetrics\Controller;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Log\LoggerAwareInterface;
use Psr\Log\LoggerAwareTrait;
use SightMetrics\Domain\Repository\CubeRepository;
use SightMetrics\Support\AjaxSiteGuard;
use SightMetrics\Support\Params;
use SightMetrics\Support\TopNDims;
use SightMetrics\Support\WindowResolver;
use TYPO3\CMS\Core\Http\JsonResponse;
use TYPO3\CMS\Core\Site\SiteFinder;

/**
 * Ajax endpoint for lazy-loading (initial date change + "+ N more") of the
 * server-side Top-N-limited bar lists (see TopNDims/ROADMAP.md). Registered in
 * Configuration/Backend/AjaxRoutes.php, hence automatically CSRF-token-protected
 * (UriBuilder::buildUriFromRoute() appends the token as long as access != 'public').
 */
final class TopNAjaxController implements LoggerAwareInterface
{
    use LoggerAwareTrait;

    public function __construct(
        private readonly CubeRepository $cubeRepository,
        private readonly SiteFinder $siteFinder,
    ) {}

    public function handleRequest(ServerRequestInterface $request): ResponseInterface
    {
        $params = $request->getQueryParams();
        $dim = Params::toString($params['dim'] ?? null);
        // parentKey set -> drill-down lazy-loading (child dim), otherwise root-dim lazy-loading.
        // Separate whitelists: a root dim must not be requested as a child dim and
        // vice versa (referrer_url is deliberately in both, see TopNDims).
        $parentKey = Params::toStringOrNull($params['parentKey'] ?? null);
        $metricMap = $parentKey !== null ? TopNDims::CHILD_METRIC_BY_DIM : TopNDims::ROOT_METRIC_BY_DIM;
        if (!isset($metricMap[$dim])) {
            return new JsonResponse(['error' => 'unbekannte Dimension'], 400);
        }

        $siteId = Params::toInt($params['site'] ?? null);
        if (($deny = AjaxSiteGuard::denyResponse($this->siteFinder, $siteId)) !== null) {
            return $deny;
        }

        // Same date validation as WindowResolver (format + checkdate).
        $from = WindowResolver::iso(Params::toStringOrNull($params['from'] ?? null));
        $to = WindowResolver::iso(Params::toStringOrNull($params['to'] ?? null));
        if ($from === null || $to === null) {
            return new JsonResponse(['error' => 'ungueltiger Zeitraum'], 400);
        }

        $limit = max(1, min(100, Params::toInt($params['limit'] ?? null, TopNDims::DEFAULT_LIMIT)));
        // Cap the offset: deep pagination would mean a full sort over the
        // dimension per page; beyond 10000 rows the UI is no longer useful anyway.
        $offset = max(0, min(10000, Params::toInt($params['offset'] ?? null)));
        $metric = $metricMap[$dim];

        try {
            $rows = $this->cubeRepository->topN($siteId, $from, $to, $dim, $metric, $limit, $offset, $parentKey);
            $total = $this->cubeRepository->dimSummary($siteId, $from, $to, $dim, $parentKey);
        } catch (\Throwable $e) {
            $this->logger?->error('SightMetrics: Top-N-Ajax fehlgeschlagen', [
                'exception' => $e, 'dim' => $dim, 'siteId' => $siteId, 'parentKey' => $parentKey,
            ]);
            return new JsonResponse(['error' => 'Abfrage fehlgeschlagen'], 500);
        }

        return new JsonResponse(['rows' => $rows, 'total' => $total]);
    }
}
