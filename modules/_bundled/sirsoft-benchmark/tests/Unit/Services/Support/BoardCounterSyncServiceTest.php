<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services\Support;

require_once dirname(__DIR__, 5).'/sirsoft-board/tests/ModuleTestCase.php';
require_once dirname(__DIR__, 5).'/sirsoft-board/tests/BoardTestCase.php';

use Illuminate\Support\Facades\DB;
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

    public function test_board_sync_backfills_author_terms_after_raw_post_insert(): void
    {
        $authorName = 'benchmark-raw-author';
        $this->createTestPost(['author_name' => $authorName]);

        // Observer 개입 여부와 무관하게 sync 직전 누락 상태를 명시적으로 재현합니다.
        DB::table('board_post_author_terms')
            ->where('board_id', $this->board->id)
            ->where('author_name', $authorName)
            ->delete();
        $this->assertDatabaseMissing('board_post_author_terms', [
            'board_id' => $this->board->id,
            'author_name' => $authorName,
        ]);

        $cacheInvalidator = Mockery::mock(BoardCacheInvalidator::class);
        $cacheInvalidator->shouldReceive('invalidate')
            ->once()
            ->with($this->board->id, $this->board->slug);

        $service = new BoardCounterSyncService(
            new SyntheticProfileFactory(new DictionaryLoader),
            $cacheInvalidator,
        );

        $service->syncBoardsWithoutDatasetVerification([$this->board->id]);

        $this->assertDatabaseHas('board_post_author_terms', [
            'board_id' => $this->board->id,
            'author_name' => $authorName,
        ]);
    }
}
