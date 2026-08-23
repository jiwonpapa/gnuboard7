<?php

namespace Plugins\G7\PowerCache\Invalidation;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Throwable;

final class InvalidationCoordinator
{
    public function __construct(
        private readonly InvalidationRepositoryInterface $repository,
        private readonly PowerCacheStoreInterface $store,
        private readonly InvalidationApplier $applier,
    ) {}

    /**
     * @param  array<int, string>  $scopes
     * @param  array<string, mixed>  $payload
     */
    public function invalidate(array $scopes, string $reason, array $payload = []): ?int
    {
        $scopes = $this->normalizeScopes($scopes);
        if ($scopes === []) {
            return null;
        }

        try {
            if (! $this->repository->tablesReady()) {
                $this->markEmergency('outbox_tables_missing');

                return null;
            }

            if (DB::transactionLevel() > 0) {
                $eventId = $this->appendWithinTransaction($scopes, $reason, $payload);
                DB::afterCommit(fn () => $this->applier->apply($eventId));

                return $eventId;
            }

            $eventId = DB::transaction(
                fn (): int => $this->appendWithinTransaction($scopes, $reason, $payload),
            );
            $this->applier->apply($eventId);

            return $eventId;
        } catch (Throwable $e) {
            Log::critical('G7PowerCache 무효화 아웃박스 기록에 실패했습니다.', [
                'reason' => $reason,
                'scopes' => $scopes,
                'error' => $e->getMessage(),
            ]);
            $this->markEmergency('outbox_write_failed:'.$e->getMessage());

            return null;
        }
    }

    /** @param array<int, string> $scopes @param array<string, mixed> $payload */
    private function appendWithinTransaction(array $scopes, string $reason, array $payload): int
    {
        $eventId = $this->repository->append($scopes, $reason, $payload);
        $this->repository->markDirty($eventId);
        // DB 커밋 전에 빠른 경로를 닫아, 커밋 직후 프로세스가 종료되어도 이전 응답을 내보내지 않습니다.
        $this->store->markEmergencyDirty('outbox_pending:'.$eventId);

        return $eventId;
    }

    private function markEmergency(string $reason): void
    {
        try {
            $this->store->markEmergencyDirty($reason);
        } catch (Throwable $e) {
            Log::critical('G7PowerCache 저장소 비상 장벽 기록에도 실패했습니다.', [
                'reason' => $reason,
                'error' => $e->getMessage(),
            ]);
        }
    }

    /** @param array<int, string> $scopes @return array<int, string> */
    private function normalizeScopes(array $scopes): array
    {
        $normalized = array_values(array_unique(array_filter(array_map(
            static fn (mixed $scope): string => trim((string) $scope),
            $scopes,
        ))));
        sort($normalized, SORT_STRING);

        return $normalized;
    }
}
