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

    public function test_search_list_reuses_embedded_total_and_hides_internal_attribute(): void
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
        $this->assertCount(3, $response->json('data.data'));
        $this->assertStringNotContainsString(self::INTERNAL_TOTAL_ATTRIBUTE, $response->getContent());
        $this->assertTrue($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'count(*) over()')
        ));
        $this->assertFalse($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'board_posts')
                && str_contains(strtolower($sql), 'count(*) as aggregate')
        ));
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

    public function test_empty_deep_search_page_falls_back_to_count(): void
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
        $this->assertSame(7, $response->json('data.pagination.total'));
        $this->assertTrue($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'board_posts')
                && str_contains(strtolower($sql), 'count(*) as aggregate')
        ));
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
