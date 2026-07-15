<?php

namespace Modules\Sirsoft\Benchmark\Services\Generators;

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\BenchmarkProductCode;
use Modules\Sirsoft\Benchmark\Services\Support\DeterministicValue;
use Modules\Sirsoft\Benchmark\Services\Support\DictionaryLoader;
use Modules\Sirsoft\Ecommerce\Services\CurrencyConversionService;

class CommerceProductGenerator
{
    public function __construct(
        private DeterministicValue $random,
        private DictionaryLoader $dictionaries,
        private CurrencyConversionService $currencyService
    ) {}

    /**
     * @param  array<string, mixed>  $state
     * @return array<string, mixed>
     */
    public function generateBatch(GenerationJob $job, array $state, ?int $limit = null): array
    {
        $options = $job->options ?? [];
        $total = (int) $job->total_products;
        $offset = (int) ($state['product_offset'] ?? 0);
        $batchSize = (int) ($options['batch_size'] ?? 500);
        if ($limit !== null) {
            $batchSize = min($batchSize, max(1, $limit));
        }
        $end = min($total, $offset + $batchSize);

        if ($offset >= $end) {
            return $state;
        }

        $currency = $this->currencyService->getDefaultCurrency();
        $categoryIds = $this->resolveCategoryIds($state);
        $brandIds = array_values(array_map('intval', $state['brand_ids'] ?? []));
        $imagePool = array_values($state['image_pool'] ?? []);
        $rows = [];
        $codes = [];
        $productBlueprints = [];

        for ($sequence = $offset + 1; $sequence <= $end; $sequence++) {
            $blueprint = $this->buildBlueprint($job, $sequence, $currency, $categoryIds, $brandIds, $imagePool);
            $rows[] = $blueprint['product'];
            $codes[] = $blueprint['product']['product_code'];
            $productBlueprints[$blueprint['product']['product_code']] = $blueprint;
        }

        $imageCount = 0;
        DB::transaction(function () use ($rows, $codes, $productBlueprints, &$imageCount) {
            DB::table('ecommerce_products')->insertOrIgnore($rows);
            $productIds = DB::table('ecommerce_products')
                ->whereIn('product_code', $codes)
                ->pluck('id', 'product_code');
            $options = [];
            $categories = [];
            $images = [];

            foreach ($productBlueprints as $code => $blueprint) {
                $productId = (int) ($productIds[$code] ?? 0);
                if ($productId <= 0) {
                    throw new \RuntimeException("생성한 상품 ID를 찾지 못했습니다: {$code}");
                }

                $options[] = array_merge($blueprint['option'], ['product_id' => $productId]);
                $categories[] = [
                    'product_id' => $productId,
                    'category_id' => $blueprint['category_id'],
                    'is_primary' => true,
                ];
                foreach ($blueprint['images'] as $image) {
                    $images[] = array_merge($image, ['product_id' => $productId]);
                }
            }

            DB::table('ecommerce_product_options')->insertOrIgnore($options);
            DB::table('ecommerce_product_categories')->insertOrIgnore($categories);
            if ($images !== []) {
                DB::table('ecommerce_product_images')->insertOrIgnore($images);
            }
            $imageCount = count($images);
        });

        $state['product_offset'] = $end;
        $state['generated_product_options'] = $end;
        $state['generated_product_images'] = (int) ($state['generated_product_images'] ?? 0) + $imageCount;

        return $state;
    }

