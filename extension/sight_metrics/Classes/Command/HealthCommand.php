<?php

declare(strict_types=1);

namespace SightMetrics\Command;

use SightMetrics\Domain\Repository\CubeRepository;
use SightMetrics\Support\Params;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Health check of the reporting path that the GUI actually reads:
 * Is the cube DB reachable? Is the data per site current (age of meta.bis)?
 *
 * Complements check_import.sh (checks the ingestion state files) with the view
 * from the TYPO3 backend. Nagios-compatible exit codes (0=OK,1=WARN,2=CRIT,3=UNKNOWN),
 * optional JSON for monitoring agents.
 *
 * Usage: vendor/bin/typo3 sightmetrics:health [--warn-hours=26] [--crit-hours=50] [--json]
 */
#[AsCommand(name: 'sightmetrics:health', description: 'Health-Check: Cube-DB erreichbar und Daten aktuell?')]
final class HealthCommand extends Command
{
    public function __construct(private readonly CubeRepository $repo)
    {
        parent::__construct();
    }

    protected function configure(): void
    {
        $this->addOption('warn-hours', null, InputOption::VALUE_REQUIRED, 'Alter ab dem WARNING gemeldet wird', '26');
        $this->addOption('crit-hours', null, InputOption::VALUE_REQUIRED, 'Alter ab dem CRITICAL gemeldet wird', '50');
        $this->addOption('json', null, InputOption::VALUE_NONE, 'Ausgabe als JSON');
    }

    protected function execute(InputInterface $input, OutputInterface $output): int
    {
        $warnH = Params::toInt($input->getOption('warn-hours'), 26);
        $critH = Params::toInt($input->getOption('crit-hours'), 50);
        $asJson = (bool)$input->getOption('json');

        if ($critH < $warnH) {
            return $this->emit(
                $output,
                $asJson,
                3,
                sprintf('Ungueltige Schwellenwerte: --crit-hours (%d) muss >= --warn-hours (%d) sein', $critH, $warnH),
                []
            );
        }

        try {
            $sites = $this->repo->sites();
        } catch (\Throwable $e) {
            return $this->emit($output, $asJson, 2, 'Cube-DB nicht erreichbar: ' . $e->getMessage(), []);
        }

        if ($sites === []) {
            return $this->emit($output, $asJson, 2, 'Keine Sites in der Cube-DB (meta leer)', []);
        }

        // DB contract (docs/SCHEMA.md): report a newer writer version as CRIT
        // before checking freshness -- the numbers would not be trustworthy.
        $schema = $this->repo->schemaVersion();
        if ($schema !== null && $schema > CubeRepository::SCHEMA_VERSION) {
            return $this->emit($output, $asJson, 2, sprintf(
                'Inkompatible Cube-Schema-Version %d (Extension unterstuetzt bis %d) - Extension aktualisieren',
                $schema,
                CubeRepository::SCHEMA_VERSION
            ), []);
        }

        $now = time();
        $worst = 0;
        $details = [];
        foreach ($sites as $s) {
            $siteId = Params::toInt($s['site_id'] ?? null);
            $name = Params::toString($s['site'] ?? null, (string)$siteId);
            $meta = $this->repo->meta($siteId);
            $bis = Params::toString($meta['bis'] ?? null);
            if ($bis === '') {
                $worst = max($worst, 2);
                $details[] = ['site_id' => $siteId, 'site' => $name, 'status' => 'CRIT', 'last_data' => null, 'age_hours' => null];
                continue;
            }
            // Age from the end of the last data day (up to 23:59:59).
            $end = strtotime($bis . ' 23:59:59');
            $ageH = $end !== false ? (int)floor(($now - $end) / 3600) : null;
            $status = 'OK';
            if ($ageH === null) {
                $status = 'UNKNOWN';
                $worst = max($worst, 3);
            } elseif ($ageH >= $critH) {
                $status = 'CRIT';
                $worst = max($worst, 2);
            } elseif ($ageH >= $warnH) {
                $status = 'WARN';
                $worst = max($worst, 1);
            }
            $details[] = ['site_id' => $siteId, 'site' => $name, 'status' => $status, 'last_data' => $bis, 'age_hours' => $ageH];
        }

        $okCount = count(array_filter($details, static fn(array $d): bool => $d['status'] === 'OK'));
        $summary = sprintf('%d/%d Sites aktuell (Schwellen warn=%dh crit=%dh)', $okCount, count($details), $warnH, $critH);
        return $this->emit($output, $asJson, $worst, $summary, $details);
    }

    /**
     * @param list<array<string,mixed>> $details
     */
    private function emit(OutputInterface $output, bool $asJson, int $code, string $summary, array $details): int
    {
        $label = [0 => 'OK', 1 => 'WARNING', 2 => 'CRITICAL', 3 => 'UNKNOWN'][$code] ?? 'UNKNOWN';
        if ($asJson) {
            $output->writeln((string)json_encode(
                ['status' => $label, 'code' => $code, 'summary' => $summary, 'sites' => $details],
                JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES
            ));
        } else {
            $output->writeln($label . ': ' . $summary);
            foreach ($details as $d) {
                $output->writeln(sprintf(
                    '  site=%s %s last_data=%s age=%s',
                    Params::toString($d['site_id'] ?? null),
                    Params::toString($d['status'] ?? null),
                    Params::toStringOrNull($d['last_data'] ?? null) ?? '-',
                    $d['age_hours'] === null ? '-' : Params::toString($d['age_hours']) . 'h'
                ));
            }
        }
        return $code;
    }
}
