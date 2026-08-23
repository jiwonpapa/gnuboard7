<?php

namespace Plugins\G7\PowerCache\Tests\Feature;

use Illuminate\Support\Facades\DB;
use Plugins\G7\PowerCache\Invalidation\InvalidationApplier;
use Plugins\G7\PowerCache\Invalidation\InvalidationCoordinator;
use Plugins\G7\PowerCache\Tests\Support\PowerCacheTestCase;

final class OutboxTransactionTest extends PowerCacheTestCase
{
    public function test_rollback_removes_outbox_and_does_not_advance_generation(): void
    {
        $repository = $this->repository();
        $store = $this->arrayStore();
        $applier = new InvalidationApplier($repository, $store);
        $coordinator = new InvalidationCoordinator($repository, $store, $applier);

        DB::beginTransaction();
        $eventId = $coordinator->invalidate(['page:all'], 'rollback-test');
        self::assertNotNull($eventId);
        DB::rollBack();

        self::assertSame(0, $repository->pendingCount());
        self::assertSame(['page:all' => 0], $store->generations(['page:all']));
        self::assertSame(0, $repository->snapshot()->dirtyEventId);
        self::assertTrue($store->emergencyDirty(), '롤백 후에는 운영자가 확인할 때까지 fail-closed 장벽을 유지합니다.');
    }

    public function test_commit_applies_generation_after_transaction(): void
    {
        $repository = $this->repository();
        $store = $this->arrayStore();
        $applier = new InvalidationApplier($repository, $store);
        $coordinator = new InvalidationCoordinator($repository, $store, $applier);

        DB::beginTransaction();
        $eventId = $coordinator->invalidate(['page:all'], 'commit-test');
        self::assertNotNull($eventId);
        self::assertSame(['page:all' => 0], $store->generations(['page:all']));
        DB::commit();

        self::assertSame(['page:all' => $eventId], $store->generations(['page:all']));
        self::assertSame(0, $repository->pendingCount());
        self::assertSame(0, $repository->snapshot()->dirtyEventId);
        self::assertFalse($store->emergencyDirty());
    }

    public function test_gc_only_prunes_old_applied_events(): void
    {
        $repository = $this->repository();
        $store = $this->arrayStore();
        $applier = new InvalidationApplier($repository, $store);
        $coordinator = new InvalidationCoordinator($repository, $store, $applier);

        $oldApplied = $coordinator->invalidate(['site'], 'old-applied');
        $recentApplied = $coordinator->invalidate(['site'], 'recent-applied');
        self::assertNotNull($oldApplied);
        self::assertNotNull($recentApplied);

        DB::table('g7_power_cache_invalidation_outbox')
            ->where('id', $oldApplied)
            ->update(['applied_at' => now()->subDays(30)]);

        self::assertSame(1, $repository->pruneAppliedBefore(now()->subDays(7)));
        self::assertNull($repository->find($oldApplied));
        self::assertNotNull($repository->find($recentApplied));
        self::assertSame(0, $repository->pendingCount());
    }
}
