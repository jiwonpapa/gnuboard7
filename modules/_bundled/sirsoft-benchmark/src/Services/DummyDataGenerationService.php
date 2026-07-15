<?php

namespace Modules\Sirsoft\Benchmark\Services;

use App\Models\User;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Enums\WorkloadType;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Generators\BoardGenerator;
use Modules\Sirsoft\Benchmark\Services\Generators\CommentGenerator;
use Modules\Sirsoft\Benchmark\Services\Generators\PostGenerator;
use Modules\Sirsoft\Benchmark\Services\Generators\UserGenerator;
use Modules\Sirsoft\Benchmark\Services\Support\BoardCounterSyncService;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;
use Modules\Sirsoft\Benchmark\Services\Support\ProgressReporter;

class DummyDataGenerationService
{
    public function __construct(
        private UserGenerator $userGenerator,
        private BoardGenerator $boardGenerator,
        private PostGenerator $postGenerator,
        private CommentGenerator $commentGenerator,
        private BoardCounterSyncService $boardCounterSyncService,
        private CommerceGenerationService $commerceGenerationService,
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

        try {
            if ($job->status === GenerationJobStatus::Stopping) {
                $this->progressReporter->markStopped($job, '중단 요청을 반영했습니다.');
                $this->logger->warning($job, '작업이 중단되었습니다.', $job->current_stage->value);

                return false;
            }

            if ($job->dry_run) {
                $job->status = GenerationJobStatus::Running;
                $job->started_at = $job->started_at ?? now();
                $job->save();
                $this->progressReporter->markCompleted($job, 'dry-run 검증이 완료되었습니다.');
                $this->logger->info($job, 'dry-run 검증이 완료되었습니다.', GenerationStage::Completed->value, [
                    'estimated_comments' => $job->estimated_comments,
                ]);

                return false;
            }

            if ($job->status !== GenerationJobStatus::Running) {
                $job->status = GenerationJobStatus::Running;
                $job->started_at = $job->started_at ?? now();
                $job->save();
            }

            if ($job->workload_type === WorkloadType::Commerce) {
                return $this->commerceGenerationService->processNextChunk($job->fresh());
            }

            return match ($job->current_stage) {
                GenerationStage::Users => $this->processUsers($job),
                GenerationStage::Boards => $this->processBoards($job),
                GenerationStage::Posts => $this->processPosts($job),
                GenerationStage::Comments => $this->processComments($job),
                GenerationStage::Syncing => $this->processSyncing($job),
                GenerationStage::Completed => false,
                GenerationStage::Planning,
                GenerationStage::ImagePool,
                GenerationStage::Categories,
                GenerationStage::Brands,
                GenerationStage::Products,
                GenerationStage::Verifying,
                GenerationStage::Resetting => false,
            };
        } catch (\Throwable $e) {
            $job = $this->progressReporter->markFailed($job->refresh(), $e->getMessage());
            $this->logger->error($job, '작업 처리 중 예외가 발생했습니다.', $job->current_stage->value, [
                'error' => $e->getMessage(),
            ]);

            throw $e;
        }
    }

    private function processUsers(GenerationJob $job): bool
    {
        $before = (int) $job->generated_users;
        $job = DB::transaction(function () use ($job, $before) {
            $job = $job->fresh();
            $state = $job->runtime_state ?? [];
            $state = $this->userGenerator->generateChunk($job, $state);
            $after = (int) ($state['next_user_offset'] ?? $before);

            return $this->progressReporter->heartbeat($job, [
                'runtime_state' => $state,
                'generated_users' => $after,
                'current_stage' => $after >= (int) $job->total_users ? GenerationStage::Boards : GenerationStage::Users,
            ], "회원 생성 {$after}/{$job->total_users}");
        });
        $after = (int) $job->generated_users;

        $this->logger->info($job, '회원 청크가 처리되었습니다.', GenerationStage::Users->value, [
            'chunk_users' => $after - $before,
            'generated_users' => $after,
        ]);

        return true;
    }

