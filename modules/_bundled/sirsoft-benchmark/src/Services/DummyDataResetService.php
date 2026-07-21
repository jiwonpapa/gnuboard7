<?php

namespace Modules\Sirsoft\Benchmark\Services;

use App\Models\User;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Enums\WorkloadType;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\BoardCounterSyncService;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;
use Modules\Sirsoft\Benchmark\Services\Support\ProgressReporter;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticProfileFactory;

class DummyDataResetService
{
    public const DELETE_CHUNK_SIZE = 20000;

    public function __construct(
        private SyntheticProfileFactory $profileFactory,
        private BoardCounterSyncService $boardCounterSyncService,
        private CommerceDatasetResetService $commerceDatasetResetService,
        private ProgressReporter $progressReporter,
        private GenerationJobLogger $logger
    ) {}

    public function processNextChunk(int $jobId): bool
    {
        $job = GenerationJob::query()->find($jobId);

        if (! $job) {
            return false;
        }

        $this->authenticateRequester($job);

        if ($job->status === GenerationJobStatus::Stopping) {
            $this->progressReporter->markStopped($job, '초기화 중단 요청을 반영했습니다.');
            $this->logger->warning($job, '데이터셋 초기화가 중단되었습니다.', GenerationStage::Resetting->value);

            return false;
        }

        $state = $job->runtime_state ?? [];
        if (($state['reset_phase'] ?? null) === 'completed') {
            return false;
        }

        $job->status = GenerationJobStatus::Running;
        $job->save();

        if ($job->workload_type === WorkloadType::Commerce) {
            return $this->commerceDatasetResetService->processNextChunk($job->fresh());
        }

        $state['reset_phase'] = (string) ($state['reset_phase'] ?? 'comments');
        $state['reset_user_segment_index'] = (int) ($state['reset_user_segment_index'] ?? 0);
        $state['cleanup'] = array_merge([
            'deleted_posts' => 0,
            'deleted_comments' => 0,
            'deleted_users' => 0,
            'synced_boards' => 0,
        ], is_array($state['cleanup'] ?? null) ? $state['cleanup'] : []);

        $segments = array_values(array_filter(
            $state['user_segments'] ?? [],
            fn ($segment) => is_array($segment) && (int) ($segment['count'] ?? 0) > 0
        ));
        $boardIds = $this->resolveTargetBoardIds($state);

        return match ($state['reset_phase']) {
            'comments' => $this->processDeletePhase(
                $job,
                $state,
                $segments,
                $boardIds,
                'board_comments',
                'deleted_comments',
                '댓글',
                'posts'
            ),
            'posts' => $this->processDeletePhase(
                $job,
                $state,
                $segments,
                $boardIds,
                'board_posts',
                'deleted_posts',
                '게시글',
                'users'
            ),
            'users' => $this->processDeletePhase(
                $job,
                $state,
                $segments,
                [],
                'users',
                'deleted_users',
                '회원',
                'sync'
            ),
            default => $this->completeBoardReset($job, $state, $boardIds),
        };
    }

    /**
     * 한 번의 큐 실행에서 최대 DELETE_CHUNK_SIZE 행만 삭제합니다.
     *
     * @param  array<string, mixed>  $state
     * @param  array<int, array<string, mixed>>  $segments
     * @param  array<int>  $boardIds
     */
    private function processDeletePhase(
        GenerationJob $job,
        array $state,
        array $segments,
        array $boardIds,
        string $table,
        string $cleanupKey,
        string $label,
        string $nextPhase
    ): bool {
        $segmentIndex = (int) ($state['reset_user_segment_index'] ?? 0);

        if ($segments === [] || ($table !== 'users' && $boardIds === [])) {
            return $this->advancePhase($job, $state, $nextPhase, "{$label} 삭제 대상이 없어 다음 단계로 이동합니다.");
        }

        if ($segmentIndex >= count($segments)) {
            return $this->advancePhase($job, $state, $nextPhase, "{$label} 삭제가 완료되었습니다.");
        }

        $segment = $segments[$segmentIndex];
        $firstId = (int) $segment['first_id'];
        $lastId = $firstId + (int) $segment['count'] - 1;
        $chunk = $this->deleteChunk(
            $table,
            $boardIds,
            [$firstId, $lastId],
            $table === 'users' ? $this->profileFactory->datasetMarker($job) : null,
            (int) ($state['reset_delete_cursor'] ?? 0)
        );
        $deleted = $chunk['deleted'];

        $state['cleanup'][$cleanupKey] = (int) ($state['cleanup'][$cleanupKey] ?? 0) + $deleted;
        $state['reset_delete_cursor'] = $chunk['cursor'];

        if ($chunk['selected'] < self::DELETE_CHUNK_SIZE) {
            $segmentIndex++;
            $state['reset_delete_cursor'] = 0;
        }

        $state['reset_user_segment_index'] = $segmentIndex;

        if ($segmentIndex >= count($segments)) {
            $state['reset_phase'] = $nextPhase;
            $state['reset_user_segment_index'] = 0;
        }

        $totalDeleted = (int) $state['cleanup'][$cleanupKey];
        $step = "{$label} {$deleted}건 삭제 · 누적 {$totalDeleted}건";
        $job = $this->saveResetProgress($job, $state, $step);
        $this->logger->warning($job, '데이터셋 초기화 청크가 처리되었습니다.', GenerationStage::Resetting->value, [
            'phase' => $state['reset_phase'],
            'deleted_in_chunk' => $deleted,
            'cleanup' => $state['cleanup'],
        ]);

        return true;
    }

