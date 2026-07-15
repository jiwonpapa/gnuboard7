<?php

namespace Modules\Sirsoft\Benchmark\Providers;

use App\Contracts\Extension\CacheInterface;
use App\Extension\BaseModuleServiceProvider;
use App\Extension\Cache\ModuleCacheDriver;
use Modules\Sirsoft\Benchmark\Console\Commands\GenerateDummyDataCommand;
use Modules\Sirsoft\Benchmark\Console\Commands\ResetDummyDataCommand;
use Modules\Sirsoft\Benchmark\Services\Support\BoardCacheInvalidator;

class BenchmarkServiceProvider extends BaseModuleServiceProvider
{
    protected string $moduleIdentifier = 'sirsoft-benchmark';

    protected array $commands = [
        GenerateDummyDataCommand::class,
        ResetDummyDataCommand::class,
    ];

    public function register(): void
    {
        parent::register();

        // 벌크 적재 후 원본 게시판 모듈이 소유한 캐시만 정확히 무효화합니다.
        $this->app->when(BoardCacheInvalidator::class)
            ->needs(CacheInterface::class)
            ->give(fn () => new ModuleCacheDriver('sirsoft-board'));
    }

    public function boot(): void
    {
        parent::boot();

        if ($this->app->runningInConsole()) {
            $this->commands($this->commands);
        }
    }
}
