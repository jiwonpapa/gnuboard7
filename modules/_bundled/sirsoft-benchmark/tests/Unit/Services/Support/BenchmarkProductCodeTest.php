<?php

namespace Modules\Sirsoft\Benchmark\Tests\Unit\Services\Support;

use Modules\Sirsoft\Benchmark\Services\Support\BenchmarkProductCode;
use PHPUnit\Framework\TestCase;

class BenchmarkProductCodeTest extends TestCase
{
    public function test_code_matches_public_ecommerce_route_contract(): void
    {
        $code = BenchmarkProductCode::make(9, 9463);

        self::assertSame(16, strlen($code));
        self::assertMatchesRegularExpression('/^[0-9A-Za-z]+$/', $code);
        self::assertStringStartsWith(BenchmarkProductCode::prefix(9), $code);
    }

    public function test_job_and_sequence_are_encoded_without_collisions(): void
    {
        self::assertNotSame(
            BenchmarkProductCode::make(9, 1),
            BenchmarkProductCode::make(10, 1)
        );
        self::assertNotSame(
            BenchmarkProductCode::make(9, 1),
            BenchmarkProductCode::make(9, 2)
        );
    }

    public function test_invalid_identifiers_are_rejected(): void
    {
        $this->expectException(\InvalidArgumentException::class);

        BenchmarkProductCode::make(0, 1);
    }
}
