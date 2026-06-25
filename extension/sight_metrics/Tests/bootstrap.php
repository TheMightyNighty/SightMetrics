<?php
// Leichter PSR-4-Autoloader (ohne TYPO3) fuer die Unit-Tests.
spl_autoload_register(static function (string $class): void {
    $prefix = 'SightMetrics\\';
    if (strncmp($class, $prefix, strlen($prefix)) !== 0) {
        return;
    }
    $rel = substr($class, strlen($prefix));
    if (strncmp($rel, 'Tests\\', 6) === 0) {
        $file = __DIR__ . '/' . str_replace('\\', '/', substr($rel, 6)) . '.php';
    } else {
        $file = dirname(__DIR__) . '/Classes/' . str_replace('\\', '/', $rel) . '.php';
    }
    if (is_file($file)) {
        require $file;
    }
});
