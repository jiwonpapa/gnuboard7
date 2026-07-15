<?php

namespace Modules\Sirsoft\Benchmark\Services;

use App\Models\User;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\WorkloadType;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\BoardCounterSyncService;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;
use Modules\Sirsoft\Benchmark\Services\Support\ProgressReporter;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticProfileFactory;

class DummyDataResetService
{
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
            $this->logger->warning($job, '데이터셋 초기화가 중단되었습니다.', 'resetting');

            return false;
        }

        $job->status = GenerationJobStatus::Running;
        $job->save();

        if ($job->workload_type === WorkloadType::Commerce) {
            return $this->commerceDatasetResetService->processNextChunk($job->fresh());
        }

        $state = $job->runtime_state ?? [];
        $cleanup = $state['cleanup'] ?? [
            'deleted_posts' => 0,
            'deleted_comments' => 0,
            'deleted_users' => 0,
        ];
        $segments = $state['user_segments'] ?? [];
        $segmentIndex = (int) ($state['reset_user_segment_index'] ?? 0);
        $processedSegments = 0;
        $boardIds = $this->resolveTargetBoardIds($state);

        while ($segmentIndex < count($segments) && $processedSegments < 10) {
            $segment = $segments[$segmentIndex];
            $range = [
                (int) $segment['first_id'],
                (int) $segment['first_id'] + (int) $segment['count'] - 1,
            ];

            if ($boardIds !== []) {
                $cleanup['deleted_comments'] += DB::table('board_comments')
                    ->whereIn('board_id', $boardIds)
                    ->whereBetween('user_id', $range)
                    ->delete();

                $cleanup['deleted_posts'] += DB::table('board_posts')
                    ->whereIn('board_id', $boardIds)
                    ->whereBetween('user_id', $range)
                    ->delete();
            }

            $cleanup['deleted_users'] += DB::table('users')
                ->whereBetween('id', $range)
                ->where('admin_memo', $this->profileFactory->datasetMarker($job))
                ->delete();

            $segmentIndex++;
            $processedSegments++;
        }

        $state['reset_user_segment_index'] = $segmentIndex;
        $state['cleanup'] = $cleanup;

        if ($segmentIndex >= count($segments)) {
            if ($boardIds !== []) {
                $state['cleanup']['synced_boards'] = count($this->boardCounterSyncService->syncBoardsWithoutDatasetVerification($boardIds));
            }

            $job = $this->progressReporter->heartbeat($job, [
                'runtime_state' => $state,
            ], '데이터셋 초기화 완료');
            $this->progressReporter->markCompleted($job->refresh(), '데이터셋 초기화가 완료되었습니다.');
            $this->logger->warning($job->refresh(), '데이터셋 초기화가 완료되었습니다.', 'resetting', $cleanup);

            return false;
        }

        $job = $this->progressReporter->heartbeat($job, [
            'runtime_state' => $state,
            'current_stage' => 'resetting',
        ], '데이터셋 초기화 진행 중');
        $this->logger->warning($job, '데이터셋 초기화 청크가 처리되었습니다.', 'resetting', $cleanup);

        return true;
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
     * @return array<int, int>
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