    /**
     * @param  array<int, int>  $categoryIds
     * @param  array<int, int>  $brandIds
     * @param  array<int, array<string, mixed>>  $imagePool
     * @return array{product:array<string,mixed>,option:array<string,mixed>,category_id:int,images:array<int,array<string,mixed>>}
     */
    private function buildBlueprint(
        GenerationJob $job,
        int $sequence,
        string $currency,
        array $categoryIds,
        array $brandIds,
        array $imagePool
    ): array {
        $seed = (int) $job->seed;
        $options = $job->options ?? [];
        $productCode = BenchmarkProductCode::make((int) $job->id, $sequence);
        $sku = sprintf('BM-%d-%09d', $job->id, $sequence);
        $adjectives = $this->dictionaries->get('commerce_product_adjectives');
        $nouns = $this->dictionaries->get('commerce_product_nouns');
        $sentences = $this->dictionaries->get('commerce_product_sentences');
        $adjective = (string) $this->random->pick($adjectives, $seed, $sequence, 'adjective', '실용적인');
        $noun = (string) $this->random->pick($nouns, $seed, $sequence, 'noun', '생활 상품');
        $sentence = (string) $this->random->pick($sentences, $seed, $sequence, 'sentence', '일상에서 편리하게 사용할 수 있는 벤치마크용 상품입니다.');
        $nameKo = "{$adjective} {$noun} #{$sequence}";
        $nameEn = "Benchmark product {$sequence}";
        $listPrice = $this->random->integer($seed, $sequence, 'list_price', 10, 5000) * 100;
        $discountPercent = $this->random->integer($seed, $sequence, 'discount', 0, 35);
        $sellingPrice = max(100, (int) (floor(($listPrice * (100 - $discountPercent) / 100) / 100) * 100));
        $statusRoll = $this->random->integer($seed, $sequence, 'status', 1, 100);
        $salesStatus = match (true) {
            $statusRoll <= 90 => 'on_sale',
            $statusRoll <= 95 => 'sold_out',
            $statusRoll <= 98 => 'suspended',
            default => 'coming_soon',
        };
        $stock = $salesStatus === 'sold_out' ? 0 : $this->random->integer($seed, $sequence, 'stock', 1, 1000);
        $createdAt = now()->subDays($this->random->integer($seed, $sequence, 'created_days', 0, 730));
        $categoryId = $this->pickDistributedId($categoryIds, $seed, $sequence, 'category', ($options['category_distribution'] ?? 'skewed') === 'skewed');
        $brandId = $brandIds === [] ? null : $this->pickDistributedId($brandIds, $seed, $sequence, 'brand', true);
        $description = "{$sentence}\n상품 코드 {$productCode}. 대량 조회와 검색, 장바구니 흐름을 검증하기 위한 재현 가능한 데이터입니다.";

        $product = [
            'name' => $this->json(['ko' => $nameKo, 'en' => $nameEn]),
            'product_code' => $productCode,
            'sales_product_code' => null,
            'sku' => $sku,
            'brand_id' => $brandId,
            'list_price' => number_format($listPrice, 2, '.', ''),
            'selling_price' => number_format($sellingPrice, 2, '.', ''),
            'currency_code' => $currency,
            'stock_quantity' => $stock,
            'safe_stock_quantity' => min($stock, $this->random->integer($seed, $sequence, 'safe_stock', 0, 20)),
            'sales_status' => $salesStatus,
            'display_status' => $this->random->chance($seed, $sequence, 'hidden', 0.05) ? 'hidden' : 'visible',
            'tax_status' => $taxStatus = ($this->random->chance($seed, $sequence, 'tax_free', 0.08) ? 'tax_free' : 'taxable'),
            'tax_rate' => $taxStatus === 'tax_free' ? '0.00' : '10.00',
            'shipping_policy_id' => null,
            'common_info_id' => null,
            'min_purchase_qty' => 1,
            'max_purchase_qty' => $this->random->chance($seed, $sequence, 'max_purchase', 0.15) ? $this->random->integer($seed, $sequence, 'max_purchase_value', 2, 20) : 0,
            'purchase_restriction' => 'none',
            'allowed_roles' => null,
            'description' => $this->json(['ko' => $description, 'en' => "Benchmark product {$sequence} for ecommerce load testing."]),
            'description_mode' => 'text',
            'meta_title' => $this->json(['ko' => $nameKo, 'en' => $nameEn]),
            'seo_sync_title' => true,
            'meta_description' => $this->json(['ko' => $sentence, 'en' => "Benchmark commerce product {$sequence}."]),
            'seo_sync_description' => true,
            'meta_keywords' => $this->json(['benchmark', 'dummy', $noun]),
            'barcode' => null,
            'hs_code' => null,
            'has_options' => false,
            'option_groups' => $this->json([]),
            'created_by' => $job->requested_by,
            'updated_by' => $job->requested_by,
            'created_at' => $createdAt,
            'updated_at' => $createdAt,
            'deleted_at' => null,
        ];

        return [
            'product' => $product,
            'option' => [
                'option_code' => 'default',
                'option_values' => $this->json([]),
                'option_name' => $this->json(['ko' => '기본', 'en' => 'Default']),
                'price_adjustment' => '0.00',
                'list_price' => $product['list_price'],
                'selling_price' => $product['selling_price'],
                'currency_code' => $currency,
                'stock_quantity' => $stock,
                'safe_stock_quantity' => $product['safe_stock_quantity'],
                'weight' => null,
                'volume' => null,
                'mileage_value' => null,
                'mileage_type' => null,
                'is_default' => true,
                'is_active' => true,
                'sku' => $sku,
                'sort_order' => 0,
                'created_at' => $createdAt,
                'updated_at' => $createdAt,
            ],
            'category_id' => $categoryId,
            'images' => $this->buildImages($job, $sequence, $nameKo, $imagePool, $createdAt),
        ];
    }

