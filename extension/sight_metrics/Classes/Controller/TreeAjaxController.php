<?php

declare(strict_types=1);

namespace SightMetrics\Controller;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Log\LoggerAwareInterface;
use Psr\Log\LoggerAwareTrait;
use SightMetrics\Domain\Repository\CubeRepository;
use SightMetrics\Support\AjaxSiteGuard;
use SightMetrics\Support\TopNDims;
use SightMetrics\Support\WindowResolver;
use TYPO3\CMS\Core\Http\JsonResponse;
use TYPO3\CMS\Core\Site\SiteFinder;

/**
 * Ajax-Endpunkt fuer den Seitenbaum ('url'-Dimension): laedt die direkten Kind-Segmente
 * eines Pfad-Praefixes nach (Aufklappen eines Astes, "+ N weitere", Datumswechsel).
 * Registriert in Configuration/Backend/AjaxRoutes.php (erbt die Modul-Berechtigung).
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

        // Pfad-Praefix: '' = Wurzel, sonst '/seg(/seg)*' ohne trailing slash und ohne
        // leere Segmente. Laenge gedeckelt (dimkey ist ohnehin endlich lang).
        $path = (string)($params['path'] ?? '');
        if ($path !== '' && (mb_strlen($path) > 2000 || !preg_match('#^(/[^/]+)+$#', $path))) {
            return new JsonResponse(['error' => 'ungueltiger Pfad'], 400);
        }

        $siteId = (int)($params['site'] ?? 0);
        if (($deny = AjaxSiteGuard::denyResponse($this->siteFinder, $siteId)) !== null) {
            return $deny;
        }

        $from = WindowResolver::iso(isset($params['from']) ? (string)$params['from'] : null);
        $to = WindowResolver::iso(isset($params['to']) ? (string)$params['to'] : null);
        if ($from === null || $to === null) {
            return new JsonResponse(['error' => 'ungueltiger Zeitraum'], 400);
        }

        $depth = (int)($params['depth'] ?? 1) === 2 ? 2 : 1;
        $limit = max(1, min(100, (int)($params['limit'] ?? TopNDims::DEFAULT_LIMIT)));
        $offset = max(0, min(10000, (int)($params['offset'] ?? 0)));

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
