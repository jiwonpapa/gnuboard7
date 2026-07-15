<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

class SeededRandom
{
    private int $state;

    public function __construct(int $seed)
    {
        $normalized = abs($seed % 2147483647);
        $this->state = $normalized === 0 ? 1 : $normalized;
    }

    public function getState(): int
    {
        return $this->state;
    }

    public function setState(int $state): void
    {
        $normalized = abs($state % 2147483647);
        $this->state = $normalized === 0 ? 1 : $normalized;
    }

    public function nextRaw(): int
    {
        $this->state = (int) (($this->state * 48271) % 2147483647);

        return $this->state;
    }

    public function nextFloat(): float
    {
        return $this->nextRaw() / 2147483647;
    }

    public function nextInt(int $min, int $max): int
    {
        if ($max <= $min) {
            return $min;
        }

        $range = $max - $min + 1;

        return $min + ($this->nextRaw() % $range);
    }

    public function chance(float $probability): bool
    {
        if ($probability <= 0) {
            return false;
        }

        if ($probability >= 1) {
            return true;
        }

        return $this->nextFloat() <= $probability;
    }

    public function pick(array $values, mixed $default = null): mixed
    {
        if ($values === []) {
            return $default;
        }

        return $values[$this->nextInt(0, count($values) - 1)];
    }
}
