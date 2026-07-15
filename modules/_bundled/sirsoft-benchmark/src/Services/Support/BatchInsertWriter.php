<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Illuminate\Support\Facades\DB;

class BatchInsertWriter
{
    /**
     * @param  array<int, array<string, mixed>>  $rows
     * @return array{first_id:int, count:int}
     */
    public function insertAndReturnRange(string $table, array $rows): array
    {
        if ($rows === []) {
            return ['first_id' => 0, 'count' => 0];
        }

        DB::table($table)->insert($rows);
        $firstId = (int) DB::getPdo()->lastInsertId();

        return [
            'first_id' => $firstId,
            'count' => count($rows),
        ];
    }

    /**
     * @param  array<int, array<string, mixed>>  $rows
     */
    public function insert(string $table, array $rows): void
    {
        if ($rows === []) {
            return;
        }

        DB::table($table)->insert($rows);
    }
}
