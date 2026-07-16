<?php

namespace Modules\Sirsoft\Board\Tests\Unit\Observers;

require_once __DIR__.'/../../ModuleTestCase.php';

use Illuminate\Database\QueryException;
use Mockery;
use Modules\Sirsoft\Board\Models\Post;
use Modules\Sirsoft\Board\Observers\PostAuthorTermObserver;
use Modules\Sirsoft\Board\Tests\ModuleTestCase;
use ReflectionMethod;
use ReflectionProperty;
use RuntimeException;

class PostAuthorTermObserverTest extends ModuleTestCase
{
    protected function tearDown(): void
    {
        Mockery::close();
        parent::tearDown();
    }

    public function test_missing_author_terms_table_race_is_ignored(): void
    {
        $observer = new PostAuthorTermObserver;
        $exception = $this->queryException(
            "Table 'g7_testing.g7_board_post_author_terms' doesn't exist",
            1146,
        );

        $this->invokeWriteExceptionHandler($observer, $exception);

        $this->assertFalse($this->authorTermsAvailable($observer));
    }

    public function test_missing_source_table_error_is_rethrown(): void
    {
        $observer = new PostAuthorTermObserver;
        $exception = $this->queryException(
            "Table 'g7_testing.g7_board_posts' doesn't exist",
            1146,
        );

        $this->expectExceptionObject($exception);

        $this->invokeWriteExceptionHandler($observer, $exception);
    }

    public function test_unrelated_update_does_not_write_author_term(): void
    {
        $post = Mockery::mock(Post::class);
        $post->shouldReceive('wasChanged')
            ->once()
            ->with(['board_id', 'author_name'])
            ->andReturnFalse();

        (new PostAuthorTermObserver)->updated($post);

        $this->addToAssertionCount(1);
    }

    public function test_non_table_database_error_is_rethrown(): void
    {
        $observer = new PostAuthorTermObserver;
        $exception = $this->queryException('Deadlock found when trying to get lock', 1213);

        $this->expectExceptionObject($exception);

        $this->invokeWriteExceptionHandler($observer, $exception);
    }

    private function queryException(string $message, int $code): QueryException
    {
        return new QueryException(
            'testing',
            'insert into board_post_author_terms ...',
            [],
            new RuntimeException($message, $code),
        );
    }

    private function invokeWriteExceptionHandler(PostAuthorTermObserver $observer, QueryException $exception): void
    {
        (new ReflectionMethod($observer, 'handleAuthorTermsWriteException'))
            ->invoke($observer, $exception);
    }

    private function authorTermsAvailable(PostAuthorTermObserver $observer): ?bool
    {
        return (new ReflectionProperty($observer, 'authorTermsAvailable'))->getValue($observer);
    }
}