    /**
     * @param  array<int>  $boardIds
     * @param  array{0: int, 1: int}  $userIdRange
     * @return array{deleted: int, selected: int, cursor: int}
     */
    private function deleteChunk(
        string $table,
        array $boardIds,
        array $userIdRange,
        ?string $datasetMarker,
        int $cursor
    ): array {
        $query = DB::table($table)
            ->whereBetween($table === 'users' ? 'id' : 'user_id', $userIdRange);

        if ($boardIds !== []) {
            $query->whereIn('board_id', $boardIds);
        }

        if ($datasetMarker !== null) {
            $query->where('admin_memo', $datasetMarker);
        }

        if ($cursor > 0) {
            $query->where('id', '>', $cursor);
        }

        $ids = $query
            ->orderBy('id')
            ->limit(self::DELETE_CHUNK_SIZE)
            ->pluck('id');

        if ($ids->isEmpty()) {
            return [
                'deleted' => 0,
                'selected' => 0,
                'cursor' => $cursor,
            ];
        }

        return [
            'deleted' => DB::table($table)
                ->whereIntegerInRaw('id', $ids->all())
                ->delete(),
            'selected' => $ids->count(),
            'cursor' => (int) $ids->last(),
        ];
    }

    /**
     * @param  array<string, mixed>  $state
     */
    private function advancePhase(GenerationJob $job, array $state, string $nextPhase, string $step): bool
    {
        $state['reset_phase'] = $nextPhase;
        $state['reset_user_segment_index'] = 0;
        $state['reset_delete_cursor'] = 0;
        $job = $this->saveResetProgress($job, $state, $step);
        $this->logger->warning($job, $step, GenerationStage::Resetting->value, [
            'phase' => $nextPhase,
            'cleanup' => $state['cleanup'],
        ]);

        return true;
    }

    /**
     * @param  array<string, mixed>  $state
     * @param  array<int>  $boardIds
     */
    private function completeBoardReset(GenerationJob $job, array $state, array $boardIds): bool
    {
        $summaries = $boardIds === []
            ? []
            : $this->boardCounterSyncService->syncBoardTotalsAfterDatasetDeletion($boardIds);

        $state['cleanup']['synced_boards'] = count($summaries);
        $state['reset_results'] = [
            'synced_boards' => count($summaries),
            'boards' => $summaries,
        ];
        $state['reset_phase'] = 'completed';
        $state['reset_finished_at'] = now()->toIso8601String();

        $job = $this->saveResetProgress($job, $state, '게시판 합계와 캐시 갱신 완료');
        $job = $this->progressReporter->markCompleted($job->refresh(), '데이터셋 초기화가 완료되었습니다.');
        $this->logger->warning($job, '데이터셋 초기화가 완료되었습니다.', GenerationStage::Resetting->value, $state['cleanup']);

        return false;
    }

    /**
     * @param  array<string, mixed>  $state
     */
    private function saveResetProgress(GenerationJob $job, array $state, string $step): GenerationJob
    {
        $job->runtime_state = $state;
        $job->current_stage = GenerationStage::Resetting;
        $job->current_step = $step;
        $job->progress_percent = $this->calculateResetProgress($job, $state);
        $job->last_heartbeat_at = now();
        $job->save();

        return $job->refresh();
    }

    /**
     * @param  array<string, mixed>  $state
     */
    private function calculateResetProgress(GenerationJob $job, array $state): float
    {
        $cleanup = $state['cleanup'] ?? [];
        $phase = (string) ($state['reset_phase'] ?? 'comments');
        $phaseOrder = [
            'comments' => 0,
            'posts' => 1,
            'users' => 2,
            'sync' => 3,
            'completed' => 4,
        ];
        $currentPhase = $phaseOrder[$phase] ?? 3;

        $comments = $this->resetRatio(
            (int) ($cleanup['deleted_comments'] ?? 0),
            (int) $job->generated_comments,
            $currentPhase > 0
        );
        $posts = $this->resetRatio(
            (int) ($cleanup['deleted_posts'] ?? 0),
            (int) $job->generated_posts,
            $currentPhase > 1
        );
        $users = $this->resetRatio(
            (int) ($cleanup['deleted_users'] ?? 0),
            (int) $job->generated_users,
            $currentPhase > 2
        );
        $boards = max(1, count($state['board_states'] ?? []));
        $sync = min(1, (int) ($cleanup['synced_boards'] ?? 0) / $boards);

        return min(99.5, round(($comments * 45) + ($posts * 40) + ($users * 10) + ($sync * 5), 2));
    }

    private function resetRatio(int $deleted, int $expected, bool $phaseCompleted): float
    {
        if ($expected <= 0) {
            return $phaseCompleted ? 1.0 : 0.0;
        }

        return min(1, $deleted / $expected);
    }

    private function authenticateRequester(GenerationJob $job): void
    {
        if (! $job->requested_by) {
            return;
        }

        $user = User::query()->find($job->requested_by);

        if ($user) {
            Auth::setUser($user);
        }
    }

    /**
     * @param  array<string, mixed>  $state
     * @return array<int>
     */
    private function resolveTargetBoardIds(array $state): array
    {
        return array_values(array_unique(array_map(
            fn (array $boardState) => (int) ($boardState['target_board_id'] ?? $boardState['board_id'] ?? 0),
            array_filter(
                $state['board_states'] ?? [],
                fn ($boardState) => is_array($boardState) && ! empty($boardState['target_board_id'] ?? $boardState['board_id'])
            )
        )));
    }
}
