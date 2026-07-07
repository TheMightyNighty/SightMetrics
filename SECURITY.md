# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| 1.3.x | ✅ |
| < 1.3 | ❌ (please upgrade) |

Supported platform range: TYPO3 13.4 LTS / 14, PHP 8.2–8.4 (see
`extension/sight_metrics/composer.json`).

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security problems.

- Preferred: [GitHub private vulnerability reporting](https://github.com/TheMIghtyNighty/SightMetrics/security/advisories/new)
- Alternatively by e-mail: robert.schleiermacher@gmail.com (subject prefix `[SECURITY]`)

Please include: affected component (TYPO3 extension `sight_metrics` or the
ingestion pipeline), version/commit, reproduction steps, and impact assessment.
You can expect an initial response within 7 days. Coordinated disclosure is
appreciated; credit is given in the changelog unless you prefer otherwise.

For vulnerabilities in the published TYPO3 extension, the
[TYPO3 Security Team](https://typo3.org/community/teams/security) process
applies additionally once the extension is available via TER.

## Scope notes

- The extension is **read-only** on the cube database (`report_ro`, SELECT
  only); the ingestion is the only writer (`cube_rw`). Reports about privilege
  separation between the two are in scope.
- The demo stack (`demo/`) is explicitly **not for production**; hard-coded
  demo credentials there are not considered vulnerabilities.
