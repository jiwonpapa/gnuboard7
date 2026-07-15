<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Board\Models\Board;

class DatasetPlanner
{
    /**
     * @return array{plan: array<string, mixed>, runtime_state: array<string, mixed>}
     */
    public function build(GenerationJob $job, array $options): array
    {
        $seed = (int) ($options['seed'] ?? $job->seed ?? $job->id);
        $rng = new SeededRandom($seed);
        $boardPlans = $this->buildBoardPlans($job->dataset_slug, $options, $rng);
        $estimatedComments = array_sum(array_column($boardPlans, 'estimated_comments'));

        $plan = [
            'seed' => $seed,
            'activity_profile' => $options['activity_profile'],
            'time_distribution' => $options['time_distribution'],
            'heavy_user_count' => $this->resolveHeavyUserCount((int) $options['total_users'], $options['activity_profile']),
            'heavy_user_share' => $this->resolveHeavyUserShare($options['activity_profile']),
            'board_plans' => $boardPlans,
            'estimated_comments' => $estimatedComments,
            'estimated_batches' => [
                'users' => (int) ceil($options['total_users'] / max(1, $options['batch_size'])),
                'boards' => count($boardPlans),
                'posts' => (int) ceil($options['total_posts'] / max(1, $options['batch_size'])),
                'comment_scans' => (int) ceil($options['total_posts'] / max(1, $options['comment_chunk_size'] ?? $options['chunk_size'])),
            ],
        ];

        $runtimeState = [
            'next_user_offset' => 0,
            'user_segments' => [],
            'board_states' => array_map(
                fn (array $boardPlan) => [
                    'index' => $boardPlan['index'],
                    'slug' => $boardPlan['slug'],
                    'target_board_id' => (int) $boardPlan['board_id'],
                    'board_id' => null,
                    'generated_posts' => 0,
                    'generated_comments' => 0,
                    'processed_comment_posts' => 0,
                    'post_rng_state' => $this->deriveSeed($seed, "post:{$boardPlan['index']}"),
                    'comment_rng_state' => $this->deriveSeed($seed, "comment:{$boardPlan['index']}"),
                    'comment_source_cursor' => 0,
                ],
                $boardPlans
            ),
            'post_board_index' => 0,
            'comment_board_index' => 0,
            'sync_board_index' => 0,
            'sync_results' => [
                'synced_boards' => 0,
                'boards' => [],
                'verification' => null,
            ],
            'reset_board_index' => 0,
            'reset_user_segment_index' => 0,
        ];

        return [
            'plan' => $plan,
            'runtime_state' => $runtimeState,
        ];
    }

    /**
     * @return array<int, array<string, mixed>>
     */
    private function buildBoardPlans(string $datasetSlug, array $options, SeededRandom $rng): array
    {
        $selectedBoards = $options['selected_boards'] ?? [];
        $boardIds = array_values(array_unique(array_map(
            fn (array $boardTarget) => (int) ($boardTarget['board_id'] ?? 0),
            $selectedBoards
        )));
        $boards = Board::query()
            ->whereIn('id', $boardIds)
            ->get()
            ->keyBy('id');
        $plans = [];

        foreach ($selectedBoards as $index => $selectedBoard) {
            $boardId = (int) ($selectedBoard['board_id'] ?? 0);
            /** @var Board|null $board */
            $board = $boards->get($boardId);

            if (! $board) {
                throw new \RuntimeException("선택한 게시판 #{$boardId} 을(를) 찾을 수 없습니다.");
            }

            $postCount = max(0, (int) ($selectedBoard['target_posts'] ?? 0));
            $commentRate = $board->use_comment
                ? $this->varyCommentRate((float) $options['comment_rate'], $rng)
                : 0.0;
            $estimatedComments = (int) round($postCount * $commentRate * (float) $options['avg_comments_per_post']);

            $plans[] = [
                'index' => $index,
                'board_id' => $board->id,
                'slug' => $board->slug,
                'name' => $board->getLocalizedName(),
                'description' => $board->description,
                'categories' => is_array($board->categories) ? $board->categories : [],
                'type' => (string) $board->type,
                'is_active' => (bool) $board->is_active,
                'use_comment' => (bool) $board->use_comment,
                'use_reply' => (bool) $board->use_reply,
                'target_posts' => $postCount,
                'estimated_comments' => $estimatedComments,
                'comment_rate' => $commentRate,
            ];
        }

        return $plans;
    }

    private function resolveHeavyUserCount(int $totalUsers, string $activityProfile): int
    {
        if ($totalUsers <= 0) {
            return 0;
        }

        $ratio = match ($activityProfile) {
            'extreme' => 0.02,
            'balanced' => 0.08,
            default => 0.05,
        };

        return max(1, (int) floor($totalUsers * $ratio));
    }

    private function resolveHeavyUserShare(string $activityProfile): float
    {
        return match ($activityProfile) {
            'extreme' => 0.78,
            'balanced' => 0.45,
            default => 0.62,
        };
    }

    private function varyCommentRate(float $baseRate, SeededRandom $rng): float
    {
        $min = max(0.01, $baseRate * 0.75);
        $max = min(1.0, $baseRate * 1.25);

        return round($min + (($max - $min) * $rng->nextFloat()), 4);
    }

    private function deriveSeed(int $seed, string $suffix): int
    {
        return max(1, abs(crc32($seed.'|'.$suffix)));
    }
}
