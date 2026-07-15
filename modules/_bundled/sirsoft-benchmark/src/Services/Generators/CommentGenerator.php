<?php

namespace Modules\Sirsoft\Benchmark\Services\Generators;

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\BatchInsertWriter;
use Modules\Sirsoft\Benchmark\Services\Support\SeededRandom;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticContentFactory;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticProfileFactory;
use Modules\Sirsoft\Benchmark\Services\Support\UserIdResolver;

class CommentGenerator
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
        $remainingBudget = max(100, (int) ($options['comment_chunk_size'] ?? $options['chunk_size'] ?? 100));
        $batchSize = max(100, (int) ($options['comment_batch_size'] ?? $options['batch_size'] ?? 100));
        $boardIndex = (int) ($state['comment_board_index'] ?? 0);

        while ($remainingBudget > 0 && $boardIndex < count($boardStates)) {
            $boardState = $boardStates[$boardIndex];
            $boardPlan = $boardPlans[$boardIndex] ?? null;

            if (! $boardPlan || empty($boardState['board_id'])) {
                $boardIndex++;

                continue;
            }

            $targetPosts = (int) ($boardPlan['target_posts'] ?? 0);

            if ($targetPosts === 0) {
                $boardIndex++;

                continue;
            }

            $posts = DB::table('board_posts')
                ->select(['id', 'user_id', 'created_at'])
                ->where('board_id', $boardState['board_id'])
                ->where(function ($query) use ($userSegments) {
                    foreach ($userSegments as $segment) {
                        $query->orWhereBetween('user_id', [
                            (int) $segment['first_id'],
                            (int) $segment['first_id'] + (int) $segment['count'] - 1,
                        ]);
                    }
                })
                ->where('id', '>', (int) ($boardState['comment_source_cursor'] ?? 0))
                ->orderBy('id')
                ->limit($remainingBudget)
                ->get();

            if ($posts->isEmpty()) {
                $boardIndex++;

                continue;
            }

            $rng = new SeededRandom((int) $boardState['comment_rng_state']);
            $commentRows = [];
            $processedPosts = 0;
            $generatedComments = 0;

            foreach ($posts as $post) {
                $processedPosts++;
                $count = $this->decideCommentCount($boardPlan, $options, $rng);

                for ($commentIndex = 0; $commentIndex < $count; $commentIndex++) {
                    $authorOffset = $this->pickAuthorOffset($job, $rng);
                    $authorId = $this->resolveDifferentUserId($userSegments, $authorOffset, (int) $post->user_id, $rng);

                    if ($authorId === null) {
                        continue;
                    }

                    $commentRows[] = [
                        'board_id' => $boardState['board_id'],
                        'post_id' => $post->id,
                        'user_id' => $authorId,
                        'parent_id' => null,
                        'author_name' => $this->profileFactory->nicknameForOffset($authorOffset, (int) $job->seed),
                        'password' => null,
                        'content' => $this->contentFactory->makeCommentContent($rng),
                        'is_secret' => $rng->chance(0.02),
                        'status' => 'published',
                        'trigger_type' => 'user',
                        'action_logs' => null,
                        'depth' => 0,
                        'ip_address' => $this->profileFactory->ipForOffset($authorOffset, (int) $job->seed),
                        'created_at' => $this->contentFactory->makeCommentTimestamp($post->created_at, $rng),
                        'updated_at' => $this->contentFactory->makeCommentTimestamp($post->created_at, $rng),
                        'deleted_at' => null,
                    ];
                    $generatedComments++;

                    if (count($commentRows) >= $batchSize) {
                        if (! $job->dry_run) {
                            $this->batchInsertWriter->insert('board_comments', $commentRows);
                        }
                        $commentRows = [];
                    }
                }

                $boardState['comment_source_cursor'] = (int) $post->id;
            }

            if ($commentRows !== [] && ! $job->dry_run) {
                $this->batchInsertWriter->insert('board_comments', $commentRows);
            }

            $boardState['generated_comments'] += $generatedComments;
            $boardState['processed_comment_posts'] = (int) ($boardState['processed_comment_posts'] ?? 0) + $processedPosts;
            $boardState['comment_rng_state'] = $rng->getState();
            $boardStates[$boardIndex] = $boardState;
            $remainingBudget -= $processedPosts;

            if ((int) $boardState['processed_comment_posts'] >= $targetPosts) {
                $boardIndex++;
            }
        }

        $state['board_states'] = $boardStates;
        $state['comment_board_index'] = $boardIndex;

        return $state;
    }

    private function decideCommentCount(array $boardPlan, array $options, SeededRandom $rng): int
    {
        $max = (int) ($options['max_comments_per_post'] ?? 0);

        if ($max <= 0) {
            return 0;
        }

        if (! $rng->chance((float) ($boardPlan['comment_rate'] ?? $options['comment_rate'] ?? 0))) {
            return 0;
        }

        $avg = max(1.0, (float) ($options['avg_comments_per_post'] ?? 1));
        $ceiling = max(1, min($max, (int) ceil($avg * 2.5)));
        $count = $rng->nextInt(1, $ceiling);

        if ($rng->chance(0.08)) {
            $count = min($max, $count + (int) ceil($avg));
        }

        return min($max, $count);
    }

    /**
     * @param  array<int, array<string, int>>  $segments
     */
    private function resolveDifferentUserId(array $segments, int $offset, int $postUserId, SeededRandom $rng): ?int
    {
        for ($attempt = 0; $attempt < 4; $attempt++) {
            $userId = $this->userIdResolver->resolve($segments, $offset);

            if ($userId !== null && $userId !== $postUserId) {
                return $userId;
            }

            $offset = $rng->nextInt(0, max(0, $segments !== [] ? end($segments)['offset_end'] : 0));
        }

        return $this->userIdResolver->resolve($segments, $offset);
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
