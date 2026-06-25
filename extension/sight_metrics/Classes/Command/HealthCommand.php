<?php

declare(strict_types=1);

namespace SightMetrics\Command;

use SightMetrics\Domain\Repository\CubeRepository;
use Symfony\Component\Console\Attribute\AsCommand;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\InputInterface;
use Symfony\Component\Console\Input\InputOption;
use Symfony\Component\Console\Output\OutputInterface;

/**
 * Health-Check des Reporting-Pfads, den die GUI tatsaechlich liest:
 * Cube-DB erreichbar? Daten je Site aktuell (Alter von meta.bis)?
 *
 * Ergaenzt check_import.sh (prueft die Ingestion-State-Dateien) um die Sicht
 * aus dem TYPO3-Backend. Nagios-kompatible Exit-Codes (0=OK,1=WARN,2=CRIT,3=UNKNOWN),
 * optional JSON fuer Monitoring-Agenten.
 *
 * Aufruf: vendor/bin/typo3 sightmetrics:health [--warn-hours=26] [--crit-hours=50] [--json]
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
        $warnH = (int)$input->getOption('warn-hours');
        $critH = (int)$input->getOption('crit-hours');
        $asJson = (bool)$input->getOption('json');

        try {
            $sites = $this->repo->sites();
        } catch (\Throwable $e) {
            return $this->emit($output, $asJson, 2, 'Cube-DB nicht erreichbar: ' . $e->getMessage(), []);
        }

        if ($sites === []) {
            return $this->emit($output, $asJson, 2, 'Keine Sites in der Cube-DB (meta leer)', []);
        }

        $now = time();
        $worst = 0;
        $details = [];
        foreach ($sites as $s) {
            $siteId = (int)$s['site_id'];
            $name = (string)($s['site'] ?? $siteId);
            $meta = $this->repo->meta($siteId);
            $bis = (string)($meta['bis'] ?? '');
            if ($bis === '') {
                $worst = max($worst, 2);
                $details[] = ['site_id' => $siteId, 'site' => $name, 'status' => 'CRIT', 'last_data' => null, 'age_hours' => null];
                continue;
            }
            // Alter ab Ende des letzten Datentags (bis 23:59:59).
            $end = strtotime($bis . ' 23:59:59');
            $ageH = $end ? (int)floor(($now - $end) / 3600) : null;
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
                    (string)$d['site_id'],
                    (string)$d['status'],
                    $d['last_data'] === null ? '-' : (string)$d['last_data'],
                    $d['age_hours'] === null ? '-' : $d['age_hours'] . 'h'
                ));
            }
        }
        return $code;
    }
}
