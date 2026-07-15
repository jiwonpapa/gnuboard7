<?php

namespace Modules\Sirsoft\Benchmark\Services;

use Illuminate\Support\Str;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Enums\WorkloadType;
use Modules\Sirsoft\Benchmark\Jobs\ResetGenerationJob;
use Modules\Sirsoft\Benchmark\Jobs\RunGenerationJob;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\CommerceDatasetPlanner;
use Modules\Sirsoft\Benchmark\Services\Support\DatasetPlanner;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;

class GenerationJobService
{
    public const DEFAULT_BATCH_SIZE = 3000;

    public const DEFAULT_CHUNK_SIZE = 20000;

    public const ALLOWED_BATCH_SIZES = [2000, 3000];

    public const ALLOWED_CHUNK_SIZES = [5000, 10000, 20000];

    public const DEFAULT_COMMERCE_BATCH_SIZE = 500;

    public const DEFAULT_COMMERCE_CHUNK_SIZE = 5000;

    public const ALLOWED_COMMERCE_BATCH_SIZES = [250, 500, 1000];

    public const ALLOWED_COMMERCE_CHUNK_SIZES = [2500, 5000, 10000];

    public function __construct(
        private DatasetPlanner $planner,
        private CommerceDatasetPlanner $commercePlanner,
        private GenerationJobLogger $logger
    ) {}

    public function createJob(array $payload, ?int $requestedBy = null): GenerationJob
    {
        $options = $this->normalizeOptions($payload);
        $seed = (int) ($options['seed'] ?? random_int(1, 2147483646));
        $options['seed'] = $seed;
        $workloadType = WorkloadType::from($options['workload_type']);
        $initialStage = $workloadType === WorkloadType::Commerce
            ? GenerationStage::ImagePool
            : GenerationStage::Users;

        $job = new GenerationJob([
            'uuid' => (string) Str::uuid(),
            'dataset_name' => $options['dataset_name'],
            'dataset_slug' => 'pending-'.Str::lower(Str::random(12)),
            'workload_type' => $workloadType,
            'seed' => $seed,
            'status' => GenerationJobStatus::Pending,
            'current_stage' => $initialStage,
            'dry_run' => (bool) $options['dry_run'],
            'total_users' => (int) $options['total_users'],
            'total_boards' => (int) $options['total_boards'],
            'total_posts' => (int) $options['total_posts'],
            'total_categories' => (int) $options['total_categories'],
            'total_brands' => (int) $options['total_brands'],
            'total_products' => (int) $options['total_products'],
            'requested_by' => $requestedBy,
        ]);
        $job->save();

        $job->dataset_slug = $this->makeDatasetSlug($job->id, $options['dataset_name']);
        $job->save();

        $planBundle = $workloadType === WorkloadType::Commerce
            ? $this->commercePlanner->build($job->refresh(), array_merge($options, ['seed' => $seed]))
            : $this->planner->build($job->refresh(), array_merge($options, ['seed' => $seed]));
        $job->fill([
            'seed' => $seed,
            'options' => $options,
            'plan' => $planBundle['plan'],
            'runtime_state' => $planBundle['runtime_state'],
            'estimated_comments' => (int) ($planBundle['plan']['estimated_comments'] ?? 0),
            'estimated_product_images' => (int) ($planBundle['plan']['estimated_product_images'] ?? 0),
            'current_step' => '작업 대기 중',
        ]);
        $job->save();

        $this->logger->info($job, '생성 작업이 등록되었습니다.', $initialStage->value, [
            'dry_run' => $job->dry_run,
            'seed' => $seed,
            'workload_type' => $workloadType->value,
        ]);

        return $job->refresh();
    }

    /**
     * @return array<string, mixed>
     */
    public function estimate(array $payload): array
    {
        $options = $this->normalizeOptions($payload);
        $seed = (int) ($options['seed'] ?? 1);
        $workloadType = WorkloadType::from($options['workload_type']);
        $job = new GenerationJob([
            'id' => 0,
            'dataset_name' => $options['dataset_name'],
            'dataset_slug' => 'estimate-'.Str::slug($options['dataset_name']).'-preview',
            'workload_type' => $workloadType,
            'seed' => $seed,
            'total_users' => (int) $options['total_users'],
            'total_boards' => (int) $options['total_boards'],
            'total_posts' => (int) $options['total_posts'],
            'total_categories' => (int) $options['total_categories'],
            'total_brands' => (int) $options['total_brands'],
            'total_products' => (int) $options['total_products'],
        ]);

        return ($workloadType === WorkloadType::Commerce
            ? $this->commercePlanner
            : $this->planner
        )->build($job, array_merge($options, ['seed' => $seed]))['plan'];
    }

    public function dispatchGenerate(GenerationJob $job): void
    {
        RunGenerationJob::dispatch($job->id)
            ->onConnection($this->resolveQueueConnection())
            ->onQueue($this->resolveQueueName());
    }

