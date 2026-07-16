<?php

namespace Modules\Sirsoft\Ecommerce\Tests\Unit\Http\Resources;

use Illuminate\Http\Request;
use Modules\Sirsoft\Ecommerce\Http\Resources\ProductListResource;
use Modules\Sirsoft\Ecommerce\Models\Category;
use ReflectionMethod;
use Tests\TestCase;

class ProductListResourcePerformanceTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();
        config()->set('benchmark.ecommerce_variant', 'optimized');
        app()->setLocale('ko');
        CountingProductListResource::$exchangeRate = 0.001;
    }

    public function test_price_conversion_is_reused_only_with_matching_request_context(): void
    {
        $request = Request::create('/storefront');
        $first = new CountingProductListResource(new \stdClass);
        $second = new CountingProductListResource(new \stdClass);

        $firstResult = $this->resolvePrice($first, 12000, $request);
        $secondResult = $this->resolvePrice($second, 12000, $request);

        $this->assertSame($firstResult, $secondResult);
        $this->assertSame(1, $first->buildCount);
        $this->assertSame(0, $second->buildCount);
        $this->assertSame(0, $second->settingsReadCount);
        $this->assertArrayHasKey('g7_ecommerce_price_resource_cache', $request->attributes->all());
    }

    public function test_optimized_price_fields_are_identical_to_baseline(): void
    {
        config()->set('benchmark.ecommerce_variant', 'baseline');
        $baseline = $this->resolvePrice(
            new CountingProductListResource(new \stdClass),
            12345.67,
            Request::create('/storefront')
        );

        config()->set('benchmark.ecommerce_variant', 'optimized');
        $optimized = $this->resolvePrice(
            new CountingProductListResource(new \stdClass),
            12345.67,
            Request::create('/storefront')
        );

        $this->assertSame($baseline, $optimized);
        $this->assertSame(
            json_encode($baseline, JSON_UNESCAPED_UNICODE),
            json_encode($optimized, JSON_UNESCAPED_UNICODE)
        );
    }

    public function test_price_conversion_does_not_leak_between_requests(): void
    {
        $first = new CountingProductListResource(new \stdClass);
        $second = new CountingProductListResource(new \stdClass);

        $this->resolvePrice($first, 12000, Request::create('/storefront'));
        $this->resolvePrice($second, 12000, Request::create('/storefront'));

        $this->assertSame(1, $first->buildCount);
        $this->assertSame(1, $second->buildCount);
    }

    public function test_locale_and_currency_settings_are_part_of_request_cache_key(): void
    {
        $koreanRequest = Request::create('/storefront');
        $korean = new CountingProductListResource(new \stdClass);
        $english = new CountingProductListResource(new \stdClass);
        $changedSettings = new CountingProductListResource(new \stdClass);

        $this->resolvePrice($korean, 12000, $koreanRequest);
        $koreanContext = $koreanRequest->attributes->get('g7_ecommerce_price_resource_contexts')[CountingProductListResource::class];

        app()->setLocale('en');
        $this->resolvePrice($english, 12000, $koreanRequest);
        $englishContext = $koreanRequest->attributes->get('g7_ecommerce_price_resource_contexts')[CountingProductListResource::class];

        CountingProductListResource::$exchangeRate = 0.002;
        $changedSettingsRequest = Request::create('/storefront');
        $this->resolvePrice($changedSettings, 12000, $changedSettingsRequest);
        $changedSettingsContext = $changedSettingsRequest->attributes
            ->get('g7_ecommerce_price_resource_contexts')[CountingProductListResource::class];

        $this->assertSame(1, $korean->buildCount);
        $this->assertSame(1, $english->buildCount);
        $this->assertSame(1, $changedSettings->buildCount);
        $this->assertNotSame($koreanContext['key'], $englishContext['key']);
        $this->assertNotSame($englishContext['key'], $changedSettingsContext['key']);
    }

    public function test_optimized_category_path_calculates_breadcrumb_once_with_identical_payload(): void
    {
        $baselineCategory = new CountingBreadcrumbCategory;
        $baselineCategory->forceFill(['id' => 7]);
        $baselineCategory->setRelation('pivot', (object) ['is_primary' => true]);

        config()->set('benchmark.ecommerce_variant', 'baseline');
        $baseline = $this->resolveCategoryPath(
            new ProductListResource(new \stdClass),
            $baselineCategory
        );

        $optimizedCategory = new CountingBreadcrumbCategory;
        $optimizedCategory->forceFill(['id' => 7]);
        $optimizedCategory->setRelation('pivot', (object) ['is_primary' => true]);

        config()->set('benchmark.ecommerce_variant', 'optimized');
        $optimized = $this->resolveCategoryPath(
            new ProductListResource(new \stdClass),
            $optimizedCategory
        );

        $this->assertSame($baseline, $optimized);
        $this->assertSame(2, $baselineCategory->breadcrumbCalls);
        $this->assertSame(1, $optimizedCategory->breadcrumbCalls);
    }

    /**
     * @return array{raw: float|int, formatted: string, multi_currency: array}
     */
    private function resolvePrice(ProductListResource $resource, float|int $price, Request $request): array
    {
        $method = new ReflectionMethod(ProductListResource::class, 'resolvePriceFields');

        return $method->invoke($resource, $price, $request);
    }

    /**
     * @return array{id: int, path: array, path_string: string, is_primary: bool}
     */
    private function resolveCategoryPath(ProductListResource $resource, Category $category): array
    {
        $method = new ReflectionMethod(ProductListResource::class, 'resolveCategoryPath');

        return $method->invoke($resource, $category);
    }
}

class CountingProductListResource extends ProductListResource
{
    public static float $exchangeRate = 0.001;

    public int $buildCount = 0;

    public int $settingsReadCount = 0;

    protected function getCurrencySettings(): array
    {
        $this->settingsReadCount++;

        return [
            [
                'code' => 'KRW',
                'is_default' => true,
                'decimal_places' => 0,
                'base_unit' => 1000,
                'exchange_rate' => null,
            ],
            [
                'code' => 'USD',
                'is_default' => false,
                'decimal_places' => 2,
                'base_unit' => 1,
                'exchange_rate' => self::$exchangeRate,
                'rounding_unit' => '0.01',
                'rounding_method' => 'round',
            ],
        ];
    }

    protected function buildMultiCurrencyPrices(float|int $basePrice): array
    {
        $this->buildCount++;

        return parent::buildMultiCurrencyPrices($basePrice);
    }
}

class CountingBreadcrumbCategory extends Category
{
    public int $breadcrumbCalls = 0;

    public function getBreadcrumb(): array
    {
        $this->breadcrumbCalls++;

        return [
            ['id' => 1, 'name' => '전자기기', 'slug' => 'electronics'],
            ['id' => 7, 'name' => '노트북', 'slug' => 'laptop'],
        ];
    }
}
