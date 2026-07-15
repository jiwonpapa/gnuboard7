<?php

namespace Modules\Sirsoft\Benchmark\Services\Generators;

use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\BatchInsertWriter;
use Modules\Sirsoft\Benchmark\Services\Support\SeededRandom;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticContentFactory;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticProfileFactory;
use Modules\Sirsoft\Benchmark\Services\Support\UserIdResolver;

class PostGenerator
{
    public function __construct(
        private BatchInsertWriter $batchInsertWriter,
        private UserIdResolver $userIdResolver,
        private SyntheticProfileFactory $profileFactory,
        private SyntheticContentFactory $contentFactory
    ) {}

    /**
     * @param  array<string, mixed>  $state
     * @return array<string, mixed>
     */
    public function generateChunk(GenerationJob $job, array $state): array
    {
        $options = $job->options ?? [];
        $boardPlans = $job->plan['board_plans'] ?? [];
        $boardStates = $state['board_states'] ?? [];
        $userSegments = $state['user_segments'] ?? [];
        $remainingBudget = max(1, (int) $options['chunk_size']);
        $batchSize = max(1, (int) $options['batch_size']);
        $boardIndex = (int) ($state['post_board_index'] ?? 0);

        while ($remainingBudget > 0 && $boardIndex < count($boardStates)) {
            $boardState = $boardStates[$boardIndex];
            $boardPlan = $boardPlans[$boardIndex] ?? null;

            if (! $boardPlan || empty($boardState['board_id'])) {
                $boardIndex++;

                continue;
            }

            $remainingPosts = max(0, (int) $boardPlan['target_posts'] - (int) $boardState['generated_posts']);

            if ($remainingPosts === 0) {
                $boardIndex++;

                continue;
            }

            $rng = new SeededRandom((int) $boardState['post_rng_state']);
            $chunkCount = min($remainingBudget, $remainingPosts);

            for ($cursor = 0; $cursor < $chunkCount; $cursor += $batchSize) {
                $size = min($batchSize, $chunkCount - $cursor);
                $rows = [];

                for ($index = 0; $index < $size; $index++) {
                    $sequence = (int) $boardState['generated_posts'] + $cursor + $index;
                    $authorOffset = $this->pickAuthorOffset($job, $rng);
                    $authorId = $this->userIdResolver->resolve($userSegments, $authorOffset);

                    if ($authorId === null) {
                        throw new \RuntimeException('게시글 작성자 user_id 를 해석할 수 없습니다.');
                    }

                    $createdAt = $this->contentFactory->makePostTimestamp($options['time_distribution'], $rng);
                    $rows[] = [
                        'board_id' => $boardState['board_id'],
                        'category' => $boardPlan['categories'] !== [] ? $rng->pick($boardPlan['categories']) : null,
                        'title' => $this->contentFactory->makePostTitle($boardPlan, $rng, $sequence),
                        'content' => $this->contentFactory->makePostContent($boardPlan, $rng),
                        'content_mode' => 'text',
                        'user_id' => $authorId,
                        'author_name' => $this->profileFactory->nicknameForOffset($authorOffset, (int) $job->seed),
                        'password' => null,
                        'ip_address' => $this->profileFactory->ipForOffset($authorOffset, (int) $job->seed),
                        'is_notice' => $sequence < 3 && $rng->chance(0.25),
                        'is_secret' => $rng->chance(0.03),
                        'status' => 'published',
                        'trigger_type' => 'user',
                        'action_logs' => null,
                        'view_count' => $rng->nextInt(0, 5000),
                        'parent_id' => null,
                        'depth' => 0,
                        'created_at' => $createdAt,
                        'updated_at' => $createdAt,
                        'deleted_at' => null,
                    ];
                }

                if (! $job->dry_run) {
                    $this->batchInsertWriter->insert('board_posts', $rows);
                }
            }

            $boardState['generated_posts'] += $chunkCount;
            $boardState['post_rng_state'] = $rng->getState();
            $boardStates[$boardIndex] = $boardState;
            $remainingBudget -= $chunkCount;

            if ($boardState['generated_posts'] >= $boardPlan['target_posts']) {
                $boardIndex++;
            }
        }

        $state['board_states'] = $boardStates;
        $state['post_board_index'] = $boardIndex;

        return $state;
    }

    private function pickAuthorOffset(GenerationJob $job, SeededRandom $rng): int
    {
        $totalUsers = max(1, (int) $job->total_users);
        $heavyCount = min($totalUsers, max(1, (int) ($job->plan['heavy_user_count'] ?? 1)));
        $heavyShare = (float) ($job->plan['heavy_user_share'] ?? 0.5);

        if ($totalUsers === 1) {
            return 0;
        }

        if ($heavyCount > 0 && $rng->chance($heavyShare)) {
            return $rng->nextInt(0, max(0, $heavyCount - 1));
        }

        return $rng->nextInt($heavyCount >= $totalUsers ? 0 : $heavyCount, $totalUsers - 1);
    }
}
