<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

class UserIdResolver
{
    /**
     * @param  array<int, array<string, int>>  $segments
     */
    public function resolve(array $segments, int $offset): ?int
    {
        foreach ($segments as $segment) {
            if ($offset < $segment['offset_start'] || $offset > $segment['offset_end']) {
                continue;
            }

            return $segment['first_id'] + ($offset - $segment['offset_start']);
        }

        return null;
    }
}
