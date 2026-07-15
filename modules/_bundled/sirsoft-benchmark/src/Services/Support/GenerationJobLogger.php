<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Illuminate\Support\Facades\Log;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Models\GenerationJobLog;

class GenerationJobLogger
{
    public function info(GenerationJob $job, string $message, ?string $stage = null, array $context = []): void
    {
        $this->write($job, 'info', $message, $stage, $context);
    }

    public function warning(GenerationJob $job, string $message, ?string $stage = null, array $context = []): void
    {
        $this->write($job, 'warning', $message, $stage, $context);
    }

    public function error(GenerationJob $job, string $message, ?string $stage = null, array $context = []): void
    {
        $this->write($job, 'error', $message, $stage, $context);
    }

    private function write(GenerationJob $job, string $level, string $message, ?string $stage, array $context): void
    {
        GenerationJobLog::create([
            'generation_job_id' => $job->id,
            'level' => $level,
            'stage' => $stage,
            'message' => $message,
            'context' => $context === [] ? null : $context,
        ]);

        Log::log($level, "[sirsoft-benchmark][job:{$job->id}] {$message}", [
            'job_id' => $job->id,
            'stage' => $stage,
            'context' => $context,
        ]);
    }
}
