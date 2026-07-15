<?php

namespace Modules\Sirsoft\Board\Tests\Unit;

require_once __DIR__.'/../ModuleTestCase.php';

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Board\Models\Board;
use Modules\Sirsoft\Board\Repositories\PostRepository;
use Modules\Sirsoft\Board\Tests\ModuleTestCase;

class PostRepositoryPaginationPerformanceTest extends ModuleTestCase
{
    private Board $board;

    private PostRepository $repository;

    protected function setUp(): void
    {
        parent::setUp();
        config()->set('benchmark.board_list_variant', 'optimized');

        $this->board = Board::factory()->create([
            'slug' => 'pagination-performance-'.uniqid(),
            'is_active' => true,
        ]);
        $this->repository = app(PostRepository::class);
    }

    public function test_paginated_list_fetches_ids_before_wide_rows_and_skips_reply_query(): void
    {
        $this->insertPosts(35);

        DB::flushQueryLog();
        DB::enableQueryLog();

        $paginator = $this->repository->paginate($this->board->slug, [
            'page' => 2,
            'order_by' => 'created_at',
            'order_direction' => 'desc',
        ], 10, board: $this->board);

        $queries = collect(DB::getQueryLog())->pluck('query');
        DB::disableQueryLog();

        $this->assertCount(10, $paginator->getCollection());
        $this->assertTrue($queries->contains(
            fn (string $sql) => preg_match('/select\s+[`"]id[`"]\s+from\s+[`"][^`"]*board_posts[`"]/i', $sql) === 1
                && str_contains(strtolower($sql), 'offset 10')
        ));
        $this->assertTrue($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'substring(')
                && str_contains(strtolower($sql), ' in (')
        ));
        $this->assertFalse($queries->contains(
            fn (string $sql) => preg_match('/[`"]parent_id[`"]\s+in\s*\(/i', $sql) === 1
        ));
    }

    public function test_first_page_limits_notice_rows_to_ten(): void
    {
        $this->insertPosts(5);
        $this->insertPosts(12, true);

        $paginator = $this->repository->paginate($this->board->slug, [
            'page' => 1,
            'order_by' => 'created_at',
            'order_direction' => 'desc',
        ], 5, board: $this->board);

        $notices = $paginator->getCollection()->where('is_notice', true);

        $this->assertCount(10, $notices);
        $this->assertCount(15, $paginator->getCollection());
    }

    public function test_baseline_variant_uses_the_original_wide_offset_and_reply_query(): void
    {
        config()->set('benchmark.board_list_variant', 'baseline');
        $this->insertPosts(35);

        DB::flushQueryLog();
        DB::enableQueryLog();

        $paginator = $this->repository->paginate($this->board->slug, [
            'page' => 2,
            'order_by' => 'created_at',
            'order_direction' => 'desc',
        ], 10, board: $this->board);

        $queries = collect(DB::getQueryLog())->pluck('query');
        DB::disableQueryLog();

        $this->assertCount(10, $paginator->getCollection());
        $this->assertFalse($queries->contains(
            fn (string $sql) => preg_match('/select\s+[`"]id[`"]\s+from\s+[`"][^`"]*board_posts[`"]/i', $sql) === 1
                && str_contains(strtolower($sql), 'offset 10')
        ));
        $this->assertTrue($queries->contains(
            fn (string $sql) => str_contains(strtolower($sql), 'substring(')
                && str_contains(strtolower($sql), 'offset 10')
        ));
        $this->assertTrue($queries->contains(
            fn (string $sql) => preg_match('/[`"]parent_id[`"]\s+in\s*\(/i', $sql) === 1
        ));
    }

    public function test_baseline_variant_keeps_all_notice_rows(): void
    {
        config()->set('benchmark.board_list_variant', 'baseline');
        $this->insertPosts(5);
        $this->insertPosts(12, true);

        $paginator = $this->repository->paginate($this->board->slug, [
            'page' => 1,
            'order_by' => 'created_at',
            'order_direction' => 'desc',
        ], 5, board: $this->board);

        $notices = $paginator->getCollection()->where('is_notice', true);

        $this->assertCount(12, $notices);
        $this->assertCount(17, $paginator->getCollection());
    }

    private function insertPosts(int $count, bool $isNotice = false): void
    {
        $baseTime = now()->subDay();
        $rows = [];

        for ($index = 0; $index < $count; $index++) {
            $rows[] = [
                'board_id' => $this->board->id,
                'title' => ($isNotice ? '공지 ' : '게시글 ').$index,
                'content' => '목록 미리보기 본문 '.$index,
                'content_mode' => 'text',
                'author_name' => 'tester',
                'ip_address' => '127.0.0.1',
                'is_notice' => $isNotice,
                'is_secret' => false,
                'status' => 'published',
                'trigger_type' => 'admin',
                'view_count' => $index,
                'parent_id' => null,
                'depth' => 0,
                'replies_count' => 0,
                'comments_count' => 0,
                'attachments_count' => 0,
                'created_at' => $baseTime->copy()->addSeconds($index),
                'updated_at' => $baseTime->copy()->addSeconds($index),
                'deleted_at' => null,
            ];
        }

        DB::table('board_posts')->insert($rows);
    }
}
