<?php

namespace Modules\Sirsoft\Benchmark\Jobs;

use Illuminate\Bus\Queueable;
use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Bus\Dispatchable;
use Illuminate\Queue\InteractsWithQueue;
use Illuminate\Queue\SerializesModels;
use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Services\DummyDataGenerationService;

class RunGenerationJob implements ShouldQueue
{
    use Dispatchable, InteractsWithQueue, Queueable, SerializesModels;

    public int $tries = 1;

    public int $timeout = 900;

    public function __construct(
        public int $generationJobId
    ) {}

    public function handle(DummyDataGenerationService $generationService): void
    {
        $connection = DB::connection();
        $dispatcher = $connection->getEventDispatcher();
        $connection->disableQueryLog();
        $connection->unsetEventDispatcher();

        try {
            $hasMore = $generationService->processNextChunk($this->generationJobId);
        } finally {
            if ($dispatcher) {
                $connection->setEventDispatcher($dispatcher);
            }
        }

        if ($hasMore) {
            self::dispatch($this->generationJobId)
                ->onConnection($this->connection ?? 'database')
                ->onQueue($this->queue ?? 'default');
        }
    }
}
