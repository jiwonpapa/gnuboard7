<?php

namespace Plugins\G7\PowerCache\Runtime;

final class PowerCacheSettings
{
    public const IDENTIFIER = 'g7-power_cache';

    /** @param array<string, mixed>|null $override */
    public function __construct(private readonly ?array $override = null) {}

    public function mode(): string
    {
        $mode = (string) $this->value('mode', 'observe');

        return in_array($mode, ['observe', 'active', 'bypass'], true) ? $mode : 'observe';
    }

    public function storeDriver(): string
    {
        $driver = (string) $this->value('store_driver', 'file');
        $allowed = ['file', 'redis'];
        if (app()->environment('testing')) {
            $allowed[] = 'array';
        }

        return in_array($driver, $allowed, true) ? $driver : 'file';
    }

    public function publicPagesEnabled(): bool
    {
        return (bool) $this->value('cache_public_pages', true);
    }

    public function publicCategoriesEnabled(): bool
    {
        return (bool) $this->value('cache_public_categories', true);
    }

    public function publicBoardListsEnabled(): bool
    {
        return (bool) $this->value('cache_public_board_lists', true);
    }

    public function automaticRecovery(): bool
    {
        return (bool) $this->value('automatic_recovery', true);
    }

    public function metricsEnabled(): bool
    {
        return (bool) $this->value('metrics_enabled', true);
    }

    public function debugHeaders(): bool
    {
        return (bool) $this->value('debug_headers', false);
    }

    public function maxResponseBytes(): int
    {
        return $this->boundedInt('max_response_kb', 512, 16, 4096) * 1024;
    }

    public function retentionSeconds(): int
    {
        return $this->boundedInt('retention_seconds', 604800, 3600, 2592000);
    }

    public function lockWaitMilliseconds(): int
    {
        return $this->boundedInt('lock_wait_ms', 500, 0, 5000);
    }

    public function lockLeaseSeconds(): int
    {
        return $this->boundedInt('lock_lease_seconds', 15, 1, 120);
    }

    public function recoveryBatch(): int
    {
        return $this->boundedInt('recovery_batch', 100, 1, 1000);
    }

    private function boundedInt(string $key, int $default, int $min, int $max): int
    {
        return min($max, max($min, (int) $this->value($key, $default)));
    }

    private function value(string $key, mixed $default): mixed
    {
        if ($this->override !== null) {
            return $this->override[$key] ?? $default;
        }

        return \plugin_setting(self::IDENTIFIER, $key, $default);
    }
}
