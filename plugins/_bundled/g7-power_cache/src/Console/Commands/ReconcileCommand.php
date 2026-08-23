<?php

namespace Plugins\G7\PowerCache\Console\Commands;

use Illuminate\Console\Command;
use Plugins\G7\PowerCache\Invalidation\OutboxReconciler;

final class ReconcileCommand extends Command
{
    protected $signature = 'power-cache:reconcile {--limit=100 : 한 번에 재생할 최대 이벤트 수} {--json : JSON 형식으로 출력}';

    protected $description = '미적용 G7PowerCache 무효화 아웃박스를 멱등 재생합니다.';

    public function handle(OutboxReconciler $reconciler): int
    {
        $limit = min(1000, max(1, (int) $this->option('limit')));
        $result = $reconciler->reconcile($limit);

        if ($this->option('json')) {
            $this->line(json_encode($result, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
        } else {
            $this->line(sprintf(
                'attempted=%d applied=%d remaining=%d locked=%s error=%s',
                $result['attempted'],
                $result['applied'],
                $result['remaining'],
                $result['locked'] ? 'yes' : 'no',
                $result['error'] ?? '-',
            ));
        }

        return $result['error'] === null ? self::SUCCESS : self::FAILURE;
    }
}
