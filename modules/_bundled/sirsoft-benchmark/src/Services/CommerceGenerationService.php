<?php

namespace Modules\Sirsoft\Benchmark\Services;

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Enums\GenerationJobStatus;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Generators\CommerceBrandGenerator;
use Modules\Sirsoft\Benchmark\Services\Generators\CommerceCategoryGenerator;
use Modules\Sirsoft\Benchmark\Services\Generators\CommerceProductGenerator;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;
use Modules\Sirsoft\Benchmark\Services\Support\ProgressReporter;

class CommerceGenerationService
{
    public function __construct(
        private CommerceImagePoolService $imagePoolService,
        private CommerceCategoryGenerator $categoryGenerator,
        private CommerceBrandGenerator $brandGenerator,
        private CommerceProductGenerator $productGenerator,
        private ProgressReporter $progressReporter,
        private GenerationJobLogger $logger
    ) {}

    public function processNextChunk(GenerationJob $job): bool
    {
        return match ($job->current_stage) {
            GenerationStage::ImagePool => $this->processImagePool($job),
            GenerationStage::Categories => $this->processCategories($job),
            GenerationStage::Brands => $this->processBrands($job),
            GenerationStage::Products => $this->processProducts($job),
            GenerationStage::Verifying => $this->processVerification($job),
            GenerationStage::Completed => false,
            default => throw new \RuntimeException("쇼핑몰 작업 단계가 올바르지 않습니다: {$job->current_stage->value}"),
        };
    }

    private function processImagePool(GenerationJob $job): bool
    {
        $state = $this->imagePoolService->generateChunk($job, $job->runtime_state ?? []);
        $generated = count($state['image_pool'] ?? []);
        $total = (int) ($job->options['image_pool_size'] ?? 100);
        $nextStage = $generated >= $total ? GenerationStage::Categories : GenerationStage::ImagePool;
        $job = $this->progressReporter->heartbeat($job, [
            'runtime_state' => $state,
            'current_stage' => $nextStage,
        ], "상품 이미지 풀 생성 {$generated}/{$total}");
        $this->logger->info($job, '상품 이미지 풀 청크가 처리되었습니다.', GenerationStage::ImagePool->value, [
            'generated_pool_images' => $generated,
            'total_pool_images' => $total,
        ]);

        return true;
    }

    private function processCategories(GenerationJob $job): bool
    {
        $state = $this->categoryGenerator->generateChunk($job, $job->runtime_state ?? []);
        $generated = (int) ($state['category_index'] ?? 0);
        $nextStage = $generated >= (int) $job->total_categories ? GenerationStage::Brands : GenerationStage::Categories;
        $job = $this->progressReporter->heartbeat($job, [
            'runtime_state' => $state,
            'generated_categories' => $generated,
            'current_stage' => $nextStage,
        ], "상품 분류 생성 {$generated}/{$job->total_categories}");
        $this->logger->info($job, '상품 분류 청크가 처리되었습니다.', GenerationStage::Categories->value, [
            'generated_categories' => $generated,
        ]);

        return true;
    }

    private function processBrands(GenerationJob $job): bool
    {
        $state = $this->brandGenerator->generateChunk($job, $job->runtime_state ?? []);
        $generated = (int) ($state['brand_index'] ?? 0);
        $nextStage = $generated >= (int) $job->total_brands ? GenerationStage::Products : GenerationStage::Brands;
        $job = $this->progressReporter->heartbeat($job, [
            'runtime_state' => $state,
            'generated_brands' => $generated,
            'current_stage' => $nextStage,
        ], "브랜드 생성 {$generated}/{$job->total_brands}");
        $this->logger->info($job, '브랜드 청크가 처리되었습니다.', GenerationStage::Brands->value, [
            'generated_brands' => $generated,
        ]);

        return true;
    }

