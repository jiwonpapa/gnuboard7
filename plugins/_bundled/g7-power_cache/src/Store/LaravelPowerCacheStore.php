<?php

namespace Plugins\G7\PowerCache\Store;

use Illuminate\Cache\Repository;
use Illuminate\Contracts\Cache\Lock;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;
use RuntimeException;

final class LaravelPowerCacheStore implements PowerCacheStoreInterface
{
    private const EMERGENCY_DIRTY_KEY = 'barrier:emergency-dirty';

    private const RUNTIME_SNAPSHOT_KEY = 'barrier:runtime-snapshot';

    public function __construct(
        private readonly Repository $cache,
        private readonly string $driver,
        private readonly ?string $filePath = null,
        private readonly ?string $fileGcSafeRoot = null,
    ) {}

    public function getResponse(string $requestKey): ?array
    {
        $entry = $this->cache->get($this->responseKey($requestKey));

        return is_array($entry) ? $entry : null;
    }

    public function putResponse(string $requestKey, array $entry, int $retentionSeconds): void
    {
        if (! $this->cache->put($this->responseKey($requestKey), $entry, $retentionSeconds)) {
            throw new RuntimeException('G7PowerCache response store write failed.');
        }
    }

    public function generations(array $scopes): array
    {
        $scopes = $this->normalizeScopes($scopes);
        if ($scopes === []) {
            return [];
        }

        $keys = [];
        foreach ($scopes as $scope) {
            $keys[$scope] = $this->generationKey($scope);
        }

        $values = $this->cache->many(array_values($keys));
        $result = [];
        foreach ($keys as $scope => $key) {
            $result[$scope] = max(0, (int) ($values[$key] ?? 0));
        }

        return $result;
    }

    public function advanceGenerations(array $scopes, int $eventId): void
    {
        $scopes = $this->normalizeScopes($scopes);
        if ($scopes === []) {
            return;
        }

        $lock = $this->acquireLock('generation-writer', 10);
        if ($lock === null) {
            throw new RuntimeException('G7PowerCache generation writer lock is busy.');
        }

        try {
            foreach ($scopes as $scope) {
                $key = $this->generationKey($scope);
                $current = max(0, (int) $this->cache->get($key, 0));
                if ($eventId > $current && ! $this->cache->forever($key, $eventId)) {
                    throw new RuntimeException("G7PowerCache generation write failed: {$scope}");
                }
            }
        } finally {
            $lock->release();
        }
    }

    public function acquireLock(string $name, int $leaseSeconds): ?Lock
    {
        $lock = $this->cache->lock($this->lockKey($name), max(1, $leaseSeconds));

        return $lock->get() ? $lock : null;
    }

    public function emergencyDirty(): bool
    {
        return $this->cache->has(self::EMERGENCY_DIRTY_KEY);
    }

    public function markEmergencyDirty(string $reason): void
    {
        if (! $this->cache->forever(self::EMERGENCY_DIRTY_KEY, [
            'reason' => mb_substr($reason, 0, 500),
            'marked_at' => now()->toIso8601String(),
        ])) {
            throw new RuntimeException('G7PowerCache emergency barrier write failed.');
        }
    }

    public function clearEmergencyDirty(): void
    {
        $this->cache->forget(self::EMERGENCY_DIRTY_KEY);
    }

    public function runtimeSnapshot(): ?RuntimeSnapshot
    {
        $state = $this->cache->get(self::RUNTIME_SNAPSHOT_KEY);
        if (! is_array($state)
            || ! is_string($state['site_id'] ?? null)
            || ! is_string($state['runtime_epoch'] ?? null)
            || ! is_numeric($state['dirty_event_id'] ?? null)) {
            return null;
        }

        return new RuntimeSnapshot(
            $state['site_id'],
            $state['runtime_epoch'],
            max(0, (int) $state['dirty_event_id']),
        );
    }

    public function putRuntimeSnapshot(RuntimeSnapshot $snapshot): void
    {
        if (! $this->cache->forever(self::RUNTIME_SNAPSHOT_KEY, [
            'site_id' => $snapshot->siteId,
            'runtime_epoch' => $snapshot->runtimeEpoch,
            'dirty_event_id' => $snapshot->dirtyEventId,
        ])) {
            throw new RuntimeException('G7PowerCache runtime snapshot write failed.');
        }
    }

    public function forgetRuntimeSnapshot(): void
    {
        $this->cache->forget(self::RUNTIME_SNAPSHOT_KEY);
    }

    public function incrementMetric(string $metric): void
    {
        $metric = preg_replace('/[^a-z0-9_.:-]/i', '_', $metric) ?: 'unknown';
        $key = 'metric:'.gmdate('YmdH').':'.$metric;
        $this->cache->add($key, 0, 691200);
        $this->cache->increment($key);
    }

    public function probe(): array
    {
        $key = 'probe:'.bin2hex(random_bytes(8));
        $value = bin2hex(random_bytes(12));
        $written = $this->cache->put($key, $value, 10);
        $readBack = $this->cache->get($key);
        $this->cache->forget($key);

        return [
            'ok' => $written && hash_equals($value, (string) $readBack),
            'driver' => $this->driver,
        ];
    }

    public function garbageCollect(): array
    {
        if ($this->driver !== 'file' || $this->filePath === null) {
            return ['supported' => false, 'deleted' => 0];
        }

        return (new FileCacheGarbageCollector)->collect(
            $this->filePath,
            safeRoot: $this->fileGcSafeRoot,
        );
    }

    public function driverName(): string
    {
        return $this->driver;
    }

    private function responseKey(string $requestKey): string
    {
        return 'response:'.$requestKey;
    }

    private function generationKey(string $scope): string
    {
        return 'generation:'.hash('sha256', $scope);
    }

    private function lockKey(string $name): string
    {
        return 'lock:'.hash('sha256', $name);
    }

    /** @param array<int, string> $scopes @return array<int, string> */
    private function normalizeScopes(array $scopes): array
    {
        $scopes = array_values(array_unique(array_filter(array_map(
            static fn (mixed $scope): string => trim((string) $scope),
            $scopes,
        ))));
        sort($scopes, SORT_STRING);

        return $scopes;
    }
}
