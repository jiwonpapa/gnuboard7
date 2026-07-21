<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services;

use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\CommerceDatasetResetService;
use PHPUnit\Framework\TestCase;
use ReflectionClass;

class CommerceDatasetResetServiceTest extends TestCase
{
    public function test_reset_progress_uses_deleted_rows_instead_of_generation_progress(): void
    {
        $service = (new ReflectionClass(CommerceDatasetResetService::class))
            ->newInstanceWithoutConstructor();
        $method = (new ReflectionClass(CommerceDatasetResetService::class))
            ->getMethod('calculateResetProgress');
        $job = new GenerationJob([
            'generated_products' => 10000,
            'generated_categories' => 50,
            'generated_brands' => 30,
        ]);

        $this->assertSame(40.0, $method->invoke($service, $job, [
            'reset_phase' => 'products',
            'cleanup' => ['deleted_products' => 5000],
        ]));
        $this->assertSame(80.0, $method->invoke($service, $job, [
            'reset_phase' => 'categories',
            'cleanup' => ['deleted_categories' => 0],
        ]));
        $this->assertSame(95.0, $method->invoke($service, $job, [
            'reset_phase' => 'files',
            'cleanup' => [],
        ]));
        $this->assertSame(100.0, $method->invoke($service, $job, [
            'reset_phase' => 'completed',
            'cleanup' => [],
        ]));
    }
}
