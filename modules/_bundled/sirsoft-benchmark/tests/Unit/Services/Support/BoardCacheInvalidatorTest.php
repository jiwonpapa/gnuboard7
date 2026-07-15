<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services\Support;

use App\Contracts\Extension\CacheInterface;
use Mockery;
use Modules\Sirsoft\Benchmark\Services\Support\BoardCacheInvalidator;
use PHPUnit\Framework\TestCase;

class BoardCacheInvalidatorTest extends TestCase
{
    protected function tearDown(): void
    {
        Mockery::close();
        parent::tearDown();
    }

    public function test_it_invalidates_board_counts_and_derived_caches(): void
    {
        $cache = Mockery::mock(CacheInterface::class);
        $cache->shouldReceive('forget')->once()->with('board_normal_count_2')->andReturnTrue();
        $cache->shouldReceive('forget')->once()->with('boards:list')->andReturnTrue();
        $cache->shouldReceive('forget')->once()->with('boards:id:2')->andReturnTrue();
        $cache->shouldReceive('forget')->once()->with('posts_count_gallery')->andReturnTrue();
        $cache->shouldReceive('forget')->once()->with('boards:slug:gallery')->andReturnTrue();
        $cache->shouldReceive('flushTags')
            ->once()
            ->with(['board-stats', 'board-posts', 'board-list'])
            ->andReturnTrue();

        (new BoardCacheInvalidator($cache))->invalidate(2, 'gallery');

        $this->addToAssertionCount(1);
    }

    public function test_it_rejects_invalid_board_id(): void
    {
        $cache = Mockery::mock(CacheInterface::class);
        $cache->shouldNotReceive('forget');
        $cache->shouldNotReceive('flushTags');

        $this->expectException(\InvalidArgumentException::class);

        (new BoardCacheInvalidator($cache))->invalidate(0, 'gallery');
    }
}
