<?php

namespace Plugins\G7\PowerCache\Contracts;

use DateTimeInterface;
use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;

interface InvalidationRepositoryInterface
{
    public function tablesReady(): bool;

    public function snapshot(): RuntimeSnapshot;

    /** @param array<int, string> $scopes @param array<string, mixed> $payload */
    public function append(array $scopes, string $reason, array $payload = []): int;

    public function markDirty(int $eventId): void;

    /** @return array<string, mixed>|null */
    public function find(int $eventId): ?array;

    /** @return array<int, array<string, mixed>> */
    public function pending(int $limit): array;

    public function markAttemptFailed(int $eventId, string $error): void;

    public function markApplied(int $eventId): void;

    public function clearDirtyWhenRecovered(): bool;

    public function pendingCount(): int;

    public function pruneAppliedBefore(DateTimeInterface $before): int;

    public function rotateRuntimeEpoch(): string;
}
