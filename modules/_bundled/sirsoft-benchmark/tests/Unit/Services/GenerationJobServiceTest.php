<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services;

use Mockery;
use Modules\Sirsoft\Benchmark\Services\GenerationJobService;
use Modules\Sirsoft\Benchmark\Services\Support\CommerceDatasetPlanner;
use Modules\Sirsoft\Benchmark\Services\Support\DatasetPlanner;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;
use PHPUnit\Framework\TestCase;

class GenerationJobServiceTest extends TestCase
{
    protected function tearDown(): void
    {
        Mockery::close();
        parent::tearDown();
    }

    public function test_commerce_options_use_bounded_select_values_without_board_targets(): void
    {
        $service = new GenerationJobService(
            Mockery::mock(DatasetPlanner::class),
            new CommerceDatasetPlanner,
            Mockery::mock(GenerationJobLogger::class)
        );

        $options = $service->normalizeOptions([
            'workload_type' => 'commerce',
            'dataset_name' => 'commerce-load',
            'total_products' => 200000,
            'total_categories' => 500,
            'total_brands' => 100,
            'image_pool_size' => 100,
            'image_coverage' => 0.8,
            'max_images_per_product' => 3,
            'batch_size' => 1000,
            'chunk_size' => 10000,
        ]);

        $this->assertSame(0, $options['total_users']);
        $this->assertSame(0, $options['total_boards']);
        $this->assertSame(0, $options['total_posts']);
        $this->assertSame(200000, $options['total_products']);
        $this->assertSame(1000, $options['batch_size']);
        $this->assertSame(10000, $options['chunk_size']);
        $this->assertSame('shared', $options['image_mode']);
    }
}
