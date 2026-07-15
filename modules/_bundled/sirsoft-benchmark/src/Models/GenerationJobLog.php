<?php

namespace Modules\Sirsoft\Benchmark\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

class GenerationJobLog extends Model
{
    public const UPDATED_AT = null;

    protected $table = 'generation_job_logs';

    protected $fillable = [
        'generation_job_id',
        'level',
        'stage',
        'message',
        'context',
        'created_at',
    ];

    protected function casts(): array
    {
        return [
            'context' => 'array',
            'created_at' => 'datetime',
        ];
    }

    public function job(): BelongsTo
    {
        return $this->belongsTo(GenerationJob::class, 'generation_job_id');
    }
}
