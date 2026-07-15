<?php

namespace Modules\Sirsoft\Benchmark\Models;

use App\Models\User;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;
use Illuminate\Database\Eloquent\Relations\HasMany;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Enums\WorkloadType;

class GenerationJob extends Model
{
    protected $table = 'generation_jobs';

    protected $fillable = [
        'uuid',
        'dataset_name',
        'dataset_slug',
        'workload_type',
        'seed',
        'status',
        'current_stage',
        'dry_run',
        'total_users',
        'total_boards',
        'total_posts',
        'estimated_comments',
        'total_categories',
        'total_brands',
        'total_products',
        'estimated_product_images',
        'processed_comment_candidates',
        'generated_users',
        'generated_boards',
        'generated_posts',
        'generated_comments',
        'generated_categories',
        'generated_brands',
        'generated_products',
        'generated_product_options',
        'generated_product_images',
        'progress_percent',
        'current_step',
        'options',
        'plan',
        'runtime_state',
        'last_error',
        'started_at',
        'finished_at',
        'stop_requested_at',
        'last_heartbeat_at',
        'requested_by',
    ];

    protected function casts(): array
    {
        return [
            'seed' => 'integer',
            'dry_run' => 'boolean',
            'total_users' => 'integer',
            'total_boards' => 'integer',
            'total_posts' => 'integer',
            'estimated_comments' => 'integer',
            'total_categories' => 'integer',
            'total_brands' => 'integer',
            'total_products' => 'integer',
            'estimated_product_images' => 'integer',
            'processed_comment_candidates' => 'integer',
            'generated_users' => 'integer',
            'generated_boards' => 'integer',
            'generated_posts' => 'integer',
            'generated_comments' => 'integer',
            'generated_categories' => 'integer',
            'generated_brands' => 'integer',
            'generated_products' => 'integer',
            'generated_product_options' => 'integer',
            'generated_product_images' => 'integer',
            'progress_percent' => 'decimal:2',
            'options' => 'array',
            'plan' => 'array',
            'runtime_state' => 'array',
            'started_at' => 'datetime',
            'finished_at' => 'datetime',
            'stop_requested_at' => 'datetime',
            'last_heartbeat_at' => 'datetime',
            'status' => GenerationJobStatus::class,
            'current_stage' => GenerationStage::class,
            'workload_type' => WorkloadType::class,
        ];
    }

    public function logs(): HasMany
    {
        return $this->hasMany(GenerationJobLog::class, 'generation_job_id');
    }

    public function requester(): BelongsTo
    {
        return $this->belongsTo(User::class, 'requested_by');
    }

    public function isStopRequested(): bool
    {
        return in_array($this->status, [GenerationJobStatus::Stopping, GenerationJobStatus::Stopped], true)
            || $this->stop_requested_at !== null;
    }

    public function canResume(): bool
    {
        return in_array($this->status, [GenerationJobStatus::Pending, GenerationJobStatus::Stopped, GenerationJobStatus::Failed], true);
    }
}
