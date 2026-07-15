<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Modules\Sirsoft\Benchmark\Models\GenerationJob;

class CommerceDatasetPlanner
{
    /**
     * @return array{plan: array<string, mixed>, runtime_state: array<string, mixed>}
     */
    public function build(GenerationJob $job, array $options): array
    {
        $seed = (int) ($options['seed'] ?? $job->seed ?? $job->id);
        $categorySpecs = $this->buildCategorySpecs(
            (int) ($job->id ?? 0),
            (int) $options['total_categories'],
            (int) $options['category_depth']
        );
        $estimatedImages = (int) round(
            (int) $options['total_products']
            * (float) $options['image_coverage']
            * ((1 + (int) $options['max_images_per_product']) / 2)
        );

        return [
            'plan' => [
                'seed' => $seed,
                'workload_type' => 'commerce',
                'category_specs' => $categorySpecs,
                'estimated_product_images' => $estimatedImages,
                'estimated_rows' => [
                    'categories' => (int) $options['total_categories'],
                    'brands' => (int) $options['total_brands'],
                    'products' => (int) $options['total_products'],
                    'product_options' => (int) $options['total_products'],
                    'product_categories' => (int) $options['total_products'],
                    'product_images' => $estimatedImages,
                ],
                'estimated_batches' => [
                    'image_pool' => (int) ceil($options['image_pool_size'] / 10),
                    'categories' => (int) ceil($options['total_categories'] / 25),
                    'brands' => (int) ceil(max(1, $options['total_brands']) / 50),
                    'products' => (int) ceil($options['total_products'] / max(1, $options['batch_size'])),
                ],
                'physical_image_files' => (int) $options['image_pool_size'],
            ],
            'runtime_state' => [
                'image_pool_index' => 0,
                'image_pool' => [],
                'category_index' => 0,
                'category_states' => [],
                'brand_index' => 0,
                'brand_ids' => [],
                'product_offset' => 0,
                'verification' => null,
                'reset_phase' => 'preflight',
                'cleanup' => [
                    'deleted_products' => 0,
                    'deleted_categories' => 0,
                    'deleted_brands' => 0,
                    'deleted_files' => false,
                ],
            ],
        ];
    }

    /**
     * @return array<int, array<string, int|string|null>>
     */
    private function buildCategorySpecs(int $jobId, int $total, int $maxDepth): array
    {
        if ($total <= 0) {
            return [];
        }

        $rootCount = min($total, max(1, (int) ceil($total * 0.10)));
        $middleCount = $maxDepth >= 3
            ? min($total - $rootCount, max(0, (int) ceil($total * 0.30)))
            : 0;
        $specs = [];

        for ($sequence = 1; $sequence <= $total; $sequence++) {
            if ($sequence <= $rootCount) {
                $depth = 0;
                $parentSequence = null;
            } elseif ($sequence <= $rootCount + $middleCount) {
                $depth = 1;
                $parentSequence = (($sequence - $rootCount - 1) % $rootCount) + 1;
            } else {
                $depth = $maxDepth >= 3 && $middleCount > 0 ? 2 : 1;
                $parentBase = $depth === 2 ? $rootCount + 1 : 1;
                $parentCount = $depth === 2 ? $middleCount : $rootCount;
                $parentSequence = $parentBase + (($sequence - $rootCount - $middleCount - 1) % $parentCount);
            }

            $specs[] = [
                'sequence' => $sequence,
                'parent_sequence' => $parentSequence,
                'depth' => $depth,
                'slug' => sprintf('bmj-%d-category-%03d', $jobId, $sequence),
            ];
        }

        return $specs;
    }
}
