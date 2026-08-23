<?php

namespace Plugins\G7\PowerCache\Console\Commands;

use Illuminate\Console\Command;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Invalidation\InvalidationCoordinator;
use Plugins\G7\PowerCache\Invalidation\OutboxReconciler;
use Throwable;

final class PurgeCommand extends Command
{
    protected $signature = 'power-cache:purge
        {--scope=site : site|page|category}
        {--reason=manual : 감사 로그용 사유}
        {--json : JSON 형식으로 출력}';

    protected $description = '키 삭제 없이 G7PowerCache 세대를 회전합니다.';

    public function handle(
        InvalidationCoordinator $coordinator,
        OutboxReconciler $reconciler,
        InvalidationRepositoryInterface $repository,
        PowerCacheStoreInterface $store,
    ): int {
        $scope = (string) $this->option('scope');
        $generationScope = match ($scope) {
            'site' => 'site',
            'page' => 'page:all',
            'category' => 'category:tree',
            default => null,
        };

        if ($generationScope === null) {
            $this->error('scope은 site, page, category 중 하나여야 합니다.');

            return self::INVALID;
        }

        $eventId = $coordinator->invalidate(
            [$generationScope],
            'manual:'.(string) $this->option('reason'),
            ['operator' => get_current_user(), 'scope' => $scope],
        );
        if ($eventId === null) {
            $this->error('무효화 아웃박스를 기록하지 못했습니다.');

            return self::FAILURE;
        }

        $recovery = $reconciler->reconcile(1000);
        $pending = $repository->pendingCount();
        $emergencyCleared = false;

        if ($scope === 'site' && $pending === 0 && $recovery['error'] === null) {
            try {
                $store->clearEmergencyDirty();
                $emergencyCleared = true;
            } catch (Throwable) {
                // 결과의 emergency_cleared=false로 운영자에게 드러냅니다.
            }
        }

        $result = [
            'ok' => $pending === 0 && $recovery['error'] === null,
            'event_id' => $eventId,
            'scope' => $generationScope,
            'pending_outbox' => $pending,
            'emergency_cleared' => $emergencyCleared,
            'recovery' => $recovery,
        ];

        if ($this->option('json')) {
            $this->line(json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
        } else {
            $this->line(sprintf(
                'event_id=%d scope=%s pending=%d emergency_cleared=%s',
                $eventId,
                $generationScope,
                $pending,
                $emergencyCleared ? 'yes' : 'no',
            ));
        }

        return $result['ok'] ? self::SUCCESS : self::FAILURE;
    }
}
