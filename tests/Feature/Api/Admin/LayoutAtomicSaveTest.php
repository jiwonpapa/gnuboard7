<?php

declare(strict_types=1);

namespace Tests\Feature\Api\Admin;

use App\Contracts\Repositories\LayoutRepositoryInterface;
use App\Contracts\Repositories\LayoutVersionRepositoryInterface;
use App\Exceptions\ConcurrentModificationException;
use App\Models\Template;
use App\Models\TemplateLayout;
use App\Models\TemplateLayoutVersion;
use App\Repositories\LayoutRepository;
use App\Repositories\LayoutVersionRepository;
use App\Services\LayoutService;
use Illuminate\Foundation\Testing\DatabaseTransactions;
use Mockery;
use RuntimeException;
use Tests\TestCase;

class LayoutAtomicSaveTest extends TestCase
{
    use DatabaseTransactions;

    public function test_atomic_writer_capability_is_advertised(): void
    {
        $this->assertSame('g7.layout.content.row-lock.v1', LayoutRepositoryInterface::ATOMIC_CONTENT_CAPABILITY);
    }

    private function layout(): TemplateLayout
    {
        return TemplateLayout::factory()->create([
            'template_id' => Template::factory()->create(['type' => 'user'])->id,
            'content' => ['components' => []],
            'lock_version' => 0,
        ]);
    }

    /**
     * @scenario operation=stale_write
     *
     * @effects winning_content_preserved
     */
    public function test_repository_rejects_a_writer_using_the_same_previous_version(): void
    {
        $layout = $this->layout();
        $repository = app(LayoutRepository::class);
        $winner = ['components' => [], 'extends' => 'winner'];
        $repository->updateContent($layout->id, $winner, 1);
        try {
            $repository->updateContent($layout->id, ['components' => []], 1);
            self::fail('A stale writer overwrote the winning content.');
        } catch (ConcurrentModificationException $error) {
            self::assertSame(1, $error->currentVersion);
            self::assertSame(0, $error->expectedVersion);
        }
        self::assertSame($winner, $layout->fresh()->content);
        self::assertSame('winner', $layout->fresh()->extends);
        self::assertSame(1, $layout->fresh()->lock_version);
    }

    /**
     * @scenario operation=history_failure
     *
     * @effects content_and_history_rolled_back
     */
    public function test_history_failure_rolls_back_content_and_lock_version(): void
    {
        $layout = $this->layout();
        $versions = Mockery::mock(LayoutVersionRepositoryInterface::class);
        $versions->shouldReceive('getNextVersion')->andReturn(1);
        $nativeVersions = app(LayoutVersionRepository::class);
        $versions->shouldReceive('saveVersion')->andReturnUsing(function (int $id, array $content, ?array $previous) use ($nativeVersions): TemplateLayoutVersion {
            if ($previous === null) {
                return $nativeVersions->saveVersion($id, $content, $previous);
            }
            throw new RuntimeException('history failure');
        });
        app()->instance(LayoutVersionRepositoryInterface::class, $versions);
        try {
            app(LayoutService::class)->updateLayout($layout->template_id, $layout->name, [
                'expected_lock_version' => 0,
                'content' => ['components' => [], 'extends' => 'changed'],
            ]);
            self::fail('Expected the injected history failure.');
        } catch (RuntimeException $error) {
            self::assertSame('history failure', $error->getMessage());
        }
        self::assertSame($layout->content, $layout->fresh()->content);
        self::assertSame(0, $layout->fresh()->lock_version);
        self::assertSame(0, TemplateLayoutVersion::where('layout_id', $layout->id)->count());
    }

    /**
     * @scenario operation=save
     *
     * @effects baseline_and_snapshot_committed
     */
    public function test_success_keeps_baseline_and_current_snapshot_together(): void
    {
        $layout = $this->layout();
        $content = ['components' => [], 'extends' => 'changed'];
        $saved = app(LayoutService::class)->updateLayout($layout->template_id, $layout->name, [
            'expected_lock_version' => 0, 'content' => $content,
        ]);
        self::assertSame(1, $saved->lock_version);
        self::assertSame(2, $saved->current_version);
        self::assertSame([$layout->content, $content], TemplateLayoutVersion::where('layout_id', $layout->id)
            ->orderBy('version')->get()->pluck('content')->all());
    }

    /**
     * @scenario operation=restore
     *
     * @effects restored_revision_invalidates_editor
     */
    public function test_restore_advances_revision_and_invalidates_an_open_editor(): void
    {
        $layout = $this->layout();
        $service = app(LayoutService::class);
        $service->updateLayout($layout->template_id, $layout->name, [
            'expected_lock_version' => 0,
            'content' => ['components' => [], 'extends' => 'changed'],
        ]);
        $baseline = TemplateLayoutVersion::where('layout_id', $layout->id)->orderBy('version')->firstOrFail();
        $service->restoreVersion($layout->template_id, $layout->name, $baseline->id);
        self::assertSame(2, $layout->fresh()->lock_version);
        self::assertNull($layout->fresh()->extends);
        self::assertSame($baseline->content, $layout->fresh()->content);
        $this->expectException(ConcurrentModificationException::class);
        $service->updateLayout($layout->template_id, $layout->name, [
            'expected_lock_version' => 1, 'content' => ['components' => []],
        ]);
    }
}
