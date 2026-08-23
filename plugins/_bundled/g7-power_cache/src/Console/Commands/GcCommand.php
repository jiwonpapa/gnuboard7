<?php

namespace Plugins\G7\PowerCache\Console\Commands;

use Illuminate\Console\Command;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;

final class GcCommand extends Command
{
    protected $signature = 'power-cache:gc
        {--days= : 적용 완료 아웃박스 보존일; 미지정 시 환경설정 사용}
        {--json : JSON 형식으로 출력}';

    protected $description = '적용 완료된 오래된 G7PowerCache 아웃박스 이력을 정리합니다.';

    public function handle(
        InvalidationRepositoryInterface $repository,
        PowerCacheStoreInterface $store,
    ): int {
        if (! $repository->tablesReady()) {
            $this->error('G7PowerCache 테이블이 없습니다.');

            return self::FAILURE;
        }

        $configured = (int) config('g7_power_cache.outbox_retention_days', 7);
        $days = $this->option('days') === null ? $configured : (int) $this->option('days');
        $days = min(3650, max(1, $days));
        $deleted = $repository->pruneAppliedBefore(now()->subDays($days));
        $cacheGc = $store->garbageCollect();
        $result = [
            'ok' => true,
            'retention_days' => $days,
            'outbox_deleted' => $deleted,
            'cache' => $cacheGc,
        ];

        if ($this->option('json')) {
            $this->line(json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
        } else {
            $this->line(sprintf(
                'retention_days=%d outbox_deleted=%d cache_gc_supported=%s cache_deleted=%d',
                $days,
                $deleted,
                $cacheGc['supported'] ? 'yes' : 'no',
                $cacheGc['deleted'],
            ));
        }

        return self::SUCCESS;
    }
}
