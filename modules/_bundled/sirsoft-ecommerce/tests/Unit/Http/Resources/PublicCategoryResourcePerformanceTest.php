<?php

namespace Modules\Sirsoft\Ecommerce\Tests\Unit\Http\Resources;

use Illuminate\Database\Eloquent\Collection;
use Illuminate\Http\Request;
use Modules\Sirsoft\Ecommerce\Http\Controllers\Public\ProductController;
use Modules\Sirsoft\Ecommerce\Http\Resources\PublicCategoryResource;
use Modules\Sirsoft\Ecommerce\Models\Category;
use Modules\Sirsoft\Ecommerce\Services\CategoryService;
use Modules\Sirsoft\Ecommerce\Services\ProductService;
use Tests\TestCase;

class PublicCategoryResourcePerformanceTest extends TestCase
{
    public function test_optimized_tree_is_byte_equivalent_to_recursive_resource_collections(): void
    {
        app()->setLocale('ko');

        $leaf = $this->category(3, 2, 2, ['ko' => '노트북', 'en' => 'Laptop'], 'laptop', 7);
        $leaf->setRelation('children', new Collection);

        $child = $this->category(2, 1, 1, ['ko' => '컴퓨터', 'en' => 'Computer'], 'computer', 11);
        $child->setRelation('children', new Collection([$leaf]));

        $root = $this->category(1, null, 0, ['ko' => '전자기기', 'en' => 'Electronics'], 'electronics', 19);
        $root->setRelation('children', new Collection([$child]));

        $request = Request::create('/api/modules/sirsoft-ecommerce/storefront');
        $this->app->instance('request', $request);
        $categories = new Collection([$root]);
        $resourcePayload = PublicCategoryResource::collection($categories)->resolve($request);
        $optimizedPayload = PublicCategoryResource::resolveTree($categories);

        $this->assertSame(
            json_encode($resourcePayload, JSON_UNESCAPED_UNICODE),
            json_encode($optimizedPayload, JSON_UNESCAPED_UNICODE)
        );
        $this->assertSame([2], collect($optimizedPayload[0]['children'])->pluck('id')->all());
        $this->assertSame([3], collect($optimizedPayload[0]['children'][0]['children'])->pluck('id')->all());
    }

    public function test_optimized_tree_omits_children_when_relation_is_not_loaded(): void
    {
        $category = $this->category(1, null, 0, ['ko' => '전자기기'], 'electronics', 19);

        $payload = PublicCategoryResource::resolveTree(new Collection([$category]));

        $this->assertArrayNotHasKey('children', $payload[0]);
    }

    public function test_storefront_optimized_response_is_byte_equivalent_to_baseline(): void
    {
        $child = $this->category(2, 1, 1, ['ko' => '컴퓨터'], 'computer', 11);
        $child->setRelation('children', new Collection);
        $root = $this->category(1, null, 0, ['ko' => '전자기기'], 'electronics', 19);
        $root->setRelation('children', new Collection([$child]));
        $categories = new Collection([$root]);

        $productService = $this->createMock(ProductService::class);
        $productService->expects($this->exactly(2))->method('getProductsByIds')->with([])->willReturn(new Collection);
        $productService->expects($this->exactly(2))->method('getPopularProducts')->with(8)->willReturn(new Collection);
        $productService->expects($this->exactly(2))->method('getNewProducts')->with(8)->willReturn(new Collection);

        $categoryService = $this->createMock(CategoryService::class);
        $categoryService->expects($this->exactly(2))->method('getPublicCategoryTree')->willReturn($categories);

        $controller = new ProductController($productService, $categoryService);

        config()->set('benchmark.ecommerce_variant', 'baseline');
        $baselineRequest = Request::create('/api/modules/sirsoft-ecommerce/storefront');
        $this->app->instance('request', $baselineRequest);
        $baseline = $controller->storefront($baselineRequest)->getContent();

        config()->set('benchmark.ecommerce_variant', 'optimized');
        $optimizedRequest = Request::create('/api/modules/sirsoft-ecommerce/storefront');
        $this->app->instance('request', $optimizedRequest);
        $optimized = $controller->storefront($optimizedRequest)->getContent();

        $this->assertSame($baseline, $optimized);
    }

    /**
     * @param  array<string, string>  $name
     */
    private function category(
        int $id,
        ?int $parentId,
        int $depth,
        array $name,
        string $slug,
        int $productsCount
    ): Category {
        $category = new Category;
        $category->forceFill([
            'id' => $id,
            'parent_id' => $parentId,
            'depth' => $depth,
            'name' => $name,
            'slug' => $slug,
        ]);
        $category->setAttribute('products_count', $productsCount);

        return $category;
    }
}
