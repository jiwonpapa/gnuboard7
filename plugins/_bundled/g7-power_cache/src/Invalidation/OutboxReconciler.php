<?php

namespace Plugins\G7\PowerCache\Invalidation;

use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Throwable;

final class OutboxReconciler
{
    public function __construct(
        private readonly InvalidationRepositoryInterface $repository,
        private readonly PowerCacheStoreInterface $store,
        private readonly InvalidationApplier $applier,
    ) {}

    /** @return array{attempted:int, applied:int, remaining:int, locked:bool, error:?string} */
    public function reconcile(int $limit): array
    {
        $lock = null;

        try {
            $lock = $this->store->acquireLock('outbox-reconcile', 15);
            if ($lock === null) {
                return [
                    'attempted' => 0,
                    'applied' => 0,
                    'remaining' => $this->repository->pendingCount(),
                    'locked' => true,
                    'error' => null,
                ];
            }

            $attempted = 0;
            $applied = 0;
            foreach ($this->repository->pending(max(1, $limit)) as $event) {
                $attempted++;
                if (! $this->applier->apply((int) $event['id'])) {
                    break;
                }
                $applied++;
            }

            $this->repository->clearDirtyWhenRecovered();

            return [
                'attempted' => $attempted,
                'applied' => $applied,
                'remaining' => $this->repository->pendingCount(),
                'locked' => false,
                'error' => null,
            ];
        } catch (Throwable $e) {
            return [
                'attempted' => 0,
                'applied' => 0,
                'remaining' => $this->repository->tablesReady() ? $this->repository->pendingCount() : 0,
                'locked' => false,
                'error' => $e->getMessage(),
            ];
        } finally {
            $lock?->release();
        }
    }
}
