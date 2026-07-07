<?php

declare(strict_types=1);

namespace SightMetrics\Support;

/**
 * Type narrowing at the outer boundaries (query parameters, DBAL rows, extension
 * configuration): everything there is 'mixed', and phpstan-strict-rules rightly
 * forbids blindly casting from mixed -- these helpers check first and cast
 * afterward. Non-convertible values fall back to the default.
 */
final class Params
{
    private function __construct() {}

    public static function toInt(mixed $value, int $default = 0): int
    {
        if (\is_int($value)) {
            return $value;
        }
        if (\is_float($value) || \is_bool($value)) {
            return (int)$value;
        }
        if (\is_string($value) && \is_numeric($value)) {
            return (int)$value;
        }
        return $default;
    }

    public static function toString(mixed $value, string $default = ''): string
    {
        if (\is_string($value)) {
            return $value;
        }
        if (\is_scalar($value)) {
            return (string)$value;
        }
        return $default;
    }

    public static function toStringOrNull(mixed $value): ?string
    {
        return $value === null ? null : self::toString($value);
    }
}
