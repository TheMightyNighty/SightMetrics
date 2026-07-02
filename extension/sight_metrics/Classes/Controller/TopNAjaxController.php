<?php

declare(strict_types=1);

namespace SightMetrics\Controller;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Log\LoggerAwareInterface;
use Psr\Log\LoggerAwareTrait;
use SightMetrics\Domain\Repository\CubeRepository;
use SightMetrics\Support\SiteSelector;
use SightMetrics\Support\TopNDims;
use TYPO3\CMS\Core\Authentication\BackendUserAuthentication;
use TYPO3\CMS\Core\Http\JsonResponse;
use TYPO3\CMS\Core\Site\SiteFinder;

/**
 * Ajax-Endpunkt fuers Nachladen (initiale Datumsaenderung + "+ N weitere") der
 * serverseitig auf Top-N begrenzten Barlisten (siehe TopNDims/ROADMAP.md). Registriert in
 * Configuration/Backend/AjaxRoutes.php, daher automatisch CSRF-Token-geschuetzt
 * (UriBuilder::buildUriFromRoute() haengt den Token an, sofern access != 'public').
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
        $dim = (string)($params['dim'] ?? '');
        if (!isset(TopNDims::METRIC_BY_DIM[$dim])) {
            return new JsonResponse(['error' => 'unbekannte Dimension'], 400);
        }

        $beUser = $GLOBALS['BE_USER'] ?? null;
        if (!$beUser instanceof BackendUserAuthentication) {
            return new JsonResponse(['error' => 'kein Backend-Benutzer'], 403);
        }

        $siteId = (int)($params['site'] ?? 0);
        // Gleiche Pruefung wie DashboardController: leere Liste = kein Filter
        // (Rueckwaertskompatibilitaet), sonst muss $siteId in der erlaubten Menge sein.
        $allowedIds = SiteSelector::allowedSiteIds($this->siteFinder, $beUser);
        if ($allowedIds !== [] && !in_array($siteId, $allowedIds, true)) {
            return new JsonResponse(['error' => 'kein Zugriff auf diese Site'], 403);
        }

        $from = (string)($params['from'] ?? '');
        $to = (string)($params['to'] ?? '');
        if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $from) || !preg_match('/^\d{4}-\d{2}-\d{2}$/', $to)) {
            return new JsonResponse(['error' => 'ungueltiger Zeitraum'], 400);
        }

        $limit = max(1, min(100, (int)($params['limit'] ?? TopNDims::DEFAULT_LIMIT)));
        $offset = max(0, (int)($params['offset'] ?? 0));
        $metric = TopNDims::METRIC_BY_DIM[$dim];

        try {
            $rows = $this->cubeRepository->topN($siteId, $from, $to, $dim, $metric, $limit, $offset);
            $total = $this->cubeRepository->dimSummary($siteId, $from, $to, $dim);
        } catch (\Throwable $e) {
            $this->logger?->error('SightMetrics: Top-N-Ajax fehlgeschlagen', [
                'exception' => $e, 'dim' => $dim, 'siteId' => $siteId,
            ]);
            return new JsonResponse(['error' => 'Abfrage fehlgeschlagen'], 500);
        }

        return new JsonResponse(['rows' => $rows, 'total' => $total]);
    }
}
