<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services;

use Illuminate\Config\Repository;
use Illuminate\Container\Container;
use Mockery;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\GenerationJobService;
use Modules\Sirsoft\Benchmark\Services\Support\CommerceDatasetPlanner;
use Modules\Sirsoft\Benchmark\Services\Support\DatasetPlanner;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;
use PHPUnit\Framework\TestCase;
use RuntimeException;

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

    public function test_queue_settings_are_resolved_from_cached_config(): void
    {
        $previousContainer = Container::getInstance();
        $container = new Container;
        $container->instance('config', new Repository([
            'benchmark' => [
                'queue_connection' => 'redis',
                'queue_name' => 'benchmark-reset',
            ],
            'queue' => [
                'default' => 'database',
                'connections' => [
                    'redis' => ['queue' => 'default'],
                    'database' => ['queue' => 'database-default'],
                ],
            ],
        ]));
        Container::setInstance($container);

        try {
            $service = new class(Mockery::mock(DatasetPlanner::class), Mockery::mock(CommerceDatasetPlanner::class), Mockery::mock(GenerationJobLogger::class)) extends GenerationJobService
            {
                /** @return array{0: string, 1: string} */
                public function resolvedQueue(): array
                {
                    return [$this->resolveQueueConnection(), $this->resolveQueueName()];
                }
            };

            $this->assertSame(['redis', 'benchmark-reset'], $service->resolvedQueue());
        } finally {
            Container::setInstance($previousContainer);
        }
    }

    public function test_reset_dispatch_failure_marks_job_failed_and_rethrows(): void
    {
        $logger = Mockery::mock(GenerationJobLogger::class);
        $logger->shouldReceive('error')->once();
        $service = new class(Mockery::mock(DatasetPlanner::class), Mockery::mock(CommerceDatasetPlanner::class), $logger) extends GenerationJobService
        {
            protected function resolveQueueConnection(): string
            {
                return 'redis';
            }

            protected function resolveQueueName(): string
            {
                return 'default';
            }

            protected function dispatchResetJob(GenerationJob $job, string $connection, string $queue): void
            {
                throw new RuntimeException('redis unavailable');
            }
        };
        $job = Mockery::mock(GenerationJob::class)->makePartial();
        $job->id = 77;
        $job->status = GenerationJobStatus::Running;
        $job->current_stage = GenerationStage::Resetting;
        $job->shouldReceive('save')->once()->andReturnTrue();

        try {
            $service->dispatchReset($job);
            $this->fail('dispatch 예외가 다시 전달되어야 합니다.');
        } catch (RuntimeException $exception) {
            $this->assertSame('redis unavailable', $exception->getMessage());
        }

        $this->assertSame(GenerationJobStatus::Failed, $job->status);
        $this->assertSame(GenerationStage::Resetting, $job->current_stage);
        $this->assertSame('redis unavailable', $job->last_error);
    }
}
