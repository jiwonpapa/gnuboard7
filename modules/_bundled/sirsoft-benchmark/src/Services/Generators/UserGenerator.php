<?php

namespace Modules\Sirsoft\Benchmark\Services\Generators;

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\BatchInsertWriter;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticProfileFactory;

class UserGenerator
{
    private ?int $userRoleId = null;

    public function __construct(
        private BatchInsertWriter $batchInsertWriter,
        private SyntheticProfileFactory $profileFactory
    ) {}

    /**
     * @param  array<string, mixed>  $state
     * @return array<string, mixed>
     */
    public function generateChunk(GenerationJob $job, array $state): array
    {
        $options = $job->options ?? [];
        $remaining = max(0, (int) $job->total_users - (int) $job->generated_users);
        $chunkCount = min((int) $options['chunk_size'], $remaining);
        $nextOffset = (int) ($state['next_user_offset'] ?? 0);
        $segments = $state['user_segments'] ?? [];

        if ($chunkCount <= 0) {
            return $state;
        }

        if (! $job->dry_run) {
            $this->userRoleId = $this->userRoleId ?? (int) DB::table('roles')->where('identifier', 'user')->value('id');
            if (! $this->userRoleId) {
                throw new \RuntimeException('기본 user 역할이 없어 더미 회원을 생성할 수 없습니다.');
            }
        }

        $passwordHash = Hash::make('benchmark-password');
        $batchSize = max(1, (int) $options['batch_size']);

        for ($cursor = 0; $cursor < $chunkCount; $cursor += $batchSize) {
            $size = min($batchSize, $chunkCount - $cursor);
            $rows = [];
            $segmentOffsetStart = $nextOffset + $cursor;

            for ($index = 0; $index < $size; $index++) {
                $offset = $segmentOffsetStart + $index;
                $rows[] = $this->profileFactory->buildUserRow($job, $offset, (int) $job->seed, $passwordHash);
            }

            if (! $job->dry_run) {
                $range = $this->batchInsertWriter->insertAndReturnRange('users', $rows);
                $roles = [];

                for ($index = 0; $index < $range['count']; $index++) {
                    $roles[] = [
                        'user_id' => $range['first_id'] + $index,
                        'role_id' => $this->userRoleId,
                        'assigned_at' => now(),
                        'assigned_by' => $job->requested_by,
                        'created_at' => now(),
                        'updated_at' => now(),
                    ];
                }

                $this->batchInsertWriter->insert('user_roles', $roles);

                $segments[] = [
                    'offset_start' => $segmentOffsetStart,
                    'offset_end' => $segmentOffsetStart + $range['count'] - 1,
                    'first_id' => $range['first_id'],
                    'count' => $range['count'],
                ];
            }
        }

        $state['next_user_offset'] = $nextOffset + $chunkCount;
        $state['user_segments'] = $segments;

        return $state;
    }
}
