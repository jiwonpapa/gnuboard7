<?php

declare(strict_types=1);

namespace Tests\Feature\Api\Admin;

use App\Models\Template;
use App\Models\TemplateLayout;
use Symfony\Component\Process\InputStream;
use Symfony\Component\Process\Process;
use Tests\TestCase;

class LayoutConcurrentSaveTest extends TestCase
{
    /**
     * @scenario operation=concurrent_write
     *
     * @effects one_concurrent_writer_succeeds
     */
    public function test_two_independent_connections_cannot_both_save_the_same_revision(): void
    {
        // 자식 연결에서 보여야 하므로 바깥 테스트 트랜잭션을 사용하지 않는다.
        $template = Template::factory()->create(['type' => 'user']);
        $layout = TemplateLayout::factory()->create([
            'template_id' => $template->id, 'content' => ['components' => []], 'lock_version' => 0,
        ]);
        $workers = [];
        $inputs = [];
        try {
            foreach (['first', 'second'] as $writer) {
                $input = new InputStream;
                $process = new Process([PHP_BINARY, base_path('tests/Fixtures/layout-atomic-writer.php'), (string) $layout->id, $writer], base_path());
                $process->setTimeout(20);
                $process->setInput($input);
                $process->start();
                $workers[] = $process;
                $inputs[] = $input;
            }
            foreach ($workers as $worker) {
                self::assertTrue(str_contains($worker->getOutput(), 'ready') || $worker->waitUntil(fn (string $type, string $output): bool => str_contains($output, 'ready')), $worker->getErrorOutput());
            }
            foreach ($inputs as $input) {
                $input->write("save\n");
                $input->close();
            }
            $results = [];
            foreach ($workers as $worker) {
                self::assertSame(0, $worker->wait(), $worker->getErrorOutput());
                $results[] = trim(substr($worker->getOutput(), strlen("ready\n")));
            }
            sort($results);
            self::assertSame(['conflict', 'saved'], $results);
            self::assertSame(1, $layout->fresh()->lock_version);
            self::assertContains($layout->fresh()->extends, ['first', 'second']);
            self::assertSame($layout->fresh()->extends, $layout->fresh()->content['extends']);
        } finally {
            foreach ($workers as $worker) {
                if ($worker->isRunning()) {
                    $worker->stop();
                }
            }
            $layout->forceDelete();
            $template->forceDelete();
        }
    }
}
