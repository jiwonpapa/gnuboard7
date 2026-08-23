<?php

namespace Plugins\G7\PowerCache\Providers;

use App\Extension\BasePluginServiceProvider;
use Plugins\G7\PowerCache\Console\Commands\DoctorCommand;
use Plugins\G7\PowerCache\Console\Commands\GcCommand;
use Plugins\G7\PowerCache\Console\Commands\ModeCommand;
use Plugins\G7\PowerCache\Console\Commands\PurgeCommand;
use Plugins\G7\PowerCache\Console\Commands\ReconcileCommand;
use Plugins\G7\PowerCache\Console\Commands\StatusCommand;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Infrastructure\DatabaseInvalidationRepository;
use Plugins\G7\PowerCache\Runtime\PowerCacheSettings;
use Plugins\G7\PowerCache\Store\LaravelPowerCacheStore;

final class PowerCacheServiceProvider extends BasePluginServiceProvider
{
    protected string $pluginIdentifier = 'g7-power_cache';

    public function register(): void
    {
        parent::register();

        $root = dirname(__DIR__, 2);
        $this->mergeConfigFrom($root.'/config/power_cache.php', 'g7_power_cache');
        $this->registerDedicatedStores();

        $this->app->scoped(PowerCacheSettings::class);
        $this->app->singleton(InvalidationRepositoryInterface::class, DatabaseInvalidationRepository::class);
        $this->app->scoped(PowerCacheStoreInterface::class, function ($app): PowerCacheStoreInterface {
            $settings = $app->make(PowerCacheSettings::class);
            $driver = $settings->storeDriver();

            $storeName = (string) config("g7_power_cache.stores.{$driver}");

            return new LaravelPowerCacheStore(
                $app['cache']->store($storeName),
                $driver,
                $driver === 'file' ? (string) config('g7_power_cache.file.path') : null,
                $driver === 'file' ? (string) config('g7_power_cache.file.gc_safe_root') : null,
            );
        });
    }

    public function boot(): void
    {
        parent::boot();

        if ($this->app->runningInConsole()) {
            $this->commands([
                DoctorCommand::class,
                GcCommand::class,
                ModeCommand::class,
                StatusCommand::class,
                PurgeCommand::class,
                ReconcileCommand::class,
            ]);
        }
    }

    private function registerDedicatedStores(): void
    {
        config([
            'cache.stores.g7_power_cache_file' => [
                'driver' => 'file',
                'path' => config('g7_power_cache.file.path'),
                'lock_path' => config('g7_power_cache.file.path').'/locks',
            ],
            'cache.stores.g7_power_cache_redis' => [
                'driver' => 'redis',
                'connection' => config('g7_power_cache.redis.connection'),
                'lock_connection' => config('g7_power_cache.redis.connection'),
                'prefix' => config('g7_power_cache.redis.prefix'),
            ],
            'cache.stores.g7_power_cache_array' => [
                'driver' => 'array',
                'serialize' => true,
            ],
            'database.redis.g7_power_cache' => [
                'url' => config('g7_power_cache.redis.url'),
                'host' => config('g7_power_cache.redis.host'),
                'username' => config('g7_power_cache.redis.username'),
                'password' => config('g7_power_cache.redis.password'),
                'port' => config('g7_power_cache.redis.port'),
                'database' => config('g7_power_cache.redis.database'),
                'max_retries' => 1,
                'backoff_algorithm' => 'decorrelated_jitter',
                'backoff_base' => 50,
                'backoff_cap' => 250,
            ],
        ]);
    }
}
