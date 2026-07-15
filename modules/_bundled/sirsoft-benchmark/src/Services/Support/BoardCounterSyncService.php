<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Board\Models\Board;

class BoardCounterSyncService
{
    public function __construct(
        private SyntheticProfileFactory $profileFactory,
        private BoardCacheInvalidator $boardCacheInvalidator
    ) {}

    /**
     * @return array<string, int|string|bool|null>
     */
    public function syncBoard(GenerationJob $job, int $boardId, string $boardSlug, int $expectedDatasetPosts, int $expectedDatasetComments): array
    {
        if ($boardId <= 0) {
            throw new \InvalidArgumentException('카운트 동기화 대상 board_id 가 올바르지 않습니다.');
        }

        $this->syncPostCommentCounts($boardId);

        $postsCount = (int) DB::table('board_posts')
            ->where('board_id', $boardId)
            ->whereNull('deleted_at')
            ->count();

        $commentsCount = (int) DB::table('board_comments')
            ->where('board_id', $boardId)
            ->whereNull('deleted_at')
            ->count();

        Board::query()
            ->where('id', $boardId)
            ->update([
                'posts_count' => $postsCount,
                'comments_count' => $commentsCount,
                'updated_at' => now(),
            ]);

        $this->boardCacheInvalidator->invalidate($boardId, $boardSlug);

        $datasetMarker = $this->profileFactory->datasetMarker($job);

        $datasetPosts = (int) DB::table('board_posts')
            ->join('users', 'board_posts.user_id', '=', 'users.id')
            ->where('board_posts.board_id', $boardId)
            ->whereNull('board_posts.deleted_at')
            ->where('users.admin_memo', $datasetMarker)
            ->count();

        $datasetComments = (int) DB::table('board_comments')
            ->join('users', 'board_comments.user_id', '=', 'users.id')
            ->where('board_comments.board_id', $boardId)
            ->whereNull('board_comments.deleted_at')
            ->where('users.admin_memo', $datasetMarker)
            ->count();

        return [
            'board_id' => $boardId,
            'slug' => $boardSlug,
            'posts_count' => $postsCount,
            'comments_count' => $commentsCount,
            'expected_dataset_posts' => $expectedDatasetPosts,
            'actual_dataset_posts' => $datasetPosts,
            'expected_dataset_comments' => $expectedDatasetComments,
            'actual_dataset_comments' => $datasetComments,
            'dataset_posts_match' => $datasetPosts === $expectedDatasetPosts,
            'dataset_comments_match' => $datasetComments === $expectedDatasetComments,
        ];
    }

    /**
     * @param  array<int>  $boardIds
     * @return array<int, array<string, int|string|bool|null>>
     */
    public function syncBoardsWithoutDatasetVerification(array $boardIds): array
    {
        $summaries = [];

        foreach ($this->normalizeBoardIds($boardIds) as $boardId) {
            $this->syncPostCommentCounts($boardId);

            $board = Board::query()->find($boardId, ['id', 'slug']);

            $postsCount = (int) DB::table('board_posts')
                ->where('board_id', $boardId)
                ->whereNull('deleted_at')
                ->count();

            $commentsCount = (int) DB::table('board_comments')
                ->where('board_id', $boardId)
                ->whereNull('deleted_at')
                ->count();

            Board::query()
                ->where('id', $boardId)
                ->update([
                    'posts_count' => $postsCount,
                    'comments_count' => $commentsCount,
                    'updated_at' => now(),
                ]);

            $this->boardCacheInvalidator->invalidate($boardId, $board?->slug);

            $summaries[] = [
                'board_id' => $boardId,
                'posts_count' => $postsCount,
                'comments_count' => $commentsCount,
            ];
        }

        return $summaries;
    }

    private function syncPostCommentCounts(int $boardId): void
    {
        if (DB::getDriverName() === 'mysql') {
            $prefix = DB::getTablePrefix();
            $postsTable = $prefix.'board_posts';
            $commentsTable = $prefix.'board_comments';

            DB::statement(
                "UPDATE {$postsTable} AS posts
                 LEFT JOIN (
                    SELECT post_id, COUNT(*) AS comments_count
                    FROM {$commentsTable}
                    WHERE board_id = ? AND deleted_at IS NULL
                    GROUP BY post_id
                 ) AS counts ON counts.post_id = posts.id
                 SET posts.comments_count = COALESCE(counts.comments_count, 0)
                 WHERE posts.board_id = ?",
                [$boardId, $boardId]
            );

            return;
        }

        DB::table('board_posts')
            ->where('board_id', $boardId)
            ->update(['comments_count' => 0]);

        DB::table('board_comments')
            ->select('post_id', DB::raw('COUNT(*) AS comments_count'))
            ->where('board_id', $boardId)
            ->whereNull('deleted_at')
            ->groupBy('post_id')
            ->orderBy('post_id')
            ->chunk(500, function ($rows) {
                foreach ($rows as $row) {
                    DB::table('board_posts')
                        ->where('id', (int) $row->post_id)
                        ->update(['comments_count' => (int) $row->comments_count]);
                }
            });
    }

    /**
     * @param  array<int>  $boardIds
     * @return array<int>
     */
    private function normalizeBoardIds(array $boardIds): array
    {
        return array_values(array_unique(array_filter(
            array_map(fn ($boardId) => (int) $boardId, $boardIds),
            fn (int $boardId) => $boardId > 0
        )));
    }
}