    public function dispatchReset(GenerationJob $job): void
    {
        ResetGenerationJob::dispatch($job->id)
            ->onConnection($this->resolveQueueConnection())
            ->onQueue($this->resolveQueueName());
    }

    public function requestStop(GenerationJob $job): GenerationJob
    {
        if ($job->status === GenerationJobStatus::Pending) {
            $job->status = GenerationJobStatus::Stopped;
            $job->current_step = '대기 중인 작업을 중단했습니다.';
        } else {
            $job->status = GenerationJobStatus::Stopping;
            $job->current_step = '중단 요청이 접수되었습니다.';
        }

        $job->stop_requested_at = now();
        $job->save();

        $this->logger->warning($job, '작업 중단 요청이 등록되었습니다.', $job->current_stage->value);

        return $job->refresh();
    }

    public function resume(GenerationJob $job): GenerationJob
    {
        if (! $job->canResume()) {
            throw new \RuntimeException('현재 상태에서는 작업을 재개할 수 없습니다.');
        }

        $job->status = GenerationJobStatus::Pending;
        $job->stop_requested_at = null;
        $job->last_error = null;
        $job->current_step = '재개 대기 중';
        $job->save();

        if ($job->current_stage === GenerationStage::Resetting) {
            $this->dispatchReset($job);
        } else {
            $this->dispatchGenerate($job);
        }

        $this->logger->info($job, '작업 재개가 요청되었습니다.', $job->current_stage->value);

        return $job->refresh();
    }

    public function rerun(GenerationJob $job, ?int $requestedBy = null): GenerationJob
    {
        $payload = $job->options ?? [];
        $payload['dataset_name'] = ($payload['dataset_name'] ?? $job->dataset_name).' rerun';

        $newJob = $this->createJob($payload, $requestedBy ?? $job->requested_by);
        $this->dispatchGenerate($newJob);

        return $newJob;
    }

    public function prepareReset(GenerationJob $job): GenerationJob
    {
        $runtimeState = $job->runtime_state ?? [];
        $runtimeState['reset_board_index'] = 0;
        $runtimeState['reset_user_segment_index'] = 0;
        $runtimeState['cleanup'] = [
            'deleted_posts' => 0,
            'deleted_comments' => 0,
            'deleted_users' => 0,
        ];
        if ($job->workload_type === WorkloadType::Commerce) {
            $runtimeState['reset_phase'] = 'preflight';
            $runtimeState['cleanup'] = [
                'deleted_products' => 0,
                'deleted_categories' => 0,
                'deleted_brands' => 0,
                'deleted_files' => false,
            ];
        }

        $job->status = GenerationJobStatus::Running;
        $job->current_stage = GenerationStage::Resetting;
        $job->current_step = '데이터셋 초기화 대기 중';
        $job->stop_requested_at = null;
        $job->runtime_state = $runtimeState;
        $job->started_at = $job->started_at ?? now();
        $job->save();

        $this->logger->warning($job, '데이터셋 초기화가 요청되었습니다.', GenerationStage::Resetting->value);

        return $job->refresh();
    }

