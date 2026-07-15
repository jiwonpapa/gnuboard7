<?php

namespace Modules\Sirsoft\Benchmark\Services\Generators;

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;

class CommerceBrandGenerator
{
    /**
     * @param  array<string, mixed>  $state
     * @return array<string, mixed>
     */
    public function generateChunk(GenerationJob $job, array $state, int $limit = 50): array
    {
        $total = (int) $job->total_brands;
        $index = (int) ($state['brand_index'] ?? 0);
        $end = min($total, $index + $limit);
        $rows = [];
        $slugs = [];

        for ($offset = $index; $offset < $end; $offset++) {
            $sequence = $offset + 1;
            $slug = sprintf('bmj-%d-brand-%03d', $job->id, $sequence);
            $slugs[] = $slug;
            $rows[] = [
                'name' => $this->json(['ko' => "벤치 브랜드 {$sequence}", 'en' => "Bench brand {$sequence}"]),
                'slug' => $slug,
                'website' => null,
                'sort_order' => $sequence,
                'is_active' => true,
                'created_by' => $job->requested_by,
                'updated_by' => $job->requested_by,
                'created_at' => now(),
                'updated_at' => now(),
                'deleted_at' => null,
            ];
        }

        if ($rows !== []) {
            DB::table('ecommerce_brands')->insertOrIgnore($rows);
        }

        $ids = DB::table('ecommerce_brands')
            ->whereIn('slug', $slugs)
            ->orderBy('slug')
            ->pluck('id')
            ->map(fn ($id) => (int) $id)
            ->all();

        $state['brand_index'] = $end;
        $state['brand_ids'] = array_values(array_unique(array_merge($state['brand_ids'] ?? [], $ids)));

        return $state;
    }

    private function json(array $value): string
    {
        return (string) json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    }
}
