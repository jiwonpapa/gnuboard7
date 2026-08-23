<?php

namespace Plugins\G7\PowerCache\Eligibility;

final readonly class EligibilityResult
{
    private function __construct(
        public bool $eligible,
        public string $reason,
    ) {}

    public static function allow(): self
    {
        return new self(true, 'eligible');
    }

    public static function bypass(string $reason): self
    {
        return new self(false, $reason);
    }
}
