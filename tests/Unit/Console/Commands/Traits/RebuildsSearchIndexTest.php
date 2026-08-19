<?php

namespace Tests\Unit\Console\Commands\Traits;

use App\Console\Commands\Traits\RebuildsSearchIndex;
use App\Search\DTO\SearchIndexRepairReport;
use Illuminate\Console\Command;
use PHPUnit\Framework\TestCase;

class RebuildsSearchIndexTest extends TestCase
{
    public function test_명시_옵션이_없으면_유지보수기를_조회하지_않는다(): void
    {
        $command = new class extends Command
        {
            use RebuildsSearchIndex;

            public function option($key = null): mixed
            {
                return false;
            }

            public function runSearchIndexMaintenance(): ?SearchIndexRepairReport
            {
                return $this->handleSearchIndexRebuild();
            }
        };

        // Laravel 컨테이너를 부팅하지 않은 상태에서도 null 이어야 한다. 유지보수기를
        // 먼저 해석하면 app() 호출에서 실패하므로 기본 경로의 완전한 단락을 고정한다.
        $this->assertNull($command->runSearchIndexMaintenance());
    }
}
