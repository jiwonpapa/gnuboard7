<?php

namespace Modules\Sirsoft\Benchmark\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\DummyDataResetService;

class ResetGenerationJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 1;

    public int $timeout = 900;

    public function __construct(
        public int $generationJobId
    ) {}

    public function handle(DummyDataResetService $resetService): void
    {
        $hasMore = $resetService->processNextChunk($this->generationJobId);

        if ($hasMore) {
            self::dispatch($this->generationJobId)
                ->onConnection($this->connection ?? 'database')
                ->onQueue($this->queue ?? 'default');
        }
    }

    public function failed(\Throwable $exception): void
    {
        $job = GenerationJob::query()->find($this->generationJobId);
        if (! $job) {
            return;
        }

        $job->status = GenerationJobStatus::Failed;
        $job->last_error = $exception->getMessage();
        $job->current_step = $exception->getMessage();
        $job->last_heartbeat_at = now();
        $job->save();
    }
}