    /**
     * @param  array<int, array<string, mixed>>  $imagePool
     * @return array<int, array<string, mixed>>
     */
    private function buildImages(GenerationJob $job, int $sequence, string $name, array $imagePool, mixed $createdAt): array
    {
        $options = $job->options ?? [];
        $coverage = (float) ($options['image_coverage'] ?? 1);
        if ($imagePool === [] || ! $this->random->chance((int) $job->seed, $sequence, 'has_image', $coverage)) {
            return [];
        }

        $count = $this->random->integer((int) $job->seed, $sequence, 'image_count', 1, (int) ($options['max_images_per_product'] ?? 1));
        $rows = [];

        for ($slot = 0; $slot < $count; $slot++) {
            $poolIndex = $this->random->integer((int) $job->seed, $sequence, "image_pool:{$slot}", 0, count($imagePool) - 1);
            $poolImage = $imagePool[$poolIndex];
            $hash = $this->imageHash((int) $job->id, $sequence, $slot);
            $rows[] = [
                'temp_key' => null,
                'hash' => $hash,
                'original_filename' => $poolImage['filename'],
                'stored_filename' => $poolImage['filename'],
                'disk' => $poolImage['disk'],
                'path' => $poolImage['path'],
                'mime_type' => $poolImage['mime_type'],
                'file_size' => (int) $poolImage['file_size'],
                'width' => (int) $poolImage['width'],
                'height' => (int) $poolImage['height'],
                'alt_text' => $this->json(['ko' => $name, 'en' => "Benchmark product {$sequence}"]),
                'collection' => $slot === 0 ? 'main' : 'additional',
                'is_thumbnail' => $slot === 0,
                'sort_order' => $slot,
                'created_by' => $job->requested_by,
                'created_at' => $createdAt,
                'updated_at' => $createdAt,
                'deleted_at' => null,
            ];
        }

        return $rows;
    }

    /**
     * @param  array<string, mixed>  $state
     * @return array<int, int>
     */
    private function resolveCategoryIds(array $state): array
    {
        $categoryStates = array_values(array_filter(
            $state['category_states'] ?? [],
            fn ($category) => is_array($category) && ! empty($category['id'])
        ));
        $leaves = array_values(array_filter($categoryStates, fn (array $category) => (bool) ($category['is_leaf'] ?? false)));
        $source = $leaves !== [] ? $leaves : $categoryStates;
        $ids = array_values(array_map(fn (array $category) => (int) $category['id'], $source));

        if ($ids === []) {
            throw new \RuntimeException('상품에 연결할 벤치마크 분류가 없습니다.');
        }

        return $ids;
    }

    /**
     * @param  array<int, int>  $ids
     */
    private function pickDistributedId(array $ids, int $seed, int $sequence, string $key, bool $skewed): int
    {
        $maxIndex = count($ids) - 1;
        if ($skewed && count($ids) > 5 && $this->random->chance($seed, $sequence, "{$key}:heavy", 0.70)) {
            $maxIndex = max(0, (int) ceil(count($ids) * 0.10) - 1);
        }

        return $ids[$this->random->integer($seed, $sequence, $key, 0, $maxIndex)];
    }

    private function imageHash(int $jobId, int $sequence, int $slot): string
    {
        $jobPart = base_convert((string) $jobId, 10, 36);
        $sequencePart = base_convert((string) $sequence, 10, 36);
        if (strlen($jobPart) > 4 || strlen($sequencePart) > 6 || $slot > 35) {
            throw new \RuntimeException('상품 이미지 해시 범위를 초과했습니다.');
        }

        return 'b'.str_pad($jobPart, 4, '0', STR_PAD_LEFT).str_pad($sequencePart, 6, '0', STR_PAD_LEFT).base_convert((string) $slot, 10, 36);
    }

    private function json(array $value): string
    {
        return (string) json_encode($value, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_THROW_ON_ERROR);
    }
}