    private function processProducts(GenerationJob $job): bool
    {
        $chunkStart = (int) $job->generated_products;
        $chunkSize = (int) ($job->options['chunk_size'] ?? 5000);

        while ((int) $job->generated_products < (int) $job->total_products
            && (int) $job->generated_products - $chunkStart < $chunkSize) {
            $job = $job->fresh();
            if ($job->status === GenerationJobStatus::Stopping) {
                $job = $this->progressReporter->markStopped($job, '상품 배치 사이에서 중단 요청을 반영했습니다.');
                $this->logger->warning($job, '쇼핑몰 상품 생성 작업이 중단되었습니다.', GenerationStage::Products->value);

                return false;
            }

            $before = (int) $job->generated_products;
            $remainingChunk = $chunkSize - ($before - $chunkStart);
            $state = $this->productGenerator->generateBatch($job, $job->runtime_state ?? [], $remainingChunk);
            $generated = (int) ($state['product_offset'] ?? 0);
            $nextStage = $generated >= (int) $job->total_products ? GenerationStage::Verifying : GenerationStage::Products;
            $job = $this->progressReporter->heartbeat($job, [
                'runtime_state' => $state,
                'generated_products' => $generated,
                'generated_product_options' => (int) ($state['generated_product_options'] ?? $generated),
                'generated_product_images' => (int) ($state['generated_product_images'] ?? 0),
                'current_stage' => $nextStage,
            ], "상품 생성 {$generated}/{$job->total_products}");
            $this->logger->info($job, '상품 배치가 처리되었습니다.', GenerationStage::Products->value, [
                'batch_products' => $generated - $before,
                'generated_products' => $generated,
                'generated_product_images' => (int) $job->generated_product_images,
            ]);
        }

        return true;
    }

    private function processVerification(GenerationJob $job): bool
    {
        $prefix = "BMJ{$job->id}-%";
        $categoryPrefix = "bmj-{$job->id}-category-%";
        $brandPrefix = "bmj-{$job->id}-brand-%";
        $products = (int) DB::table('ecommerce_products')->where('product_code', 'like', $prefix)->count();
        $options = (int) DB::table('ecommerce_product_options as options')
            ->join('ecommerce_products as products', 'products.id', '=', 'options.product_id')
            ->where('products.product_code', 'like', $prefix)
            ->count();
        $categories = (int) DB::table('ecommerce_categories')->where('slug', 'like', $categoryPrefix)->count();
        $brands = (int) DB::table('ecommerce_brands')->where('slug', 'like', $brandPrefix)->count();
        $images = (int) DB::table('ecommerce_product_images as images')
            ->join('ecommerce_products as products', 'products.id', '=', 'images.product_id')
            ->where('products.product_code', 'like', $prefix)
            ->count();
        $categoryAssignments = (int) DB::table('ecommerce_product_categories as assignments')
            ->join('ecommerce_products as products', 'products.id', '=', 'assignments.product_id')
            ->where('products.product_code', 'like', $prefix)
            ->count();
        $state = $job->runtime_state ?? [];
        $missingFiles = array_values(array_filter(
            $state['image_pool'] ?? [],
            fn (array $image) => ! $this->imagePoolService->storage()->exists('images', (string) $image['path'])
        ));
        $passed = $products === (int) $job->total_products
            && $options === $products
            && $categoryAssignments === $products
            && $categories === (int) $job->total_categories
            && $brands === (int) $job->total_brands
            && $missingFiles === [];
        $state['verification'] = [
            'status' => $passed ? 'passed' : 'warning',
            'products' => $products,
            'product_options' => $options,
            'product_images' => $images,
            'product_categories' => $categoryAssignments,
            'categories' => $categories,
            'brands' => $brands,
            'missing_pool_files' => count($missingFiles),
        ];
        $job = $this->progressReporter->heartbeat($job, [
            'runtime_state' => $state,
            'generated_products' => $products,
            'generated_product_options' => $options,
            'generated_product_images' => $images,
            'generated_categories' => $categories,
            'generated_brands' => $brands,
            'current_stage' => GenerationStage::Verifying,
        ], '쇼핑몰 데이터셋 검증 완료');
        $message = $passed
            ? '쇼핑몰 더미데이터 생성과 검증이 완료되었습니다.'
            : '쇼핑몰 더미데이터 생성은 완료되었지만 검증 경고가 있습니다.';
        $job = $this->progressReporter->markCompleted($job, $message);
        $this->logger->info($job, $message, GenerationStage::Completed->value, [
            'verification' => $state['verification'],
        ]);

        return false;
    }
}
