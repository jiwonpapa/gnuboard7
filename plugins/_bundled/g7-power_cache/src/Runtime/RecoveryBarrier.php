<?php

namespace Plugins\G7\PowerCache\Runtime;

use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Invalidation\OutboxReconciler;
use Throwable;

final class RecoveryBarrier
{
    public function __construct(
        private readonly InvalidationRepositoryInterface $repository,
        private readonly PowerCacheStoreInterface $store,
        private readonly OutboxReconciler $reconciler,
        private readonly PowerCacheSettings $settings,
    ) {}

    public function inspect(): BarrierResult
    {
        try {
            if ($this->store->driverName() === 'file'
                && ! (bool) config('g7_power_cache.file.single_node_ack', false)) {
                return BarrierResult::blocked('file_single_node_unacknowledged');
            }

            if ($this->store->emergencyDirty()) {
                return $this->recoverFromDatabase('emergency_dirty');
            }

            $snapshot = $this->store->runtimeSnapshot();
            if ($this->valid($snapshot)) {
                // 무효화 쓰기가 검사 직후 시작된 경우에도 세대 키 조회 전에 장벽을 한 번 더 확인합니다.
                if ($this->store->emergencyDirty()) {
                    return $this->recoverFromDatabase('emergency_dirty');
                }

                return BarrierResult::ready($snapshot);
            }

            return $this->recoverFromDatabase('snapshot_missing');
        } catch (Throwable) {
            return BarrierResult::blocked('barrier_error');
        }
    }

    private function recoverFromDatabase(string $blockedReason): BarrierResult
    {
        if (! $this->repository->tablesReady()) {
            return BarrierResult::blocked('tables_missing');
        }

        $snapshot = $this->repository->snapshot();
        if (! $this->valid($snapshot)) {
            return BarrierResult::blocked('state_invalid');
        }

        if (($snapshot->isDirty() || $this->store->emergencyDirty())
            && $this->settings->automaticRecovery()) {
            $this->reconciler->reconcile($this->settings->recoveryBatch());
            $snapshot = $this->repository->snapshot();
        }

        if ($snapshot->isDirty()) {
            return BarrierResult::blocked('outbox_dirty');
        }

        if ($this->store->emergencyDirty()) {
            return BarrierResult::blocked($blockedReason);
        }

        $this->store->putRuntimeSnapshot($snapshot);

        return BarrierResult::ready($snapshot);
    }

    private function valid(?RuntimeSnapshot $snapshot): bool
    {
        return $snapshot !== null
            && $snapshot->siteId !== ''
            && $snapshot->runtimeEpoch !== ''
            && ! $snapshot->isDirty();
    }
}
