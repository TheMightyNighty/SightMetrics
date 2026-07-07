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
 * Ajax endpoint for the page tree ('url' dimension): lazy-loads the direct child
 * segments of a path prefix (expanding a branch, "+ N more", date change).
 * Registered in Configuration/Backend/AjaxRoutes.php (inherits the module permission).
 */
final class TreeAjaxController implements LoggerAwareInterface
{
    use LoggerAwareTrait;

    public function __construct(
        private readonly CubeRepository $cubeRepository,
        private readonly SiteFinder $siteFinder,
    ) {}

    public function handleRequest(ServerRequestInterface $request): ResponseInterface
    {
        $params = $request->getQueryParams();

        // Path prefix: '' = root, otherwise '/seg(/seg)*' without trailing slash and without
        // empty segments. Length capped (dimkey is finite-length anyway).
        $path = Params::toString($params['path'] ?? null);
        if ($path !== '' && (mb_strlen($path) > 2000 || preg_match('#^(/[^/]+)+$#', $path) !== 1)) {
            return new JsonResponse(['error' => 'ungueltiger Pfad'], 400);
        }

        $siteId = Params::toInt($params['site'] ?? null);
        if (($deny = AjaxSiteGuard::denyResponse($this->siteFinder, $siteId)) !== null) {
            return $deny;
        }

        $from = WindowResolver::iso(Params::toStringOrNull($params['from'] ?? null));
        $to = WindowResolver::iso(Params::toStringOrNull($params['to'] ?? null));
        if ($from === null || $to === null) {
            return new JsonResponse(['error' => 'ungueltiger Zeitraum'], 400);
        }

        $depth = Params::toInt($params['depth'] ?? null, 1) === 2 ? 2 : 1;
        $limit = max(1, min(100, Params::toInt($params['limit'] ?? null, TopNDims::DEFAULT_LIMIT)));
        $offset = max(0, min(10000, Params::toInt($params['offset'] ?? null)));

        try {
            $tree = $this->cubeRepository->urlTree($siteId, $from, $to, $path, $depth, $limit, $offset);
        } catch (\Throwable $e) {
            $this->logger?->error('SightMetrics: Seitenbaum-Ajax fehlgeschlagen', [
                'exception' => $e, 'path' => $path, 'siteId' => $siteId,
            ]);
            return new JsonResponse(['error' => 'Abfrage fehlgeschlagen'], 500);
        }

        return new JsonResponse($tree);
    }
}
