<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services\Support;

use Modules\Sirsoft\Benchmark\Services\Support\DeterministicValue;
use PHPUnit\Framework\TestCase;

class DeterministicValueTest extends TestCase
{
    public function test_same_seed_sequence_and_key_return_same_value(): void
    {
        $random = new DeterministicValue;

        $first = $random->integer(20260715, 123, 'price', 100, 100000);
        $second = $random->integer(20260715, 123, 'price', 100, 100000);

        $this->assertSame($first, $second);
        $this->assertGreaterThanOrEqual(100, $first);
        $this->assertLessThanOrEqual(100000, $first);
    }
}
