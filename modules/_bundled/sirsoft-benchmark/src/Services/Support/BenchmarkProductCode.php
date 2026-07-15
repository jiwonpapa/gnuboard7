<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Illuminate\Database\Query\Builder;

final class BenchmarkProductCode
{
    private const PREFIX = 'BMJ';

    private const JOB_WIDTH = 4;

    private const SEQUENCE_WIDTH = 9;

    public static function make(int $jobId, int $sequence): string
    {
        return self::PREFIX
            .self::encode($jobId, self::JOB_WIDTH, '작업 ID')
            .self::encode($sequence, self::SEQUENCE_WIDTH, '상품 순번');
    }

    public static function prefix(int $jobId): string
    {
        return self::PREFIX.self::encode($jobId, self::JOB_WIDTH, '작업 ID');
    }

    public static function legacyPrefix(int $jobId): string
    {
        if ($jobId <= 0) {
            throw new \InvalidArgumentException('작업 ID는 1 이상이어야 합니다.');
        }

        return self::PREFIX.$jobId.'-';
    }

    public static function constrain(Builder $query, int $jobId, string $column = 'product_code'): Builder
    {
        $current = self::prefix($jobId).'%';
        $legacy = self::legacyPrefix($jobId).'%';

        return $query->where(function (Builder $nested) use ($column, $current, $legacy) {
            $nested->where($column, 'like', $current)
                ->orWhere($column, 'like', $legacy);
        });
    }

    private static function encode(int $value, int $width, string $label): string
    {
        if ($value <= 0) {
            throw new \InvalidArgumentException("{$label}는 1 이상이어야 합니다.");
        }

        $encoded = strtoupper(base_convert((string) $value, 10, 36));
        if (strlen($encoded) > $width) {
            throw new \RuntimeException("{$label}가 벤치마크 상품 코드 범위를 초과했습니다.");
        }

        return str_pad($encoded, $width, '0', STR_PAD_LEFT);
    }
}
