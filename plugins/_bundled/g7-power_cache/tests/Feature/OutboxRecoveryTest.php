<?php

namespace Plugins\G7\PowerCache\Tests\Feature;

use Illuminate\Contracts\Cache\Lock;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Invalidation\InvalidationApplier;
use Plugins\G7\PowerCache\Invalidation\InvalidationCoordinator;
use Plugins\G7\PowerCache\Invalidation\OutboxReconciler;
use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;
use Plugins\G7\PowerCache\Tests\Support\PowerCacheTestCase;
use RuntimeException;

final class OutboxRecoveryTest extends PowerCacheTestCase
{
    public function test_store_failure_keeps_dirty_barrier_until_idempotent_replay_succeeds(): void
    {
        $repository = $this->repository();
        $healthyStore = $this->arrayStore();
        $failedStore = new class($healthyStore) implements PowerCacheStoreInterface
        {
            public function __construct(private readonly PowerCacheStoreInterface $delegate) {}

            public function getResponse(string $requestKey): ?array
            {
                return $this->delegate->getResponse($requestKey);
            }

            public function putResponse(string $requestKey, array $entry, int $retentionSeconds): void
            {
                $this->delegate->putResponse($requestKey, $entry, $retentionSeconds);
            }

            public function generations(array $scopes): array
            {
                return $this->delegate->generations($scopes);
            }

            public function advanceGenerations(array $scopes, int $eventId): void
            {
                throw new RuntimeException('redis unavailable');
            }

            public function acquireLock(string $name, int $leaseSeconds): ?Lock
            {
                return $this->delegate->acquireLock($name, $leaseSeconds);
            }

            public function emergencyDirty(): bool
            {
                return $this->delegate->emergencyDirty();
            }

            public function markEmergencyDirty(string $reason): void
            {
                $this->delegate->markEmergencyDirty($reason);
            }

            public function clearEmergencyDirty(): void
            {
                $this->delegate->clearEmergencyDirty();
            }

            public function runtimeSnapshot(): ?RuntimeSnapshot
            {
                return $this->delegate->runtimeSnapshot();
            }

            public function putRuntimeSnapshot(RuntimeSnapshot $snapshot): void
            {
                $this->delegate->putRuntimeSnapshot($snapshot);
            }

            public function forgetRuntimeSnapshot(): void
            {
                $this->delegate->forgetRuntimeSnapshot();
            }

            public function incrementMetric(string $metric): void
            {
                $this->delegate->incrementMetric($metric);
            }

            public function probe(): array
            {
                return $this->delegate->probe();
            }

            public function garbageCollect(): array
            {
                return $this->delegate->garbageCollect();
            }

            public function driverName(): string
            {
                return $this->delegate->driverName();
            }
        };

        $failedApplier = new InvalidationApplier($repository, $failedStore);
        $coordinator = new InvalidationCoordinator($repository, $failedStore, $failedApplier);
        $eventId = $coordinator->invalidate(['category:tree'], 'redis-failure-test');

        self::assertNotNull($eventId);
        self::assertSame($eventId, $repository->snapshot()->dirtyEventId);
        self::assertSame(1, $repository->pendingCount());
        self::assertTrue($healthyStore->emergencyDirty());
        self::assertSame(['category:tree' => 0], $healthyStore->generations(['category:tree']));

        $healthyApplier = new InvalidationApplier($repository, $healthyStore);
        $reconciler = new OutboxReconciler($repository, $healthyStore, $healthyApplier);
        $result = $reconciler->reconcile(100);

        self::assertSame(1, $result['applied']);
        self::assertSame(0, $result['remaining']);
        self::assertSame(['category:tree' => $eventId], $healthyStore->generations(['category:tree']));
        self::assertSame(0, $repository->snapshot()->dirtyEventId);
        self::assertFalse($healthyStore->emergencyDirty());

        $secondReplay = $reconciler->reconcile(100);
        self::assertSame(0, $secondReplay['applied']);
        self::assertSame(['category:tree' => $eventId], $healthyStore->generations(['category:tree']));
    }
}
