<?php

namespace Plugins\G7\PowerCache\Console\Commands;

use Illuminate\Console\Command;
use Plugins\G7\PowerCache\Diagnostics\PowerCacheInspector;

final class StatusCommand extends Command
{
    protected $signature = 'power-cache:status {--json : JSON 형식으로 출력}';

    protected $description = 'G7PowerCache 모드와 복구 장벽 상태를 조회합니다.';

    public function handle(PowerCacheInspector $inspector): int
    {
        $result = $inspector->inspect(false);
        if ($this->option('json')) {
            $this->line(json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));

            return $result['ok'] ? self::SUCCESS : self::FAILURE;
        }

        $this->line(sprintf(
            'mode=%s driver=%s tables=%s dirty=%s pending=%s emergency=%s',
            $result['mode'],
            $result['driver'],
            $result['tables_ready'] ? 'ready' : 'missing',
            (string) ($result['dirty_event_id'] ?? '-'),
            (string) ($result['pending_outbox'] ?? '-'),
            $result['emergency_dirty'] ? 'yes' : 'no',
        ));

        foreach ($result['errors'] as $error) {
            $this->error($error);
        }

        return $result['ok'] ? self::SUCCESS : self::FAILURE;
    }
}
