<?php

namespace Plugins\G7\PowerCache\Infrastructure;

use DateTimeInterface;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;

final class DatabaseInvalidationRepository implements InvalidationRepositoryInterface
{
    private ?bool $tablesReady = null;

    public function tablesReady(): bool
    {
        return $this->tablesReady ??= Schema::hasTable('g7_power_cache_state')
            && Schema::hasTable('g7_power_cache_invalidation_outbox');
    }

    public function snapshot(): RuntimeSnapshot
    {
        $state = DB::table('g7_power_cache_state')
            ->whereIn('state_key', ['site_id', 'runtime_epoch', 'dirty_event_id'])
            ->pluck('state_value', 'state_key');

        return new RuntimeSnapshot(
            (string) ($state['site_id'] ?? ''),
            (string) ($state['runtime_epoch'] ?? ''),
            max(0, (int) ($state['dirty_event_id'] ?? 0)),
        );
    }

    public function append(array $scopes, string $reason, array $payload = []): int
    {
        return (int) DB::table('g7_power_cache_invalidation_outbox')->insertGetId([
            'scopes' => json_encode(array_values($scopes), JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE),
            'reason' => mb_substr($reason, 0, 191),
            'payload' => $payload === [] ? null : json_encode($payload, JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE),
            'attempts' => 0,
            'last_error' => null,
            'applied_at' => null,
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }

    public function markDirty(int $eventId): void
    {
        $current = (int) DB::table('g7_power_cache_state')
            ->where('state_key', 'dirty_event_id')
            ->lockForUpdate()
            ->value('state_value');

        if ($eventId <= $current) {
            return;
        }

        DB::table('g7_power_cache_state')
            ->where('state_key', 'dirty_event_id')
            ->update([
                'state_value' => (string) $eventId,
                'updated_at' => now(),
            ]);
    }

    public function find(int $eventId): ?array
    {
        $row = DB::table('g7_power_cache_invalidation_outbox')->where('id', $eventId)->first();

        return $row === null ? null : $this->normalizeRow($row);
    }

    public function pending(int $limit): array
    {
        return DB::table('g7_power_cache_invalidation_outbox')
            ->whereNull('applied_at')
            ->orderBy('id')
            ->limit(max(1, $limit))
            ->get()
            ->map(fn (object $row): array => $this->normalizeRow($row))
            ->all();
    }

    public function markAttemptFailed(int $eventId, string $error): void
    {
        DB::table('g7_power_cache_invalidation_outbox')
            ->where('id', $eventId)
            ->whereNull('applied_at')
            ->update([
                'attempts' => DB::raw('attempts + 1'),
                'last_error' => mb_substr($error, 0, 65535),
                'updated_at' => now(),
            ]);
    }

    public function markApplied(int $eventId): void
    {
        DB::table('g7_power_cache_invalidation_outbox')
            ->where('id', $eventId)
            ->update([
                'attempts' => DB::raw('attempts + 1'),
                'last_error' => null,
                'applied_at' => now(),
                'updated_at' => now(),
            ]);
    }

    public function clearDirtyWhenRecovered(): bool
    {
        return DB::transaction(function (): bool {
            DB::table('g7_power_cache_state')
                ->where('state_key', 'dirty_event_id')
                ->lockForUpdate()
                ->value('state_value');

            $hasPending = DB::table('g7_power_cache_invalidation_outbox')
                ->whereNull('applied_at')
                ->exists();

            if (! $hasPending) {
                DB::table('g7_power_cache_state')
                    ->where('state_key', 'dirty_event_id')
                    ->update([
                        'state_value' => '0',
                        'updated_at' => now(),
                    ]);

                return true;
            }

            return false;
        });
    }

    public function pendingCount(): int
    {
        return (int) DB::table('g7_power_cache_invalidation_outbox')
            ->whereNull('applied_at')
            ->count();
    }

    public function pruneAppliedBefore(DateTimeInterface $before): int
    {
        return DB::table('g7_power_cache_invalidation_outbox')
            ->whereNotNull('applied_at')
            ->where('applied_at', '<', $before)
            ->delete();
    }

    public function rotateRuntimeEpoch(): string
    {
        $epoch = (string) Str::uuid();

        DB::table('g7_power_cache_state')->updateOrInsert(
            ['state_key' => 'runtime_epoch'],
            [
                'state_value' => $epoch,
                'created_at' => now(),
                'updated_at' => now(),
            ],
        );

        return $epoch;
    }

    /** @return array<string, mixed> */
    private function normalizeRow(object $row): array
    {
        $scopes = is_string($row->scopes)
            ? json_decode($row->scopes, true, flags: JSON_THROW_ON_ERROR)
            : (array) $row->scopes;
        $payload = $row->payload === null
            ? []
            : (is_string($row->payload) ? json_decode($row->payload, true, flags: JSON_THROW_ON_ERROR) : (array) $row->payload);

        return [
            'id' => (int) $row->id,
            'scopes' => array_values(array_filter((array) $scopes, 'is_string')),
            'reason' => (string) $row->reason,
            'payload' => $payload,
            'attempts' => (int) $row->attempts,
            'last_error' => $row->last_error,
            'applied_at' => $row->applied_at,
        ];
    }
}
