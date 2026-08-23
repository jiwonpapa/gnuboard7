<?php

namespace Plugins\G7\PowerCache\Policy;

final readonly class ResponseDecision
{
    /** @param array<string, array<int, string>> $headers */
    private function __construct(
        public bool $cacheable,
        public string $reason,
        public array $headers,
    ) {}

    /** @param array<string, array<int, string>> $headers */
    public static function allow(array $headers): self
    {
        return new self(true, 'cacheable', $headers);
    }

    public static function reject(string $reason): self
    {
        return new self(false, $reason, []);
    }
}
