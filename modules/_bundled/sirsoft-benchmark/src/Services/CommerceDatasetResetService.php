<?php

namespace Modules\Sirsoft\Benchmark\Services;

use Illuminate\Support\Facades\DB;
use Modules\Sirsoft\Benchmark\Enums\GenerationStage;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;
use Modules\Sirsoft\Benchmark\Services\Support\GenerationJobLogger;
use Modules\Sirsoft\Benchmark\Services\Support\ProgressReporter;

class CommerceDatasetResetService
{
    public function __construct(
        private CommerceImagePoolService $imagePoolService,
        private ProgressReporter $progressReporter,
        private GenerationJobLogger $logger
    ) {}

    public function processNextChunk(GenerationJob $job): bool
    {
        $state = $job->runtime_state ?? [];
        $phase = (string) ($state['reset_phase'] ?? 'preflight');

        return match ($phase) {
            'preflight' => $this->preflight($job, $state),
            'products' => $this->deleteProducts($job, $state),
            'categories' => $this->deleteCategories($job, $state),
            'brands' => $this->deleteBrands($job, $state),
            'files' => $this->deleteFiles($job, $state),
            'completed' => false,
            default => throw new \RuntimeException("알 수 없는 쇼핑몰 초기화 단계입니다: {$phase}"),
        };
    }

    private function preflight(GenerationJob $job, array $state): bool
    {
        $orderCount = DB::table('ecommerce_order_options as order_options')
            ->join('ecommerce_products as products', 'products.id', '=', 'order_options.product_id')
            ->where('products.product_code', 'like', $this->productPrefix($job))
            ->count();
        if ($orderCount > 0) {
            throw new \RuntimeException("주문에서 참조 중인 벤치마크 상품 {$orderCount}건이 있어 초기화를 거부했습니다.");
        }

        $state['reset_phase'] = 'products';
        $this->heartbeat($job, $state, '쇼핑몰 데이터셋 초기화 사전검증 완료');

        return true;
    }

    private function deleteProducts(GenerationJob $job, array $state): bool
    {
        $ids = DB::table('ecommerce_products')
            ->where('product_code', 'like', $this->productPrefix($job))
            ->orderBy('id')
            ->limit(1000)
            ->pluck('id')
            ->map(fn ($id) => (int) $id)
            ->all();

        if ($ids === []) {
            $state['reset_phase'] = 'categories';
            $this->heartbeat($job, $state, '상품 삭제 완료, 분류 초기화 대기 중');

            return true;
        }

        $deleted = DB::transaction(fn () => DB::table('ecommerce_products')->whereIn('id', $ids)->delete());
        $state['cleanup']['deleted_products'] = (int) ($state['cleanup']['deleted_products'] ?? 0) + $deleted;
        $this->heartbeat($job, $state, "상품 초기화 {$state['cleanup']['deleted_products']}건");

        return true;
    }

    private function deleteCategories(GenerationJob $job, array $state): bool
    {
        $ids = DB::table('ecommerce_categories')
            ->where('slug', 'like', "bmj-{$job->id}-category-%")
            ->orderByDesc('depth')
            ->orderByDesc('id')
            ->limit(100)
            ->pluck('id')
            ->map(fn ($id) => (int) $id)
            ->all();

        if ($ids === []) {
            $state['reset_phase'] = 'brands';
            $this->heartbeat($job, $state, '상품 분류 삭제 완료, 브랜드 초기화 대기 중');

            return true;
        }

        DB::table('ecommerce_categories')->whereIn('id', $ids)->delete();
        // MySQL affected rows excludes descendants removed by the parent FK cascade.
        $deleted = count($ids);
        $state['cleanup']['deleted_categories'] = (int) ($state['cleanup']['deleted_categories'] ?? 0) + $deleted;
        $this->heartbeat($job, $state, "상품 분류 초기화 {$state['cleanup']['deleted_categories']}건");

        return true;
    }

    private function deleteBrands(GenerationJob $job, array $state): bool
    {
        $deleted = DB::table('ecommerce_brands')
            ->where('slug', 'like', "bmj-{$job->id}-brand-%")
            ->delete();
        $state['cleanup']['deleted_brands'] = (int) ($state['cleanup']['deleted_brands'] ?? 0) + $deleted;
        $state['reset_phase'] = 'files';
        $this->heartbeat($job, $state, '브랜드 삭제 완료, 이미지 파일 초기화 대기 중');

        return true;
    }

    private function deleteFiles(GenerationJob $job, array $state): bool
    {
        $deleted = $this->imagePoolService->storage()->deleteDirectory('images', "benchmark/job-{$job->id}");
        $state['cleanup']['deleted_files'] = $deleted;
        $state['reset_phase'] = 'completed';
        $job = $this->heartbeat($job, $state, '쇼핑몰 데이터셋 초기화 완료');
        $job = $this->progressReporter->markCompleted($job, '쇼핑몰 데이터셋 초기화가 완료되었습니다.');
        $this->logger->warning($job, '쇼핑몰 데이터셋 초기화가 완료되었습니다.', GenerationStage::Resetting->value, $state['cleanup']);

        return false;
    }

    private function heartbeat(GenerationJob $job, array $state, string $message): GenerationJob
    {
        $job = $this->progressReporter->heartbeat($job->fresh(), [
            'runtime_state' => $state,
            'current_stage' => GenerationStage::Resetting,
        ], $message);
        $this->logger->warning($job, $message, GenerationStage::Resetting->value, $state['cleanup'] ?? []);

        return $job;
    }

    private function productPrefix(GenerationJob $job): string
    {
        return "BMJ{$job->id}-%";
    }
}
