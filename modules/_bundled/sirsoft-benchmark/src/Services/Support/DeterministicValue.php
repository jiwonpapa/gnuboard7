<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

class DeterministicValue
{
    public function integer(int $seed, int $sequence, string $key, int $min, int $max): int
    {
        if ($max <= $min) {
            return $min;
        }

        $value = (int) hexdec(substr(hash('sha256', "{$seed}:{$sequence}:{$key}"), 0, 8));

        return $min + ($value % ($max - $min + 1));
    }

    public function chance(int $seed, int $sequence, string $key, float $probability): bool
    {
        if ($probability <= 0) {
            return false;
        }

        if ($probability >= 1) {
            return true;
        }

        return $this->integer($seed, $sequence, $key, 0, 999999) < (int) round($probability * 1000000);
    }

    public function pick(array $values, int $seed, int $sequence, string $key, mixed $default = null): mixed
    {
        if ($values === []) {
            return $default;
        }

        return $values[$this->integer($seed, $sequence, $key, 0, count($values) - 1)];
    }
}
