<?php

namespace Modules\Sirsoft\Board\Tests\Feature\User;

require_once __DIR__.'/../../ModuleTestCase.php';

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Board\Tests\BoardTestCase;

class PostListWindowCountTest extends BoardTestCase
{
    private const INTERNAL_TOTAL_ATTRIBUTE = '__g7_normal_posts_total';

    protected function setUp(): void
    {
        parent::setUp();

        config()->set('benchmark.board_list_variant', 'optimized');
    }

    public function test_search_list_returns_bounded_total_metadata_without_window_count(): void
    {
        $this->createAuthorMatches(7);

        DB::flushQueryLog();
        DB::enableQueryLog();

        $response = $this->getJson(
            "/api/modules/sirsoft-board/boards/{$this->board->slug}/posts"
            .'?search=windowauthor&per_page=3&page=2'
        );

        $queries = collect(DB::getQueryLog())->pluck('query');
        DB::disableQueryLog();

        $response->assertOk();
        $this->assertSame(7, $response->json('data.pagination.total'));
        $this->assertFalse($response->json('data.pagination.total_is_exact'));
        $this->assertSame('gte', $response->json('data.pagination.total_relation'));
        $this->assertSame(6, $response->json('data.pagination.from'));
        $this->assertSame(4, $response->json('data.pagination.to'));
        $this->assertCount(3, $response->json('data.data'));
        $this->assertStringNotContainsString(self::INTERNAL_TOTAL_ATTRIBUTE, $response->getContent());
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'count(*) over()')
        ));
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'board_posts')
                && str_contains(strtolower($sql), 'count(*) as aggregate')
        ));
    }

    public function test_non_search_list_does_not_advertise_a_search_result_cap(): void
    {
        $this->createTestPost();

        $response = $this->getJson(
            "/api/modules/sirsoft-board/boards/{$this->board->slug}/posts?per_page=3&page=1"
        );

        $response->assertOk()->assertJsonMissingPath('data.pagination.result_cap');
    }

    public function test_empty_first_search_page_returns_zero_without_count_fallback(): void
    {
        DB::flushQueryLog();
        DB::enableQueryLog();

        $response = $this->getJson(
            "/api/modules/sirsoft-board/boards/{$this->board->slug}/posts"
            .'?search=no-such-window-author&per_page=3&page=1'
        );

        $queries = collect(DB::getQueryLog())->pluck('query');
        DB::disableQueryLog();

        $response->assertOk();
        $this->assertSame(0, $response->json('data.pagination.total'));
        $this->assertStringNotContainsString(self::INTERNAL_TOTAL_ATTRIBUTE, $response->getContent());
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'board_posts')
                && str_contains(strtolower($sql), 'count(*) as aggregate')
        ));
    }

    public function test_empty_deep_search_page_never_falls_back_to_exact_count(): void
    {
        $this->createAuthorMatches(7);

        DB::flushQueryLog();
        DB::enableQueryLog();

        $response = $this->getJson(
            "/api/modules/sirsoft-board/boards/{$this->board->slug}/posts"
            .'?search=windowauthor&per_page=3&page=99'
        );

        $queries = collect(DB::getQueryLog())->pluck('query');
        DB::disableQueryLog();

        $response->assertOk();
        $this->assertSame(0, $response->json('data.pagination.total'));
        $this->assertFalse($response->json('data.pagination.total_is_exact'));
        $this->assertSame('unknown', $response->json('data.pagination.total_relation'));
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'board_posts')
                && str_contains(strtolower($sql), 'count(*) as aggregate')
        ));
    }

    public function test_all_search_cap_never_exposes_the_sentinel_page(): void
    {
        config()->set('benchmark.board_search_sync_cap', 10);
        $this->createAuthorMatches(12);

        $response = $this->getJson(
            "/api/modules/sirsoft-board/boards/{$this->board->slug}/posts"
            .'?search=windowauthor&per_page=10&page=1'
        );

        $response->assertOk();
        $this->assertSame(10, $response->json('data.pagination.total'));
        $this->assertFalse($response->json('data.pagination.total_is_exact'));
        $this->assertSame('gte', $response->json('data.pagination.total_relation'));
        $this->assertFalse($response->json('data.pagination.has_more_pages'));
        $this->assertSame(10, $response->json('data.pagination.result_cap'));
        $this->assertCount(10, $response->json('data.data'));
    }

    private function createAuthorMatches(int $count): void
    {
        $terms = [];
        for ($index = 0; $index < $count; $index++) {
            $authorName = "windowauthor {$index}";
            $this->createTestPost([
                'title' => "unrelated title {$index}",
                'content' => "unrelated content {$index}",
                'author_name' => $authorName,
                'created_at' => now()->addSeconds($index),
                'updated_at' => now()->addSeconds($index),
            ]);
            $terms[] = [
                'board_id' => $this->board->id,
                'author_name' => $authorName,
            ];
        }

        DB::table('board_post_author_terms')->insertOrIgnore($terms);
    }
}
