<?php

namespace Modules\Sirsoft\Ecommerce\Tests\Unit\Http\Resources;

use App\Models\User;
use Illuminate\Http\Request;
use Modules\Sirsoft\Ecommerce\Http\Resources\ProductCollection;
use Modules\Sirsoft\Ecommerce\Models\Product;
use Tests\TestCase;

class ProductCollectionRequestContextTest extends TestCase
{
    public function test_to_array_uses_the_supplied_request_for_rows_and_sort_order(): void
    {
        config()->set('benchmark.ecommerce_variant', 'optimized');

        $user = new User;
        $user->forceFill(['id' => 42]);
        $user->exists = true;

        $globalRequest = Request::create('/global', 'GET', ['sort_order' => 'desc']);
        $globalRequest->setUserResolver(fn () => null);
        $this->app->instance('request', $globalRequest);

        $request = Request::create('/products', 'GET', ['sort_order' => 'asc']);
        $request->setUserResolver(fn () => $user);
        $request->attributes->set('g7_ecommerce_ability_cache', [
            '42:sirsoft-ecommerce.products.create' => false,
            '42:sirsoft-ecommerce.products.update' => false,
            '42:sirsoft-ecommerce.products.delete' => false,
        ]);

        $products = collect([
            Product::factory()->make(['created_by' => 42]),
            Product::factory()->make(['created_by' => null]),
        ])->each(fn (Product $product) => $product->setRelation('images', collect()));

        $result = (new ProductCollection($products))->toArray($request);
        $rows = $result['data']->values();

        $this->assertSame(1, $rows[0]['number']);
        $this->assertSame(2, $rows[1]['number']);
        $this->assertTrue($rows[0]['is_owner']);
        $this->assertFalse($rows[1]['is_owner']);
    }
}
