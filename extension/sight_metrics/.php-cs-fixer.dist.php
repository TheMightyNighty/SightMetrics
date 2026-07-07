<?php
// Code style per TYPO3 Coding Standards.
$config = \TYPO3\CodingStandards\CsFixerConfig::create();
$config->getFinder()->in([__DIR__ . '/Classes']);
return $config;
