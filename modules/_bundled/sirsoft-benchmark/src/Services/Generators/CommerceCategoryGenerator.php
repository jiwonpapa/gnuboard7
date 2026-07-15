<?php

namespace Modules\Sirsoft\Benchmark\Services\Generators;

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;

class CommerceCategoryGenerator
{
    private const NAMES = ['디지털', '생활', '주방', '패션', '스포츠', '취미', '식품', '건강', '반려동물', '자동차'];

    /**
     * @param  array<string, mixed>  $state
     * @return array<string, mixed>
     */
    public function generateChunk(GenerationJob $job, array $state, int $limit = 25): array
    {
        $specs = $job->plan['category_specs'] ?? [];
        $index = (int) ($state['category_index'] ?? 0);
        $states = $state['category_states'] ?? [];
        $end = min(count($specs), $index + $limit);

        while ($index < $end) {
            $spec = $specs[$index];
            $sequence = (int) $spec['sequence'];
            $parentSequence = $spec['parent_sequence'] === null ? null : (int) $spec['parent_sequence'];
            $parent = $parentSequence === null ? null : ($states[$parentSequence - 1] ?? null);
            $slug = (string) $spec['slug'];
            [$categoryId, $path] = DB::transaction(function () use ($job, $parent, $sequence, $slug, $spec) {
                $existing = DB::table('ecommerce_categories')->where('slug', $slug)->first();
                if ($existing) {
                    $categoryId = (int) $existing->id;
                    $path = $parent ? "{$parent['path']}/{$categoryId}" : (string) $categoryId;
                    if ((string) $existing->path !== $path) {
                        DB::table('ecommerce_categories')->where('id', $categoryId)->update(['path' => $path]);
                    }

                    return [$categoryId, $path];
                }

                $categoryId = DB::table('ecommerce_categories')->insertGetId([
                    'name' => $this->json([
                        'ko' => self::NAMES[($sequence - 1) % count(self::NAMES)]." 상품 {$sequence}",
                        'en' => "Benchmark category {$sequence}",
                    ]),
                    'description' => $this->json([
                        'ko' => "벤치마크 작업 #{$job->id} 전용 상품 분류입니다.",
                        'en' => "Commerce benchmark category for job {$job->id}.",
                    ]),
                    'parent_id' => $parent['id'] ?? null,
                    'path' => 'pending',
                    'depth' => (int) $spec['depth'],
                    'sort_order' => $sequence,
                    'is_active' => true,
                    'slug' => $slug,
                    'meta_title' => "Benchmark category {$sequence}",
                    'meta_description' => "Commerce benchmark category {$sequence}",
                    'created_at' => now(),
                    'updated_at' => now(),
                ]);
                $path = $parent ? "{$parent['path']}/{$categoryId}" : (string) $categoryId;
                DB::table('ecommerce_categories')->where('id', $categoryId)->update(['path' => $path]);

                return [$categoryId, $path];
            });

            $states[$sequence - 1] = [
                'sequence' => $sequence,
                'id' => $categoryId,
                'path' => $path,
                'depth' => (int) $spec['depth'],
                'slug' => $slug,
                'is_leaf' => ! collect($specs)->contains(fn (array $candidate) => (int) ($candidate['parent_sequence'] ?? 0) === $sequence),
            ];
            $index++;
        }

        $state['category_index'] = $index;
        $state['category_states'] = array_values($states);

        return $state;
    }

    private function json(array $value): string
    {
        return (string) json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    }
}
