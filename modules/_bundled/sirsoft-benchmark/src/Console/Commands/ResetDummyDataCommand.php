<?php

namespace Modules\Sirsoft\Benchmark\Console\Commands;

use Illuminate\Console\Command;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\DummyDataResetService;

class ResetDummyDataCommand extends Command
{
    protected $signature = 'benchmark:reset-dummy-data {--job= : generation_jobs 테이블 ID}';

    protected $description = '벤치마크 더미데이터를 CLI에서 초기화합니다.';

    public function __construct(
        private DummyDataResetService $resetService
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $jobId = (int) $this->option('job');

        if ($jobId <= 0) {
            $this->error('--job 옵션이 필요합니다.');

            return self::FAILURE;
        }

        $job = GenerationJob::query()->find($jobId);

        if (! $job) {
            $this->error("작업 #{$jobId} 을(를) 찾을 수 없습니다.");

            return self::FAILURE;
        }

        do {
            $hasMore = $this->resetService->processNextChunk($jobId);
            $job = GenerationJob::query()->find($jobId);

            if (! $job || $job->status->isTerminal()) {
                break;
            }
        } while ($hasMore);

        $job = GenerationJob::query()->find($jobId);
        $this->line("status={$job?->status->value} stage={$job?->current_stage->value} progress={$job?->progress_percent}");

        return $job && $job->status->value !== 'failed'
            ? self::SUCCESS
            : self::FAILURE;
    }
}
