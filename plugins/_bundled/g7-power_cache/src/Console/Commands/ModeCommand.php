<?php

namespace Plugins\G7\PowerCache\Console\Commands;

use App\Services\PluginSettingsService;
use Illuminate\Console\Command;
use Plugins\G7\PowerCache\Diagnostics\PowerCacheInspector;
use Plugins\G7\PowerCache\Runtime\PowerCacheSettings;

final class ModeCommand extends Command
{
    protected $signature = 'power-cache:mode
        {mode : observe|active|bypass}
        {--json : JSON 형식으로 출력}';

    protected $description = 'G7PowerCache 실행 모드를 안전하게 전환합니다.';

    public function handle(
        PluginSettingsService $settings,
        PowerCacheInspector $inspector,
    ): int {
        $mode = strtolower(trim((string) $this->argument('mode')));
        if (! in_array($mode, ['observe', 'active', 'bypass'], true)) {
            return $this->respond([
                'ok' => false,
                'mode' => $mode,
                'error' => 'mode는 observe, active, bypass 중 하나여야 합니다.',
            ], self::INVALID);
        }

        if ($mode === 'active') {
            $preflight = $inspector->inspect(true);
            if (! $preflight['ok']) {
                return $this->respond([
                    'ok' => false,
                    'mode' => $mode,
                    'error' => 'doctor 진단이 실패해 active 전환을 차단했습니다.',
                    'doctor' => $preflight,
                ], self::FAILURE);
            }
        }

        $failureReason = null;
        if (! $settings->save(PowerCacheSettings::IDENTIFIER, ['mode' => $mode], $failureReason)) {
            return $this->respond([
                'ok' => false,
                'mode' => $mode,
                'error' => $failureReason ?? '플러그인 설정 저장에 실패했습니다.',
            ], self::FAILURE);
        }

        $status = $inspector->inspect($mode === 'active');

        return $this->respond([
            'ok' => $status['ok'],
            'mode' => $mode,
            'driver' => $status['driver'],
            'dirty_event_id' => $status['dirty_event_id'],
            'pending_outbox' => $status['pending_outbox'],
            'emergency_dirty' => $status['emergency_dirty'],
            'errors' => $status['errors'],
        ], $status['ok'] ? self::SUCCESS : self::FAILURE);
    }

    /** @param array<string, mixed> $result */
    private function respond(array $result, int $exitCode): int
    {
        if ($this->option('json')) {
            $this->line(json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

            return $exitCode;
        }

        if ($result['ok']) {
            $this->info(sprintf(
                'mode=%s driver=%s dirty=%s pending=%s emergency=%s',
                $result['mode'],
                $result['driver'],
                (string) ($result['dirty_event_id'] ?? '-'),
                (string) ($result['pending_outbox'] ?? '-'),
                ($result['emergency_dirty'] ?? false) ? 'yes' : 'no',
            ));
        } else {
            $this->error((string) ($result['error'] ?? '모드 전환 뒤 진단이 실패했습니다.'));
            foreach ($result['errors'] ?? [] as $error) {
                $this->error((string) $error);
            }
        }

        return $exitCode;
    }
}