    private function processBoards(GenerationJob $job): bool
    {
        $state = $job->runtime_state ?? [];
        $before = (int) $job->generated_boards;
        $state = $this->boardGenerator->generateChunk($job, $state);
        $after = count(array_filter($state['board_states'] ?? [], fn (array $boardState) => ! empty($boardState['board_id'])));
        $nextStage = $after >= (int) $job->total_boards ? GenerationStage::Posts : GenerationStage::Boards;

        $job = $this->progressReporter->heartbeat($job, [
            'runtime_state' => $state,
            'generated_boards' => $after,
            'current_stage' => $nextStage,
        ], "게시판 대상 확인 {$after}/{$job->total_boards}");

        $this->logger->info($job, '게시판 청크가 처리되었습니다.', GenerationStage::Boards->value, [
            'chunk_boards' => $after - $before,
            'generated_boards' => $after,
        ]);

        return true;
    }

    private function processPosts(GenerationJob $job): bool
    {
        $before = (int) $job->generated_posts;
        $job = DB::transaction(function () use ($job) {
            $job = $job->fresh();
            $state = $job->runtime_state ?? [];
            $state = $this->postGenerator->generateChunk($job, $state);
            $after = $this->sumBoardMetric($state, 'generated_posts');
            $nextStage = $after >= (int) $job->total_posts ? GenerationStage::Comments : GenerationStage::Posts;

            return $this->progressReporter->heartbeat($job, [
                'runtime_state' => $state,
                'generated_posts' => $after,
                'current_stage' => $nextStage,
            ], "게시글 생성 {$after}/{$job->total_posts}");
        });
        $after = (int) $job->generated_posts;

        $this->logger->info($job, '게시글 청크가 처리되었습니다.', GenerationStage::Posts->value, [
            'chunk_posts' => $after - $before,
            'generated_posts' => $after,
        ]);

        return true;
    }

    private function processComments(GenerationJob $job): bool
    {
        $beforeComments = (int) $job->generated_comments;
        $beforeCandidates = (int) $job->processed_comment_candidates;
        $job = DB::transaction(function () use ($job) {
            $job = $job->fresh();
            $state = $job->runtime_state ?? [];
            $state = $this->commentGenerator->generateChunk($job, $state);
            $afterComments = $this->sumBoardMetric($state, 'generated_comments');
            $afterCandidates = $this->sumBoardMetric($state, 'processed_comment_posts');
            $completed = $afterCandidates >= (int) $job->total_posts;

            return $this->progressReporter->heartbeat($job, [
                'runtime_state' => $state,
                'generated_comments' => $afterComments,
                'processed_comment_candidates' => $afterCandidates,
                'current_stage' => $completed ? GenerationStage::Syncing : GenerationStage::Comments,
            ], "댓글 생성 {$afterComments}건 / 스캔 {$afterCandidates}/{$job->total_posts}");
        });
        $afterComments = (int) $job->generated_comments;
        $afterCandidates = (int) $job->processed_comment_candidates;
        $completed = $afterCandidates >= (int) $job->total_posts;

        $this->logger->info($job, '댓글 청크가 처리되었습니다.', GenerationStage::Comments->value, [
            'chunk_comments' => $afterComments - $beforeComments,
            'chunk_candidates' => $afterCandidates - $beforeCandidates,
            'generated_comments' => $afterComments,
        ]);

        if ($completed) {
            $job = $this->progressReporter->heartbeat($job->refresh(), [
                'current_stage' => GenerationStage::Syncing,
            ], '게시판 카운트 동기화 대기 중');
            $this->logger->info($job, '댓글 적재가 완료되어 게시판 카운트 동기화를 시작합니다.', GenerationStage::Syncing->value);
        }

        return true;
    }

