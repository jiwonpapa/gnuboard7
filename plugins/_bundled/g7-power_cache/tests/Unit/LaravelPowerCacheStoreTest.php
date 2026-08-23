<?php

namespace Plugins\G7\PowerCache\Tests\Unit;

use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;
use Plugins\G7\PowerCache\Tests\Support\PowerCacheTestCase;

final class LaravelPowerCacheStoreTest extends PowerCacheTestCase
{
    public function test_generation_advance_is_monotonic_and_idempotent(): void
    {
        $store = $this->arrayStore();

        self::assertSame(['page:all' => 0, 'site' => 0], $store->generations(['site', 'page:all']));
        $store->advanceGenerations(['site', 'page:all'], 7);
        $store->advanceGenerations(['site', 'page:all'], 3);

        self::assertSame(['page:all' => 7, 'site' => 7], $store->generations(['site', 'page:all']));
    }

    public function test_response_and_emergency_barrier_round_trip(): void
    {
        $store = $this->arrayStore();
        $store->putResponse('request', ['version' => 1, 'body' => '{}'], 60);

        self::assertSame('{}', $store->getResponse('request')['body']);
        self::assertFalse($store->emergencyDirty());
        $store->markEmergencyDirty('test');
        self::assertTrue($store->emergencyDirty());
        $store->clearEmergencyDirty();
        self::assertFalse($store->emergencyDirty());

        self::assertNull($store->runtimeSnapshot());
        $snapshot = new RuntimeSnapshot('site-id', 'epoch-id', 0);
        $store->putRuntimeSnapshot($snapshot);
        self::assertEquals($snapshot, $store->runtimeSnapshot());
        $store->forgetRuntimeSnapshot();
        self::assertNull($store->runtimeSnapshot());
    }
}
