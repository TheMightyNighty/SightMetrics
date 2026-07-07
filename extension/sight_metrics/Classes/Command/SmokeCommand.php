<?php

declare(strict_types=1);

namespace SightMetrics\Command;

use SightMetrics\Domain\Repository\CubeRepository;
use SightMetrics\Support\Params;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Functional smoke test: checks the real read-only DBAL read path against the cube DB.
 * Usage: vendor/bin/typo3 sightmetrics:smoke  (exit 0 = OK, 1 = error)
 */
#[AsCommand(name: 'sightmetrics:smoke', description: 'Functional Smoke: liest read-only aus der Cube-DB')]
final class SmokeCommand extends Command
{
    public function __construct(private readonly CubeRepository $repo)
    {
        parent::__construct();
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        try {
            $sites = $this->repo->sites();
            $siteId = Params::toInt($sites[0]['site_id'] ?? null);
            $meta = $this->repo->meta($siteId);
            $von = Params::toString($meta['von'] ?? null, '0000-01-01');
            $bis = Params::toString($meta['bis'] ?? null, '9999-12-31');
            $daily = $this->repo->daily($siteId, $von, $bis);
            $cube = $this->repo->cube($siteId, $von, $bis);
        } catch (\Throwable $e) {
            $output->writeln('<error>SMOKE FAIL: ' . $e->getMessage() . '</error>');
            return Command::FAILURE;
        }
        $output->writeln(sprintf(
            'sites=%d | site#%d %s | meta.visits_total=%s | daily=%d | cube=%d',
            count($sites),
            $siteId,
            Params::toString($meta['site'] ?? null, '?'),
            Params::toString($meta['visits_total'] ?? null, 'NULL'),
            count($daily),
            count($cube)
        ));

        $ok = count($sites) > 0 && Params::toInt($meta['visits_total'] ?? null) > 0
            && count($daily) > 0 && count($cube) > 0;
        if (!$ok) {
            $output->writeln('<error>SMOKE FAIL: Cube leer oder nicht lesbar</error>');
            return Command::FAILURE;
        }
        $output->writeln('<info>SMOKE OK</info>');
        return Command::SUCCESS;
    }
}