    private function processSyncing(GenerationJob $job): bool
    {
        $job = DB::transaction(function () use ($job) {
            $job = $job->fresh();
            $state = $job->runtime_state ?? [];
            $boardStates = $state['board_states'] ?? [];
            $boardPlans = $job->plan['board_plans'] ?? [];
            $syncIndex = (int) ($state['sync_board_index'] ?? 0);
            $syncResults = $state['sync_results'] ?? [
                'synced_boards' => 0,
                'boards' => [],
                'verification' => null,
            ];
            $processed = 0;
            $syncLimit = 1;

            while ($syncIndex < count($boardStates) && $processed < $syncLimit) {
                $boardState = $boardStates[$syncIndex] ?? [];
                $boardPlan = $boardPlans[$syncIndex] ?? [];
                $boardId = (int) ($boardState['board_id'] ?? $boardState['target_board_id'] ?? 0);

                if ($boardId <= 0 || $boardPlan === []) {
                    $syncIndex++;

                    continue;
                }

                $summary = $this->boardCounterSyncService->syncBoard(
                    $job,
                    $boardId,
                    (string) ($boardPlan['slug'] ?? "board-{$boardId}"),
                    (int) ($boardState['generated_posts'] ?? 0),
                    (int) ($boardState['generated_comments'] ?? 0)
                );

                $syncResults['boards'][(string) $boardId] = $summary;
                $syncIndex++;
                $processed++;
            }

            $syncResults['synced_boards'] = count($syncResults['boards'] ?? []);
            if ($syncIndex >= count($boardStates)) {
                $syncResults['verification'] = $this->buildVerificationSummary($job, $syncResults['boards'] ?? []);
            }

            $state['sync_board_index'] = $syncIndex;
            $state['sync_results'] = $syncResults;

            return $this->progressReporter->heartbeat($job, [
                'runtime_state' => $state,
                'current_stage' => GenerationStage::Syncing,
            ], "게시판 카운트 동기화 {$syncResults['synced_boards']}/{$job->total_boards}");
        });

        $syncResults = $job->runtime_state['sync_results'] ?? [];
        $verification = $syncResults['verification'] ?? null;
        $completed = (int) ($job->runtime_state['sync_board_index'] ?? 0) >= count($job->runtime_state['board_states'] ?? []);

        $this->logger->info($job, '게시판 카운트 동기화 청크가 처리되었습니다.', GenerationStage::Syncing->value, [
            'synced_boards' => (int) ($syncResults['synced_boards'] ?? 0),
            'total_boards' => (int) $job->total_boards,
        ]);

        if (! $completed) {
            return true;
        }

        $completionMessage = ($verification['status'] ?? 'unknown') === 'passed'
            ? '더미데이터 생성과 카운트 동기화가 완료되었습니다.'
            : '더미데이터 생성은 완료되었지만 검증 경고가 있습니다.';

        $job = $this->progressReporter->markCompleted($job->refresh(), $completionMessage);
        $this->logger->info($job, $completionMessage, GenerationStage::Completed->value, [
            'verification' => $verification,
        ]);

        return false;
    }

    /**
     * @param  array<string, mixed>  $state
     */
    private function sumBoardMetric(array $state, string $key): int
    {
        return array_sum(array_map(
            fn (array $boardState) => (int) ($boardState[$key] ?? 0),
            $state['board_states'] ?? []
        ));
    }

    /**
     * @param  array<string, array<string, mixed>>  $boardSummaries
     * @return array<string, mixed>
     */
    private function buildVerificationSummary(GenerationJob $job, array $boardSummaries): array
    {
        $actualPosts = array_sum(array_map(
            fn (array $summary) => (int) ($summary['actual_dataset_posts'] ?? 0),
            $boardSummaries
        ));
        $actualComments = array_sum(array_map(
            fn (array $summary) => (int) ($summary['actual_dataset_comments'] ?? 0),
            $boardSummaries
        ));
        $expectedPosts = (int) $job->generated_posts;
        $expectedComments = (int) $job->generated_comments;
        $status = $actualPosts === $expectedPosts && $actualComments === $expectedComments
            ? 'passed'
            : 'warning';

        return [
            'status' => $status,
            'synced_boards' => count($boardSummaries),
            'expected_dataset_posts' => $expectedPosts,
            'actual_dataset_posts' => $actualPosts,
            'expected_dataset_comments' => $expectedComments,
            'actual_dataset_comments' => $actualComments,
            'posts_match' => $actualPosts === $expectedPosts,
            'comments_match' => $actualComments === $expectedComments,
        ];
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
}
