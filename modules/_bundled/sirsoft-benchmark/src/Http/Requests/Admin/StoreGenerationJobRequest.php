<?php

namespace Modules\Sirsoft\Benchmark\Http\Requests\Admin;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Rule;
use Modules\Sirsoft\Benchmark\Services\GenerationJobService;

class StoreGenerationJobRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /**
     * @return array<string, mixed>
     */
    public function rules(): array
    {
        $workloadType = $this->workloadType();
        $isBoard = $workloadType === 'board';
        $isCommerce = $workloadType === 'commerce';
        $batchSizes = $isCommerce
            ? GenerationJobService::ALLOWED_COMMERCE_BATCH_SIZES
            : GenerationJobService::ALLOWED_BATCH_SIZES;
        $chunkSizes = $isCommerce
            ? GenerationJobService::ALLOWED_COMMERCE_CHUNK_SIZES
            : GenerationJobService::ALLOWED_CHUNK_SIZES;

        return [
            'dataset_name' => ['required', 'string', 'max:100'],
            'workload_type' => ['nullable', Rule::in(['board', 'commerce'])],
            'total_users' => [Rule::excludeIf(! $isBoard), 'required', 'integer', 'min:1', 'max:1000000'],
            'selected_boards' => [Rule::excludeIf(! $isBoard), 'required', 'array', 'min:1', 'max:200'],
            'selected_boards.*.board_id' => [Rule::excludeIf(! $isBoard), 'required', 'integer', 'distinct', Rule::exists('boards', 'id')],
            'selected_boards.*.target_posts' => [Rule::excludeIf(! $isBoard), 'required', 'integer', 'min:1', 'max:100000000'],
            'comment_rate' => [Rule::excludeIf(! $isBoard), 'required', 'numeric', 'min:0', 'max:1'],
            'avg_comments_per_post' => [Rule::excludeIf(! $isBoard), 'required', 'numeric', 'min:0', 'max:500'],
            'max_comments_per_post' => [Rule::excludeIf(! $isBoard), 'required', 'integer', 'min:0', 'max:5000'],
            'total_products' => [Rule::excludeIf(! $isCommerce), 'required', 'integer', Rule::in([500, 1000, 5000, 10000, 50000, 100000, 200000])],
            'total_categories' => [Rule::excludeIf(! $isCommerce), 'required', 'integer', Rule::in([20, 50, 100, 200, 500])],
            'total_brands' => [Rule::excludeIf(! $isCommerce), 'required', 'integer', 'min:0', 'max:100'],
            'category_depth' => [Rule::excludeIf(! $isCommerce), 'required', 'integer', Rule::in([2, 3])],
            'category_distribution' => [Rule::excludeIf(! $isCommerce), 'nullable', Rule::in(['balanced', 'skewed'])],
            'image_pool_size' => [Rule::excludeIf(! $isCommerce), 'required', 'integer', Rule::in([20, 50, 100])],
            'image_coverage' => [Rule::excludeIf(! $isCommerce), 'required', 'numeric', 'min:0', 'max:1'],
            'max_images_per_product' => [Rule::excludeIf(! $isCommerce), 'required', 'integer', Rule::in([1, 2, 3])],
            'image_source' => [Rule::excludeIf(! $isCommerce), 'nullable', Rule::in(['picsum', 'generated'])],
            'image_mode' => [Rule::excludeIf(! $isCommerce), 'nullable', Rule::in(['shared'])],
            'batch_size' => ['required', 'integer', Rule::in($batchSizes)],
            'chunk_size' => ['required', 'integer', Rule::in($chunkSizes)],
            'seed' => ['nullable', 'integer', 'min:1', 'max:2147483646'],
            'dry_run' => ['nullable', 'boolean'],
            'time_distribution' => [Rule::excludeIf(! $isBoard), 'nullable', 'in:uniform,recent_burst,long_span'],
            'activity_profile' => [Rule::excludeIf(! $isBoard), 'nullable', 'in:balanced,skewed,extreme'],
        ];
    }

    private function workloadType(): string
    {
        return (string) $this->input('workload_type', 'board');
    }
}
