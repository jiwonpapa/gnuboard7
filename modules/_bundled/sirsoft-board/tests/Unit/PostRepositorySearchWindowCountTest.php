<?php

namespace Modules\Sirsoft\Board\Tests\Unit;

require_once __DIR__.'/../ModuleTestCase.php';

use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Board\Models\Post;
use Modules\Sirsoft\Board\Repositories\PostRepository;
use Modules\Sirsoft\Board\Tests\BoardTestCase;

class PostRepositorySearchWindowCountTest extends BoardTestCase
{
    private const INTERNAL_TOTAL_ATTRIBUTE = '__g7_normal_posts_total';

    private PostRepository $repository;

    protected function setUp(): void
    {
        parent::setUp();

        config()->set('benchmark.board_list_variant', 'optimized');
        $this->repository = app(PostRepository::class);
    }

    public function test_search_by_keyword_uses_id_first_lower_bound_without_window_count(): void
    {
        $this->createMatchingPosts(7);
        $this->createTestPost(['title' => 'unrelated title', 'content' => 'unrelated content']);

        DB::flushQueryLog();
        DB::enableQueryLog();

        $result = $this->repository->searchByKeyword($this->board->slug, 'windowneedle', limit: 3);

        $queries = $this->postQueries();
        DB::disableQueryLog();

        $this->assertSame(4, $result['total']);
        $this->assertFalse($result['total_is_exact']);
        $this->assertSame('gte', $result['total_relation']);
        $this->assertTrue($result['has_more_pages']);
        $this->assertCount(3, $result['items']);
        $this->assertCount(2, $queries);
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'count(*) over()')
        ));
        $this->assertWindowAttributeRemoved($result['items']);
    }

    public function test_search_across_boards_gets_total_and_page_items_from_one_post_query(): void
    {
        $this->createMatchingPosts(7);

        DB::flushQueryLog();
        DB::enableQueryLog();

        $result = $this->repository->searchAcrossBoards(
            [$this->board->id],
            'windowneedle',
            perPage: 3,
            page: 2
        );

        $queries = $this->postQueries();
        DB::disableQueryLog();

        $this->assertSame(7, $result['total']);
        $this->assertFalse($result['total_is_exact']);
        $this->assertCount(3, $result['items']);
        $this->assertCount(2, $queries);
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'count(*) over()')
        ));
        $this->assertWindowAttributeRemoved($result['items']);
    }

    public function test_optimized_empty_first_page_returns_zero_without_count_fallback(): void
    {
        DB::flushQueryLog();
        DB::enableQueryLog();

        $result = $this->repository->searchAcrossBoards(
            [$this->board->id],
            'windowneedle',
            perPage: 3,
            page: 1
        );

        $queries = $this->postQueries();
        DB::disableQueryLog();

        $this->assertSame(0, $result['total']);
        $this->assertTrue($result['total_is_exact']);
        $this->assertCount(0, $result['items']);
        $this->assertCount(1, $queries);
        $this->assertStringNotContainsString('count(*) over()', strtolower($queries->first()));
    }

    public function test_optimized_empty_deep_page_does_not_run_count_fallback(): void
    {
        $this->createMatchingPosts(7);

        DB::flushQueryLog();
        DB::enableQueryLog();

        $result = $this->repository->searchAcrossBoards(
            [$this->board->id],
            'windowneedle',
            perPage: 3,
            page: 99
        );

        $queries = $this->postQueries();
        DB::disableQueryLog();

        $this->assertSame(7, $result['total']);
        $this->assertTrue($result['total_is_exact']);
        $this->assertCount(0, $result['items']);
        $this->assertCount(1, $queries);
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'count(*) as aggregate')
        ));
    }

    public function test_search_cap_hides_the_sentinel_and_stops_pagination_at_the_boundary(): void
    {
        config()->set('benchmark.board_search_sync_cap', 10);
        $this->createMatchingPosts(12);

        $result = $this->repository->searchAcrossBoards(
            [$this->board->id],
            'windowneedle',
            perPage: 10,
            page: 1
        );
        $count = $this->repository->countAcrossBoardsBounded(
            [$this->board->id],
            'windowneedle'
        );

        $this->assertSame(10, $result['total']);
        $this->assertFalse($result['total_is_exact']);
        $this->assertSame('gte', $result['total_relation']);
        $this->assertFalse($result['has_more_pages']);
        $this->assertSame(10, $result['result_cap']);
        $this->assertCount(10, $result['items']);
        $this->assertSame(10, $count['total']);
        $this->assertFalse($count['total_is_exact']);
        $this->assertSame(10, $count['result_cap']);
    }

    public function test_baseline_search_methods_keep_separate_count_and_item_queries(): void
    {
        config()->set('benchmark.board_list_variant', 'baseline');
        $this->createMatchingPosts(4);

        DB::flushQueryLog();
        DB::enableQueryLog();
        $singleBoard = $this->repository->searchByKeyword($this->board->slug, 'windowneedle', limit: 2);
        $singleQueries = $this->postQueries();

        DB::flushQueryLog();
        $acrossBoards = $this->repository->searchAcrossBoards(
            [$this->board->id],
            'windowneedle',
            perPage: 2,
            page: 1
        );
        $acrossQueries = $this->postQueries();

        DB::flushQueryLog();
        $count = $this->repository->countAcrossBoardsBounded(
            [$this->board->id],
            'windowneedle'
        );
        DB::disableQueryLog();

        $this->assertSame(4, $singleBoard['total']);
        $this->assertSame(4, $acrossBoards['total']);
        $this->assertSame(4, $count['total']);
        $this->assertTrue($count['total_is_exact']);
        $this->assertSame('eq', $count['total_relation']);
        $this->assertArrayNotHasKey('result_cap', $count);
        $this->assertCount(2, $singleQueries);
        $this->assertCount(2, $acrossQueries);
        $this->assertFalse($singleQueries->contains(
            fn (string $sql) => str_contains(strtolower($sql), ' over()')
        ));
        $this->assertFalse($acrossQueries->contains(
            fn (string $sql) => str_contains(strtolower($sql), ' over()')
        ));
    }

    public function test_direct_eloquent_create_and_author_update_extend_author_terms(): void
    {
        $post = Post::create([
            'board_id' => $this->board->id,
            'title' => '작성자 사전 동기화',
            'content' => '작성자 사전 동기화 테스트',
            'user_id' => null,
            'author_name' => '0',
            'password' => null,
            'ip_address' => '127.0.0.1',
            'is_notice' => false,
            'is_secret' => false,
            'status' => 'published',
            'trigger_type' => 'admin',
            'view_count' => 0,
        ]);

        $this->assertDatabaseHas('board_post_author_terms', [
            'board_id' => $this->board->id,
            'author_name' => '0',
        ]);

        $post->update([
            'author_name' => 'dictionary-author-after',
        ]);

        $this->assertDatabaseHas('board_post_author_terms', [
            'board_id' => $this->board->id,
            'author_name' => 'dictionary-author-after',
        ]);
    }

    private function createMatchingPosts(int $count): void
    {
        for ($index = 0; $index < $count; $index++) {
            $this->createTestPost([
                'title' => "windowneedle title {$index}",
                'content' => "windowneedle content {$index}",
                'created_at' => now()->addSeconds($index),
                'updated_at' => now()->addSeconds($index),
            ]);
        }
    }

    /** @return Collection<int, string> */
    private function postQueries(): Collection
    {
        return collect(DB::getQueryLog())
            ->pluck('query')
            ->filter(fn (string $sql) => str_contains(strtolower($sql), 'board_posts'))
            ->values();
    }

    private function assertWindowAttributeRemoved(Collection $items): void
    {
        foreach ($items as $item) {
            $this->assertArrayNotHasKey(self::INTERNAL_TOTAL_ATTRIBUTE, $item->getAttributes());
        }
    }
}
