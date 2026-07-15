<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use App\Contracts\Extension\CacheInterface;

class BoardCacheInvalidator
{
    public function __construct(
        private CacheInterface $cache
    ) {}

    public function invalidate(int $boardId, ?string $boardSlug = null): void
    {
        if ($boardId <= 0) {
            throw new \InvalidArgumentException('캐시 무효화 대상 board_id 가 올바르지 않습니다.');
        }

        // 태그 인덱스 유실 여부와 관계없이 목록 총건수 키는 직접 삭제합니다.
        $this->cache->forget("board_normal_count_{$boardId}");
        $this->cache->forget('boards:list');
        $this->cache->forget("boards:id:{$boardId}");

        if ($boardSlug !== null && $boardSlug !== '') {
            $this->cache->forget("posts_count_{$boardSlug}");
            $this->cache->forget("boards:slug:{$boardSlug}");
        }

        $this->cache->flushTags(['board-stats', 'board-posts', 'board-list']);
    }
}
