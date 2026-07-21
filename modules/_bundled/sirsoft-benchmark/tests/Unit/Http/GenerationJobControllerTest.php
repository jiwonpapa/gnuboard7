<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Http;

use Modules\Sirsoft\Benchmark\Http\Controllers\Admin\GenerationJobController;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use PHPUnit\Framework\TestCase;
use ReflectionClass;

class GenerationJobControllerTest extends TestCase
{
    public function test_commerce_generation_preflight_cursor_is_not_presented_as_reset(): void
    {
        $runtimeState = [
            'reset_phase' => 'preflight',
            'verification' => ['status' => 'passed'],
        ];
        $job = new GenerationJob([
            'workload_type' => 'commerce',
            'status' => 'completed',
            'current_stage' => 'completed',
            'current_step' => '쇼핑몰 더미데이터 생성과 검증이 완료되었습니다.',
            'runtime_state' => $runtimeState,
        ]);

        $reset = $this->presentResetState($job, $runtimeState);

        $this->assertFalse($reset['is_reset']);
        $this->assertFalse($reset['is_active']);
        $this->assertFalse($reset['is_completed']);
        $this->assertNull($reset['phase']);
    }

    public function test_explicit_reset_marker_is_presented_as_completed_reset(): void
    {
        $runtimeState = [
            'reset_phase' => 'completed',
            'reset_started_at' => '2026-07-21T01:00:00+00:00',
            'reset_finished_at' => '2026-07-21T01:02:00+00:00',
            'cleanup' => ['deleted_products' => 10000],
        ];
        $job = new GenerationJob([
            'workload_type' => 'commerce',
            'status' => 'completed',
            'current_stage' => 'completed',
            'current_step' => '쇼핑몰 데이터셋 초기화가 완료되었습니다.',
            'runtime_state' => $runtimeState,
        ]);

        $reset = $this->presentResetState($job, $runtimeState);

        $this->assertTrue($reset['is_reset']);
        $this->assertFalse($reset['is_active']);
        $this->assertTrue($reset['is_completed']);
        $this->assertSame('completed', $reset['phase']);
    }

    public function test_stopped_board_target_summary_distinguishes_generated_rows_from_plan(): void
    {
        $job = new GenerationJob([
            'workload_type' => 'board',
            'status' => 'stopped',
            'current_stage' => 'posts',
            'plan' => [
                'board_plans' => [[
                    'index' => 0,
                    'board_id' => 7,
                    'slug' => 'free',
                    'name' => '자유게시판',
                    'target_posts' => 100,
                    'estimated_comments' => 150,
                ]],
            ],
            'runtime_state' => [
                'board_states' => [[
                    'index' => 0,
                    'generated_posts' => 37,
                    'generated_comments' => 51,
                ]],
            ],
        ]);
        $controller = (new ReflectionClass(GenerationJobController::class))
            ->newInstanceWithoutConstructor();
        $reflection = new ReflectionClass(GenerationJobController::class);
        $targets = $reflection->getMethod('presentTargets')->invoke($controller, $job);
        $summary = $reflection->getMethod('targetSummary')->invoke($controller, $job, $targets);

        $this->assertSame(37, $targets[0]['generated_posts']);
        $this->assertSame(51, $targets[0]['generated_comments']);
        $this->assertSame('자유게시판 (free, ID 7) · 게시글 37건 (목표 100건)', $summary);
    }

    /**
     * @param  array<string, mixed>  $runtimeState
     * @return array<string, mixed>
     */
    private function presentResetState(GenerationJob $job, array $runtimeState): array
    {
        $controller = (new ReflectionClass(GenerationJobController::class))
            ->newInstanceWithoutConstructor();
        $method = (new ReflectionClass(GenerationJobController::class))
            ->getMethod('presentResetState');

        return $method->invoke(
            $controller,
            $job,
            $runtimeState,
            $runtimeState['cleanup'] ?? null
        );
    }
}
