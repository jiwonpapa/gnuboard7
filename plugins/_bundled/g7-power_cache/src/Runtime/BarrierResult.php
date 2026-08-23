<?php

namespace Plugins\G7\PowerCache\Runtime;

final readonly class BarrierResult
{
    private function __construct(
        public bool $ready,
        public string $reason,
        public ?RuntimeSnapshot $snapshot,
    ) {}

    public static function ready(RuntimeSnapshot $snapshot): self
    {
        return new self(true, 'ready', $snapshot);
    }

    public static function blocked(string $reason): self
    {
        return new self(false, $reason, null);
    }
}
