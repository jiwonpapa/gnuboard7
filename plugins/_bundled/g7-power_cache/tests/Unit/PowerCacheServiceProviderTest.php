<?php

namespace Plugins\G7\PowerCache\Tests\Unit;

use Illuminate\Cache\CacheServiceProvider;
use Illuminate\Filesystem\FilesystemServiceProvider;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Providers\PowerCacheServiceProvider;
use Plugins\G7\PowerCache\Tests\Support\PowerCacheTestCase;

final class PowerCacheServiceProviderTest extends PowerCacheTestCase
{
    public function test_provider_registers_only_plugin_specific_store_and_repository_bindings(): void
    {
        $this->app->register(FilesystemServiceProvider::class);
        $this->app->register(CacheServiceProvider::class);
        (new PowerCacheServiceProvider($this->app))->register();

        self::assertSame('file', config('cache.stores.g7_power_cache_file.driver'));
        self::assertSame('redis', config('cache.stores.g7_power_cache_redis.driver'));
        self::assertSame('array', config('cache.stores.g7_power_cache_array.driver'));
        self::assertTrue($this->app->bound(PowerCacheStoreInterface::class));
        self::assertTrue($this->app->bound(InvalidationRepositoryInterface::class));
        self::assertFalse($this->app->has('App\\Contracts\\Extension\\CacheInterface'));

        $store = $this->app->make(PowerCacheStoreInterface::class);
        self::assertSame('file', $store->driverName());
    }
}