    /**
     * @return array<string, mixed>
     */
    public function normalizeOptions(array $payload): array
    {
        $defaults = [
            'workload_type' => WorkloadType::Board->value,
            'dataset_name' => 'benchmark-dataset',
            'total_users' => 10000,
            'selected_boards' => [],
            'comment_rate' => 0.35,
            'avg_comments_per_post' => 2.4,
            'max_comments_per_post' => 20,
            'batch_size' => self::DEFAULT_BATCH_SIZE,
            'chunk_size' => self::DEFAULT_CHUNK_SIZE,
            'seed' => null,
            'dry_run' => false,
            'time_distribution' => 'recent_burst',
            'activity_profile' => 'skewed',
            'total_categories' => 100,
            'total_brands' => 50,
            'total_products' => 10000,
            'category_depth' => 3,
            'category_distribution' => 'skewed',
            'image_pool_size' => 100,
            'image_coverage' => 1.0,
            'max_images_per_product' => 1,
            'image_source' => 'picsum',
            'image_mode' => 'shared',
        ];

        $options = array_merge($defaults, $payload);
        $workloadType = WorkloadType::tryFrom((string) $options['workload_type']) ?? WorkloadType::Board;
        $options['workload_type'] = $workloadType->value;
        $options['selected_boards'] = array_values(array_map(
            fn (array $boardTarget) => [
                'board_id' => (int) ($boardTarget['board_id'] ?? 0),
                'target_posts' => max(1, (int) ($boardTarget['target_posts'] ?? 0)),
            ],
            array_values(array_filter(
                $options['selected_boards'] ?? [],
                fn ($boardTarget) => is_array($boardTarget) && ! empty($boardTarget['board_id'])
            ))
        ));
        $options['total_users'] = $workloadType === WorkloadType::Board ? max(1, (int) $options['total_users']) : 0;
        $options['total_boards'] = count($options['selected_boards']);
        $options['total_posts'] = array_sum(array_column($options['selected_boards'], 'target_posts'));
        $options['comment_rate'] = min(1, max(0, (float) $options['comment_rate']));
        $options['avg_comments_per_post'] = max(0, (float) $options['avg_comments_per_post']);
        $options['max_comments_per_post'] = max(0, (int) $options['max_comments_per_post']);
        $allowedBatchSizes = $workloadType === WorkloadType::Commerce ? self::ALLOWED_COMMERCE_BATCH_SIZES : self::ALLOWED_BATCH_SIZES;
        $allowedChunkSizes = $workloadType === WorkloadType::Commerce ? self::ALLOWED_COMMERCE_CHUNK_SIZES : self::ALLOWED_CHUNK_SIZES;
        $defaultBatchSize = $workloadType === WorkloadType::Commerce ? self::DEFAULT_COMMERCE_BATCH_SIZE : self::DEFAULT_BATCH_SIZE;
        $defaultChunkSize = $workloadType === WorkloadType::Commerce ? self::DEFAULT_COMMERCE_CHUNK_SIZE : self::DEFAULT_CHUNK_SIZE;
        $options['batch_size'] = in_array((int) $options['batch_size'], $allowedBatchSizes, true) ? (int) $options['batch_size'] : $defaultBatchSize;
        $options['chunk_size'] = in_array((int) $options['chunk_size'], $allowedChunkSizes, true) ? (int) $options['chunk_size'] : $defaultChunkSize;
        $expectedCommentsPerPost = max(0.1, $options['comment_rate'] * max(1.0, $options['avg_comments_per_post']));
        $options['comment_batch_size'] = max(100, min($options['batch_size'], 500));
        $options['comment_chunk_size'] = max(
            100,
            min(
                $options['chunk_size'],
                (int) floor(5000 / $expectedCommentsPerPost)
            )
        );
        $options['dry_run'] = (bool) $options['dry_run'];
        $options['dataset_name'] = trim((string) $options['dataset_name']) !== '' ? trim((string) $options['dataset_name']) : 'benchmark-dataset';

        $options['total_categories'] = $workloadType === WorkloadType::Commerce ? min(500, max(1, (int) $options['total_categories'])) : 0;
        $options['total_brands'] = $workloadType === WorkloadType::Commerce ? min(100, max(0, (int) $options['total_brands'])) : 0;
        $options['total_products'] = $workloadType === WorkloadType::Commerce ? min(200000, max(1, (int) $options['total_products'])) : 0;
        $options['category_depth'] = in_array((int) $options['category_depth'], [2, 3], true) ? (int) $options['category_depth'] : 3;
        $options['image_pool_size'] = in_array((int) $options['image_pool_size'], [20, 50, 100], true) ? (int) $options['image_pool_size'] : 100;
        $options['image_coverage'] = min(1, max(0, (float) $options['image_coverage']));
        $options['max_images_per_product'] = min(3, max(1, (int) $options['max_images_per_product']));
        $options['image_source'] = in_array($options['image_source'], ['picsum', 'generated'], true) ? $options['image_source'] : 'picsum';
        $options['image_mode'] = 'shared';

        if ($workloadType === WorkloadType::Board && ($options['total_boards'] <= 0 || $options['total_posts'] <= 0)) {
            throw new \InvalidArgumentException('선택된 게시판과 게시판별 게시글 수를 확인해 주세요.');
        }

        return $options;
    }

    private function makeDatasetSlug(int $jobId, string $datasetName): string
    {
        $base = Str::slug($datasetName) ?: 'dataset';

        return substr("bm-job-{$jobId}-{$base}", 0, 120);
    }

    private function resolveQueueName(): string
    {
        $configuredQueue = trim((string) env('BENCHMARK_QUEUE_NAME', ''));
        if ($configuredQueue !== '') {
            return $configuredQueue;
        }

        $defaultConnection = (string) config('queue.default', 'redis');
        $defaultQueue = config("queue.connections.{$defaultConnection}.queue");

        return is_string($defaultQueue) && trim($defaultQueue) !== ''
            ? trim($defaultQueue)
            : 'default';
    }

    private function resolveQueueConnection(): string
    {
        $configuredConnection = trim((string) env('BENCHMARK_QUEUE_CONNECTION', ''));
        if ($configuredConnection !== '') {
            return $configuredConnection;
        }

        $queueConnection = trim((string) env('QUEUE_CONNECTION', ''));
        if ($queueConnection !== '') {
            return $queueConnection;
        }

        $defaultConnection = trim((string) config('queue.default', ''));
        if ($defaultConnection !== '') {
            return $defaultConnection;
        }

        return 'database';
    }
}
