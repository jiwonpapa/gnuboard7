<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Jobs;

use Illuminate\Queue\Middleware\WithoutOverlapping;
use Modules\Sirsoft\Benchmark\Jobs\ResetGenerationJob;
use PHPUnit\Framework\TestCase;

class ResetGenerationJobTest extends TestCase
{
    public function test_reset_chunks_use_a_per_job_overlap_lock(): void
    {
        $job = new ResetGenerationJob(42);
        $middleware = $job->middleware();

        $this->assertCount(1, $middleware);
        $this->assertInstanceOf(WithoutOverlapping::class, $middleware[0]);
        $this->assertSame('sirsoft-benchmark-reset-42', $middleware[0]->key);
        $this->assertSame(5, $middleware[0]->releaseAfter);
        $this->assertSame(960, $middleware[0]->expiresAfter);
    }
}
