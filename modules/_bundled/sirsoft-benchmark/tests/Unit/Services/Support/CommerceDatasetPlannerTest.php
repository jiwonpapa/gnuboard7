<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services\Support;

use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\CommerceDatasetPlanner;
use PHPUnit\Framework\TestCase;

class CommerceDatasetPlannerTest extends TestCase
{
    public function test_it_builds_reproducible_three_level_commerce_plan(): void
    {
        $job = (new GenerationJob)->forceFill([
            'id' => 42,
            'seed' => 20260715,
            'dataset_slug' => 'bm-job-42-commerce',
        ]);
        $bundle = (new CommerceDatasetPlanner)->build($job, [
            'seed' => 20260715,
            'total_categories' => 100,
            'category_depth' => 3,
            'total_brands' => 50,
            'total_products' => 10000,
            'image_coverage' => 0.8,
            'max_images_per_product' => 2,
            'image_pool_size' => 100,
            'batch_size' => 500,
        ]);

        $specs = $bundle['plan']['category_specs'];
        $this->assertCount(100, $specs);
        $this->assertSame('bmj-42-category-001', $specs[0]['slug']);
        $this->assertContains(2, array_column($specs, 'depth'));
        $this->assertSame(12000, $bundle['plan']['estimated_product_images']);
        $this->assertSame(20, $bundle['plan']['estimated_batches']['products']);
        $this->assertSame(0, $bundle['runtime_state']['product_offset']);
    }

    public function test_two_level_plan_never_creates_depth_two_categories(): void
    {
        $job = (new GenerationJob)->forceFill(['id' => 7, 'seed' => 1]);
        $bundle = (new CommerceDatasetPlanner)->build($job, [
            'seed' => 1,
            'total_categories' => 20,
            'category_depth' => 2,
            'total_brands' => 0,
            'total_products' => 500,
            'image_coverage' => 1,
            'max_images_per_product' => 1,
            'image_pool_size' => 20,
            'batch_size' => 250,
        ]);

        $this->assertLessThanOrEqual(1, max(array_column($bundle['plan']['category_specs'], 'depth')));
        $this->assertSame(500, $bundle['plan']['estimated_product_images']);
    }
}
