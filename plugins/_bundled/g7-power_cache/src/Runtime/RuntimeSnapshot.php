<?php

namespace Plugins\G7\PowerCache\Runtime;

final readonly class RuntimeSnapshot
{
    public function __construct(
        public string $siteId,
        public string $runtimeEpoch,
        public int $dirtyEventId,
    ) {}

    public function isDirty(): bool
    {
        return $this->dirtyEventId > 0;
    }
}
