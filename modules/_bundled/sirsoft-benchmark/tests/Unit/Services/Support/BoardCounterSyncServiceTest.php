<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services\Support;

require_once dirname(__DIR__, 5).'/sirsoft-board/tests/ModuleTestCase.php';
require_once dirname(__DIR__, 5).'/sirsoft-board/tests/BoardTestCase.php';

use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Mockery;
use Modules\Sirsoft\Benchmark\Services\Support\BoardCacheInvalidator;
use Modules\Sirsoft\Benchmark\Services\Support\BoardCounterSyncService;
use Modules\Sirsoft\Benchmark\Services\Support\DictionaryLoader;
use Modules\Sirsoft\Benchmark\Services\Support\SyntheticProfileFactory;
use Modules\Sirsoft\Board\Tests\BoardTestCase;

class BoardCounterSyncServiceTest extends BoardTestCase
{
    protected function tearDown(): void
    {
        Mockery::close();
        parent::tearDown();
    }

    public function test_board_sync_updates_totals_without_legacy_author_terms_table(): void
    {
        $this->assertFalse(Schema::hasTable('board_post_author_terms'));
        $this->createTestPost(['author_name' => 'benchmark-raw-author']);

        $cacheInvalidator = Mockery::mock(BoardCacheInvalidator::class);
        $cacheInvalidator->shouldReceive('invalidate')
            ->once()
            ->with($this->board->id, $this->board->slug);

        $service = new BoardCounterSyncService(
            new SyntheticProfileFactory(new DictionaryLoader),
            $cacheInvalidator,
        );

        $summaries = $service->syncBoardsWithoutDatasetVerification([$this->board->id]);

        $this->assertSame($this->board->id, $summaries[0]['board_id']);
        $this->assertSame(1, $summaries[0]['posts_count']);
        $this->assertSame(0, $summaries[0]['comments_count']);
    }

    public function test_post_delete_sync_updates_only_board_totals(): void
    {
        $postId = $this->createTestPost([
            'author_name' => 'benchmark-deleted-author',
            'comments_count' => 17,
        ]);

        $cacheInvalidator = Mockery::mock(BoardCacheInvalidator::class);
        $cacheInvalidator->shouldReceive('invalidate')
            ->once()
            ->with($this->board->id, $this->board->slug);

        $service = new BoardCounterSyncService(
            new SyntheticProfileFactory(new DictionaryLoader),
            $cacheInvalidator,
        );

        $summaries = $service->syncBoardTotalsAfterDatasetDeletion([$this->board->id]);

        $this->assertSame($this->board->id, $summaries[0]['board_id']);
        $this->assertSame(1, $summaries[0]['posts_count']);
        $this->assertSame(0, $summaries[0]['comments_count']);
        $this->assertSame(17, (int) DB::table('board_posts')->where('id', $postId)->value('comments_count'));
    }
}
