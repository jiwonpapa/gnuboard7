<?php

namespace Modules\Sirsoft\Benchmark\Http\Controllers\Admin;

use App\Helpers\ResponseHelper;
use App\Http\Controllers\Api\Base\AdminBaseController;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Http\Requests\Admin\EstimateGenerationJobRequest;
use Modules\Sirsoft\Benchmark\Http\Requests\Admin\IndexGenerationJobRequest;
use Modules\Sirsoft\Benchmark\Http\Requests\Admin\StoreGenerationJobRequest;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\GenerationJobService;
use Modules\Sirsoft\Board\Models\Board;

class GenerationJobController extends AdminBaseController
{
    public function __construct(
        private GenerationJobService $generationJobService
    ) {
        parent::__construct();
    }

    public function index(IndexGenerationJobRequest $request): JsonResponse
    {
        $query = GenerationJob::query()->orderByDesc('id');
        $validated = $request->validated();

        if (! empty($validated['status'])) {
            $query->where('status', $validated['status']);
        }

        if (! empty($validated['search'])) {
            $keyword = $validated['search'];
            $query->where(function ($builder) use ($keyword) {
                $builder->where('dataset_name', 'like', "%{$keyword}%")
                    ->orWhere('dataset_slug', 'like', "%{$keyword}%");
            });
        }

        $paginator = $query->paginate((int) ($validated['per_page'] ?? 10));

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.fetch_success', [
            'data' => $paginator->getCollection()->map(fn (GenerationJob $job) => $this->presentJob($job))->values(),
            'meta' => [
                'current_page' => $paginator->currentPage(),
                'last_page' => $paginator->lastPage(),
                'per_page' => $paginator->perPage(),
                'total' => $paginator->total(),
            ],
        ]);
    }

    public function boards(Request $request): JsonResponse
    {
        $limit = min(200, max(20, (int) $request->input('limit', 100)));
        $keyword = trim((string) $request->input('search', ''));

        $query = Board::query()
            ->select(['id', 'slug', 'name', 'type', 'categories', 'is_active', 'use_comment', 'use_reply'])
            ->orderBy('slug');

        if ($keyword !== '') {
            $query->where('slug', 'like', '%'.$keyword.'%');
        }

        $boards = $query
            ->limit($limit)
            ->get()
            ->map(fn (Board $board) => [
                'id' => $board->id,
                'slug' => $board->slug,
                'name' => $board->getLocalizedName(),
                'type' => (string) $board->type,
                'categories' => is_array($board->categories) ? $board->categories : [],
                'is_active' => (bool) $board->is_active,
                'use_comment' => (bool) $board->use_comment,
                'use_reply' => (bool) $board->use_reply,
            ])
            ->values();

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.fetch_success', [
            'data' => $boards,
        ]);
    }

    public function show(GenerationJob $generationJob): JsonResponse
    {
        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.fetch_success', $this->presentJob($generationJob, true));
    }

    public function logs(Request $request, GenerationJob $generationJob): JsonResponse
    {
        $limit = min(200, max(10, (int) $request->input('limit', 100)));
        $logs = $generationJob->logs()
            ->latest('id')
            ->limit($limit)
            ->get()
            ->map(fn ($log) => [
                'id' => $log->id,
                'level' => $log->level,
                'stage' => $log->stage,
                'message' => $log->message,
                'context' => $log->context,
                'created_at' => optional($log->created_at)->toDateTimeString(),
            ])
            ->values();

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.fetch_success', [
            'data' => $logs,
        ]);
    }

    public function estimate(EstimateGenerationJobRequest $request): JsonResponse
    {
        $plan = $this->generationJobService->estimate($request->validated());

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.estimate_success', $plan);
    }

    public function store(StoreGenerationJobRequest $request): JsonResponse
    {
        $job = $this->generationJobService->createJob($request->validated(), $request->user()?->id);
        $this->generationJobService->dispatchGenerate($job);

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.create_success', $this->presentJob($job), 201);
    }

    public function stop(GenerationJob $generationJob): JsonResponse
    {
        $job = $this->generationJobService->requestStop($generationJob);

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.stop_requested', $this->presentJob($job));
    }

    public function resume(GenerationJob $generationJob): JsonResponse
    {
        $job = $this->generationJobService->resume($generationJob);

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.resume_requested', $this->presentJob($job));
    }

    public function rerun(Request $request, GenerationJob $generationJob): JsonResponse
    {
        $job = $this->generationJobService->rerun($generationJob, $request->user()?->id);

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.rerun_requested', $this->presentJob($job), 201);
    }

    public function reset(GenerationJob $generationJob): JsonResponse
    {
        if (in_array($generationJob->status, [GenerationJobStatus::Running, GenerationJobStatus::Stopping], true)) {
            return ResponseHelper::moduleError('sirsoft-benchmark', 'job.reset_running', 409);
        }

        $job = $this->generationJobService->prepareReset($generationJob);
        if ($job === null) {
            return ResponseHelper::moduleError('sirsoft-benchmark', 'job.reset_running', 409);
        }

        $this->generationJobService->dispatchReset($job);

        return ResponseHelper::moduleSuccess('sirsoft-benchmark', 'job.reset_requested', $this->presentJob($job));
    }

    /**
     * @return array<string, mixed>
     */
    private function presentJob(GenerationJob $job, bool $withPlan = false): array
    {
        $runtimeState = $job->runtime_state ?? [];
        $cleanup = $runtimeState['cleanup'] ?? null;
        $syncResults = $runtimeState['sync_results'] ?? [];
        $targets = $this->presentTargets($job);
        $reset = $this->presentResetState($job, $runtimeState, $cleanup);

        $data = [
            'id' => $job->id,
            'uuid' => $job->uuid,
            'dataset_name' => $job->dataset_name,
            'dataset_slug' => $job->dataset_slug,
            'workload_type' => $job->workload_type->value,
            'seed' => $job->seed,
            'status' => $job->status->value,
            'current_stage' => $job->current_stage->value,
            'dry_run' => $job->dry_run,
            'progress_percent' => (float) $job->progress_percent,
            'current_step' => $job->current_step,
            'totals' => [
                'users' => (int) $job->total_users,
                'boards' => (int) $job->total_boards,
                'posts' => (int) $job->total_posts,
                'estimated_comments' => (int) $job->estimated_comments,
                'categories' => (int) $job->total_categories,
                'brands' => (int) $job->total_brands,
                'products' => (int) $job->total_products,
                'estimated_product_images' => (int) $job->estimated_product_images,
            ],
            'generated' => [
                'users' => (int) $job->generated_users,
                'boards' => (int) $job->generated_boards,
                'posts' => (int) $job->generated_posts,
                'comments' => (int) $job->generated_comments,
                'processed_comment_candidates' => (int) $job->processed_comment_candidates,
                'categories' => (int) $job->generated_categories,
                'brands' => (int) $job->generated_brands,
                'products' => (int) $job->generated_products,
                'product_options' => (int) $job->generated_product_options,
                'product_images' => (int) $job->generated_product_images,
            ],
            'options' => $job->options,
            'targets' => $targets,
            'target_summary' => $this->targetSummary($job, $targets),
            'last_error' => $job->last_error,
            'cleanup' => $cleanup,
            'reset' => $reset,
            'sync' => [
                'synced_boards' => (int) ($syncResults['synced_boards'] ?? 0),
                'total_boards' => (int) $job->total_boards,
            ],
            'verification' => $reset['is_reset']
                ? null
                : (is_array($runtimeState['verification'] ?? null)
                    ? $runtimeState['verification']
                    : (is_array($syncResults['verification'] ?? null) ? $syncResults['verification'] : null)),
            'requested_by' => $job->requested_by,
            'started_at' => optional($job->started_at)->toDateTimeString(),
            'finished_at' => optional($job->finished_at)->toDateTimeString(),
            'last_heartbeat_at' => optional($job->last_heartbeat_at)->toDateTimeString(),
            'created_at' => optional($job->created_at)->toDateTimeString(),
            'updated_at' => optional($job->updated_at)->toDateTimeString(),
        ];

        if ($withPlan) {
            $data['plan'] = $job->plan;
            $data['runtime_state'] = $job->runtime_state;
            $data['sync']['boards'] = array_values($syncResults['boards'] ?? []);
        }

        return $data;
    }

    /**
     * @return array<int, array<string, int|string>>
     */
    private function presentTargets(GenerationJob $job): array
    {
        if ($job->workload_type->value === 'commerce') {
            return [];
        }

        $runtimeState = $job->runtime_state ?? [];
        $boardStates = [];
        foreach ($runtimeState['board_states'] ?? [] as $state) {
            if (is_array($state)) {
                $boardStates[(int) ($state['index'] ?? 0)] = $state;
            }
        }

        return array_values(array_map(
            function (array $target) use ($boardStates): array {
                $state = $boardStates[(int) ($target['index'] ?? 0)] ?? [];

                return [
                    'board_id' => (int) ($target['board_id'] ?? 0),
                    'slug' => (string) ($target['slug'] ?? ''),
                    'name' => (string) ($target['name'] ?? $target['slug'] ?? ''),
                    'target_posts' => (int) ($target['target_posts'] ?? 0),
                    'generated_posts' => (int) ($state['generated_posts'] ?? 0),
                    'generated_comments' => (int) ($state['generated_comments'] ?? 0),
                    'estimated_comments' => (int) ($target['estimated_comments'] ?? 0),
                ];
            },
            array_filter(
                $job->plan['board_plans'] ?? [],
                fn ($target) => is_array($target) && (int) ($target['board_id'] ?? 0) > 0
            )
        ));
    }

    /**
     * @param  array<int, array<string, int|string>>  $targets
     */
    private function targetSummary(GenerationJob $job, array $targets): string
    {
        if ($job->workload_type->value === 'commerce') {
            $generated = (int) $job->generated_products;
            $target = (int) $job->total_products;
            $summary = '쇼핑몰 상품 데이터 '.number_format($generated).'건';

            return $generated === $target
                ? $summary
                : $summary.' (목표 '.number_format($target).'건)';
        }

        if ($targets === []) {
            return '대상 게시판 정보 없음';
        }

        return implode(', ', array_map(function (array $target): string {
            $generated = (int) ($target['generated_posts'] ?? 0);
            $planned = (int) ($target['target_posts'] ?? 0);
            $count = number_format($generated).'건';
            if ($generated !== $planned) {
                $count .= ' (목표 '.number_format($planned).'건)';
            }

            return sprintf(
                '%s (%s, ID %d) · 게시글 %s',
                $target['name'],
                $target['slug'],
                $target['board_id'],
                $count
            );
        }, $targets));
    }

    /**
     * @param  array<string, mixed>  $runtimeState
     * @param  array<string, mixed>|null  $cleanup
     * @return array<string, mixed>
     */
    private function presentResetState(GenerationJob $job, array $runtimeState, ?array $cleanup): array
    {
        $step = (string) ($job->current_step ?? '');
        // Commerce generation owns a normal `reset_phase=preflight` cursor, so
        // reset_phase alone is not proof that the user requested a reset.
        $isReset = array_key_exists('reset_started_at', $runtimeState)
            || $job->current_stage === GenerationStage::Resetting
            || ($cleanup !== null && str_contains($step, '초기화'));
        $phase = $isReset ? ($runtimeState['reset_phase'] ?? null) : null;

        if ($phase === null && $isReset && $job->status === GenerationJobStatus::Completed) {
            $phase = 'completed';
        }

        return [
            'is_reset' => $isReset,
            'is_active' => $isReset && in_array($job->status, [
                GenerationJobStatus::Pending,
                GenerationJobStatus::Running,
                GenerationJobStatus::Stopping,
            ], true),
            'is_completed' => $isReset && $phase === 'completed',
            'phase' => $phase,
            'started_at' => $runtimeState['reset_started_at'] ?? null,
            'finished_at' => $runtimeState['reset_finished_at'] ?? null,
            'cleanup' => $cleanup ?? [],
            'expected' => [
                'posts' => (int) $job->generated_posts,
                'comments' => (int) $job->generated_comments,
                'users' => (int) $job->generated_users,
                'products' => (int) $job->generated_products,
                'categories' => (int) $job->generated_categories,
                'brands' => (int) $job->generated_brands,
            ],
        ];
    }
}
