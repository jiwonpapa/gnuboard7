<?php

namespace Modules\Sirsoft\Board\Observers;

use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Modules\Sirsoft\Board\Models\Post;

class PostAuthorTermObserver
{
    private ?bool $authorTermsAvailable = null;

    /**
     * 직접 Eloquent 생성 경로의 작성자 검색 사전을 보강합니다.
     */
    public function created(Post $post): void
    {
        $this->rememberAuthorTerm($post);
    }

    /**
     * 작성자명 또는 게시판이 변경된 경우 새 검색 사전 항목을 보강합니다.
     */
    public function updated(Post $post): void
    {
        if (! $post->wasChanged(['board_id', 'author_name'])) {
            return;
        }

        $this->rememberAuthorTerm($post);
    }

    private function rememberAuthorTerm(Post $post): void
    {
        if (
            ! $this->hasAuthorTermsTable()
            || empty($post->board_id)
            || $post->author_name === null
            || $post->author_name === ''
        ) {
            return;
        }

        try {
            DB::table('board_post_author_terms')->insertOrIgnore([
                'board_id' => $post->board_id,
                'author_name' => $post->author_name,
            ]);
        } catch (QueryException $exception) {
            $this->handleAuthorTermsWriteException($exception);
        }
    }

    private function hasAuthorTermsTable(): bool
    {
        return $this->authorTermsAvailable ??= Schema::hasTable('board_post_author_terms');
    }

    /**
     * 정확 복구 중 작성자 사전 테이블이 먼저 제거된 경합만 무시합니다.
     */
    private function handleAuthorTermsWriteException(QueryException $exception): void
    {
        $driverMessage = strtolower($exception->getPrevious()?->getMessage() ?? $exception->getMessage());
        $mentionsAuthorTermsTable = str_contains($driverMessage, 'board_post_author_terms');
        $missingTable = $mentionsAuthorTermsTable && (
            in_array((string) $exception->getCode(), ['42S02', '42P01', '1146'], true)
            || str_contains($driverMessage, 'no such table')
            || str_contains($driverMessage, "doesn't exist")
            || str_contains($driverMessage, 'undefined table')
        );
        if (! $missingTable) {
            throw $exception;
        }

        $this->authorTermsAvailable = false;
    }
}
