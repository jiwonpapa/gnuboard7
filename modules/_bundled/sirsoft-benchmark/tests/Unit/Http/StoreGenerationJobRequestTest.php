<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Http;

use Illuminate\Translation\ArrayLoader;
use Illuminate\Translation\Translator;
use Illuminate\Validation\Factory;
use Modules\Sirsoft\Benchmark\Http\Requests\Admin\StoreGenerationJobRequest;
use PHPUnit\Framework\TestCase;

class StoreGenerationJobRequestTest extends TestCase
{
    public function test_commerce_payload_excludes_empty_board_fields(): void
    {
        $payload = [
            'dataset_name' => 'commerce-benchmark',
            'workload_type' => 'commerce',
            'selected_boards' => [],
            'total_users' => 10000,
            'total_products' => 500,
            'total_categories' => 20,
            'total_brands' => 20,
            'category_depth' => 3,
            'category_distribution' => 'skewed',
            'image_pool_size' => 20,
            'image_coverage' => 0.8,
            'max_images_per_product' => 2,
            'image_source' => 'generated',
            'image_mode' => 'shared',
            'batch_size' => 250,
            'chunk_size' => 2500,
            'seed' => 20260715,
            'dry_run' => false,
        ];
        $request = StoreGenerationJobRequest::create('/', 'POST', $payload);
        $validator = $this->validator()->make($payload, $request->rules());

        self::assertTrue($validator->passes(), json_encode($validator->errors()->toArray(), JSON_UNESCAPED_UNICODE));
        self::assertArrayNotHasKey('selected_boards', $validator->validated());
        self::assertArrayNotHasKey('total_users', $validator->validated());
    }

    public function test_board_payload_still_requires_selected_boards(): void
    {
        $payload = [
            'dataset_name' => 'board-benchmark',
            'workload_type' => 'board',
            'total_users' => 10000,
            'selected_boards' => [],
            'comment_rate' => 0.35,
            'avg_comments_per_post' => 2.4,
            'max_comments_per_post' => 20,
            'batch_size' => 3000,
            'chunk_size' => 20000,
            'seed' => 20260715,
            'dry_run' => false,
        ];
        $request = StoreGenerationJobRequest::create('/', 'POST', $payload);
        $validator = $this->validator()->make($payload, $request->rules());

        self::assertTrue($validator->fails());
        self::assertArrayHasKey('selected_boards', $validator->errors()->toArray());
    }

    private function validator(): Factory
    {
        return new Factory(new Translator(new ArrayLoader, 'ko'));
    }
}
