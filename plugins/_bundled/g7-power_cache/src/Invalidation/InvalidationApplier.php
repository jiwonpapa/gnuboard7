<?php

namespace Plugins\G7\PowerCache\Invalidation;

use Illuminate\Support\Facades\Log;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Throwable;

final class InvalidationApplier
{
    public function __construct(
        private readonly InvalidationRepositoryInterface $repository,
        private readonly PowerCacheStoreInterface $store,
    ) {}

    public function apply(int $eventId): bool
    {
        $event = $this->repository->find($eventId);
        if ($event === null || $event['applied_at'] !== null) {
            return true;
        }

        try {
            $this->store->advanceGenerations($event['scopes'], $eventId);
            $this->repository->markApplied($eventId);
            if ($this->repository->clearDirtyWhenRecovered()) {
                $snapshot = $this->repository->snapshot();
                $this->store->putRuntimeSnapshot($snapshot);
                $this->store->clearEmergencyDirty();
            }

            return true;
        } catch (Throwable $e) {
            try {
                $this->store->markEmergencyDirty('invalidation_apply_failed:'.$eventId);
            } catch (Throwable) {
                // 저장소 자체가 장애면 응답 캐시 읽기도 실패하여 원본 경로로 우회합니다.
            }

            try {
                $this->repository->markAttemptFailed($eventId, $e->getMessage());
            } catch (Throwable $repositoryError) {
                Log::critical('G7PowerCache 무효화 실패 상태 기록도 실패했습니다.', [
                    'event_id' => $eventId,
                    'error' => $repositoryError->getMessage(),
                ]);
            }

            Log::error('G7PowerCache 세대 적용에 실패해 복구 장벽을 유지합니다.', [
                'event_id' => $eventId,
                'error' => $e->getMessage(),
            ]);

            return false;
        }
    }
}
