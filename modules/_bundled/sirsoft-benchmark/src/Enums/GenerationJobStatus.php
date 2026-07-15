<?php

namespace Modules\Sirsoft\Benchmark\Enums;

enum GenerationJobStatus: string
{
    case Pending = 'pending';
    case Running = 'running';
    case Stopping = 'stopping';
    case Stopped = 'stopped';
    case Completed = 'completed';
    case Failed = 'failed';

    public function isTerminal(): bool
    {
        return in_array($this, [self::Stopped, self::Completed, self::Failed], true);
    }
}
