<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Board\Models\Board;

class BoardCounterSyncService
{
    private ?bool $authorTermsAvailable = null;

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

        $this->syncBoardDerivedState($boardId);

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
            $this->syncBoardDerivedState($boardId);
            $summaries[] = $this->syncBoardTotals($boardId);
        }

        return $summaries;
    }

    /**
     * 벤치마크 데이터 삭제 후 게시판 합계만 다시 계산합니다.
     *
     * 벤치마크 댓글은 같은 작업에서 생성한 게시글에만 연결되므로 해당 게시글과
     * 댓글을 모두 삭제한 뒤 남은 게시글의 comments_count 전체 재계산은 불필요합니다.
     * 수백만 건 UPDATE/GROUP BY를 생략해 초기화 완료 지연을 방지합니다.
     *
     * @param  array<int>  $boardIds
     * @return array<int, array<string, int>>
     */
    public function syncBoardTotalsAfterDatasetDeletion(array $boardIds): array
    {
        $summaries = [];

        foreach ($this->normalizeBoardIds($boardIds) as $boardId) {
            $this->pruneOrphanAuthorTermsForBoard($boardId);
            $summaries[] = $this->syncBoardTotals($boardId);
        }

        return $summaries;
    }

    /**
     * @return array<string, int>
     */
    private function syncBoardTotals(int $boardId): array
    {
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

        return [
            'board_id' => $boardId,
            'posts_count' => $postsCount,
            'comments_count' => $commentsCount,
        ];
    }

    /**
     * 벌크 적재가 우회한 게시글 파생 상태를 게시판 단위로 보강합니다.
     */
    private function syncBoardDerivedState(int $boardId): void
    {
        $this->syncAuthorTermsForBoard($boardId);
        $this->syncPostCommentCounts($boardId);
    }

    private function syncAuthorTermsForBoard(int $boardId): void
    {
        if (! $this->hasAuthorTermsTable()) {
            return;
        }

        try {
            DB::table('board_post_author_terms')->insertOrIgnoreUsing(
                ['board_id', 'author_name'],
                DB::table('board_posts')
                    ->select(['board_id', 'author_name'])
                    ->where('board_id', $boardId)
                    ->whereNotNull('author_name')
                    ->where('author_name', '<>', '')
                    ->distinct()
            );
        } catch (QueryException $exception) {
            if (! $this->isMissingAuthorTermsTable($exception)) {
                throw $exception;
            }

            $this->authorTermsAvailable = false;
        }
    }

    private function pruneOrphanAuthorTermsForBoard(int $boardId): void
    {
        if (! $this->hasAuthorTermsTable()) {
            return;
        }

        try {
            DB::table('board_post_author_terms')
                ->where('board_id', $boardId)
                ->whereNotExists(function ($query) {
                    $query->selectRaw('1')
                        ->from('board_posts')
                        ->whereColumn('board_posts.board_id', 'board_post_author_terms.board_id')
                        ->whereColumn('board_posts.author_name', 'board_post_author_terms.author_name')
                        ->whereNull('board_posts.deleted_at');
                })
                ->delete();
        } catch (QueryException $exception) {
            if (! $this->isMissingAuthorTermsTable($exception)) {
                throw $exception;
            }

            $this->authorTermsAvailable = false;
        }
    }

    private function hasAuthorTermsTable(): bool
    {
        return $this->authorTermsAvailable ??= Schema::hasTable('board_post_author_terms');
    }

    private function isMissingAuthorTermsTable(QueryException $exception): bool
    {
        $driverMessage = strtolower($exception->getPrevious()?->getMessage() ?? $exception->getMessage());

        return str_contains($driverMessage, 'board_post_author_terms') && (
            in_array((string) $exception->getCode(), ['42S02', '42P01', '1146'], true)
            || str_contains($driverMessage, 'no such table')
            || str_contains($driverMessage, "doesn't exist")
            || str_contains($driverMessage, 'undefined table')
        );
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
