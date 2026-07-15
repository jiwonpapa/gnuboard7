<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Enums\WorkloadType;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;

class ProgressReporter
{
    /**
     * @param  array<string, mixed>  $attributes
     */
    public function heartbeat(GenerationJob $job, array $attributes, ?string $step = null): GenerationJob
    {
        $merged = array_merge($job->getAttributes(), $attributes);
        $merged['options'] = $attributes['options'] ?? $job->options ?? [];
        $runtimeState = $attributes['runtime_state'] ?? $job->runtime_state ?? [];

        $currentStage = $attributes['current_stage'] ?? $job->current_stage;
        if ($currentStage instanceof GenerationStage) {
            $currentStage = $currentStage->value;
        }

        $syncBoardIndex = is_array($runtimeState) ? (int) ($runtimeState['sync_board_index'] ?? 0) : 0;
        $syncBoardTotal = is_array($runtimeState)
            ? count($runtimeState['board_states'] ?? [])
            : (int) ($merged['total_boards'] ?? 0);

        $job->fill($attributes);
        $job->last_heartbeat_at = now();
        $job->current_step = $step ?? ($attributes['current_step'] ?? $job->current_step);
        $workloadType = $job->workload_type ?? WorkloadType::Board;
        if (! $workloadType instanceof WorkloadType) {
            $workloadType = WorkloadType::tryFrom((string) $workloadType) ?? WorkloadType::Board;
        }

        $job->progress_percent = $workloadType === WorkloadType::Commerce
            ? $this->calculateCommerceProgress($merged, $runtimeState, $currentStage)
            : $this->calculateBoardProgress(
                (int) ($merged['generated_users'] ?? 0),
                (int) ($merged['total_users'] ?? 0),
                (int) ($merged['generated_boards'] ?? 0),
                (int) ($merged['total_boards'] ?? 0),
                (int) ($merged['generated_posts'] ?? 0),
                (int) ($merged['total_posts'] ?? 0),
                (int) ($merged['processed_comment_candidates'] ?? 0),
                $currentStage,
                $syncBoardIndex,
                $syncBoardTotal
            );
        $job->save();

        return $job->refresh();
    }

    public function markStopped(GenerationJob $job, string $step): GenerationJob
    {
        $job->status = GenerationJobStatus::Stopped;
        $job->current_step = $step;
        $job->last_heartbeat_at = now();
        $job->save();

        return $job->refresh();
    }

    public function markCompleted(GenerationJob $job, string $step): GenerationJob
    {
        $job->status = GenerationJobStatus::Completed;
        $job->current_stage = GenerationStage::Completed;
        $job->current_step = $step;
        $job->progress_percent = 100;
        $job->finished_at = now();
        $job->last_heartbeat_at = now();
        $job->save();

        return $job->refresh();
    }

    public function markFailed(GenerationJob $job, string $error): GenerationJob
    {
        $job->status = GenerationJobStatus::Failed;
        $job->last_error = $error;
        $job->current_step = $error;
        $job->last_heartbeat_at = now();
        $job->save();

        return $job->refresh();
    }

    private function calculateBoardProgress(
        int $generatedUsers,
        int $totalUsers,
        int $generatedBoards,
        int $totalBoards,
        int $generatedPosts,
        int $totalPosts,
        int $processedCommentCandidates,
        string $currentStage,
        int $syncBoardIndex = 0,
        int $syncBoardTotal = 0
    ): float {
        if ($currentStage === GenerationStage::Completed->value) {
            return 100;
        }

        $users = $totalUsers > 0 ? min(1, $generatedUsers / $totalUsers) : 1;
        $boards = $totalBoards > 0 ? min(1, $generatedBoards / $totalBoards) : 1;
        $posts = $totalPosts > 0 ? min(1, $generatedPosts / $totalPosts) : 1;
        $comments = $totalPosts > 0 ? min(1, $processedCommentCandidates / $totalPosts) : 1;
        $sync = $syncBoardTotal > 0 ? min(1, $syncBoardIndex / $syncBoardTotal) : 0;

        return round(($users * 0.10 + $boards * 0.05 + $posts * 0.50 + $comments * 0.25 + $sync * 0.10) * 100, 2);
    }

    /**
     * @param  array<string, mixed>  $attributes
     * @param  array<string, mixed>  $runtimeState
     */
    private function calculateCommerceProgress(array $attributes, array $runtimeState, string $currentStage): float
    {
        if ($currentStage === GenerationStage::Completed->value) {
            return 100;
        }

        $options = is_array($attributes['options'] ?? null) ? $attributes['options'] : [];
        $poolTotal = max(1, (int) ($options['image_pool_size'] ?? 0));
        $pool = min(1, count($runtimeState['image_pool'] ?? []) / $poolTotal);
        $categories = $this->ratio((int) ($attributes['generated_categories'] ?? 0), (int) ($attributes['total_categories'] ?? 0));
        $brands = $this->ratio((int) ($attributes['generated_brands'] ?? 0), (int) ($attributes['total_brands'] ?? 0));
        $products = $this->ratio((int) ($attributes['generated_products'] ?? 0), (int) ($attributes['total_products'] ?? 0));
        $verification = in_array($currentStage, [GenerationStage::Verifying->value, GenerationStage::Completed->value], true) ? 0.5 : 0;

        return round(($pool * 0.10 + $categories * 0.10 + $brands * 0.05 + $products * 0.65 + $verification * 0.10) * 100, 2);
    }

    private function ratio(int $generated, int $total): float
    {
        return $total > 0 ? min(1, $generated / $total) : 1;
    }
}
