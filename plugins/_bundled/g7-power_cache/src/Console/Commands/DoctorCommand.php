<?php

namespace Plugins\G7\PowerCache\Console\Commands;

use Illuminate\Console\Command;
use Plugins\G7\PowerCache\Diagnostics\PowerCacheInspector;

final class DoctorCommand extends Command
{
    protected $signature = 'power-cache:doctor {--json : JSON 형식으로 출력}';

    protected $description = 'G7PowerCache 활성화 전 안전 계약과 저장소를 진단합니다.';

    public function handle(PowerCacheInspector $inspector): int
    {
        $result = $inspector->inspect(true);
        if ($this->option('json')) {
            $this->line(json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

            return $result['ok'] ? self::SUCCESS : self::FAILURE;
        }

        $this->table(['항목', '값'], [
            ['판정', $result['ok'] ? 'PASS' : 'FAIL'],
            ['모드', $result['mode']],
            ['저장소', $result['driver']],
            ['테이블', $result['tables_ready'] ? 'ready' : 'missing'],
            ['저장소 probe', ($result['store']['ok'] ?? false) ? 'ready' : 'failed'],
            ['DB dirty event', (string) ($result['dirty_event_id'] ?? '-')],
            ['미적용 outbox', (string) ($result['pending_outbox'] ?? '-')],
            ['비상 dirty', $result['emergency_dirty'] ? 'yes' : 'no'],
        ]);

        foreach ($result['warnings'] as $warning) {
            $this->warn($warning);
        }
        foreach ($result['errors'] as $error) {
            $this->error($error);
        }

        return $result['ok'] ? self::SUCCESS : self::FAILURE;
    }
}
