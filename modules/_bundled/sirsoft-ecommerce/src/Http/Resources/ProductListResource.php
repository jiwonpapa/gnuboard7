<?php

namespace Modules\Sirsoft\Ecommerce\Http\Resources;

use App\Helpers\PermissionHelper;
use App\Http\Resources\BaseApiResource;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Http\Request;
use Illuminate\Http\Resources\Json\JsonResource;
use Modules\Sirsoft\Ecommerce\Http\Resources\Traits\HasMultiCurrencyPrices;

/**
 * 상품 목록 리소스
 */
class ProductListResource extends BaseApiResource
{
    use HasMultiCurrencyPrices;

    /**
     * 리소스를 배열로 변환
     *
     * @param  Request  $request  요청
     * @return array 상품 목록 리소스 배열 (다중 통화 가격 포함)
     */
    public function toArray(Request $request): array
    {
        $listPrice = $this->resolvePriceFields($this->list_price, $request);
        $sellingPrice = $this->resolvePriceFields($this->selling_price, $request);

        return [
            'id' => $this->id,
            'name' => $this->name,
            'name_localized' => $this->getLocalizedName(),
            'product_code' => $this->product_code,
            'sku' => $this->sku,
            'thumbnail_url' => $this->getThumbnailUrl(),

            // 가격
            'list_price' => $listPrice['raw'],
            'list_price_formatted' => $listPrice['formatted'],
            'selling_price' => $sellingPrice['raw'],
            'selling_price_formatted' => $sellingPrice['formatted'],
            'discount_rate' => $this->getDiscountRate(),

            // 다중 통화 가격
            'multi_currency_list_price' => $listPrice['multi_currency'],
            'multi_currency_selling_price' => $sellingPrice['multi_currency'],

            // 재고
            'stock_quantity' => $this->stock_quantity,
            'safe_stock_quantity' => $this->safe_stock_quantity,
            'is_below_safe_stock' => $this->isBelowSafeStock(),
            'option_stock_sum' => $this->relationLoaded('options')
                ? $this->options->where('is_active', true)->sum('stock_quantity')
                : $this->whenLoaded('activeOptions', fn () => $this->activeOptions->sum('stock_quantity')),

            // 상태
            'sales_status' => $this->sales_status->value,
            'sales_status_label' => $this->sales_status->label(),
            'sales_status_variant' => $this->sales_status->variant(),
            'display_status' => $this->display_status->value,
            'display_status_label' => $this->display_status->label(),
            'display_status_variant' => $this->display_status->variant(),

            // 카테고리 (다대다)
            'categories' => $this->whenLoaded('categories', fn () => $this->categories->map(fn ($cat) => [
                'id' => $cat->id,
                'name' => $cat->getLocalizedName(),
                'is_primary' => $cat->pivot->is_primary,
            ])),
            'primary_category' => $this->whenLoaded('categories', fn () => $this->categories->firstWhere('pivot.is_primary', true)?->getLocalizedName()
            ),
            'categories_with_path' => $this->whenLoaded('categories', fn () => $this->categories->map(
                fn ($cat) => $this->resolveCategoryPath($cat)
            )),

            // 브랜드 (다국어)
            'brand_name' => $this->whenLoaded('brand', fn () => $this->brand?->getLocalizedName()),

            // 배송 정책
            'shipping_policy_id' => $this->shipping_policy_id,
            'shipping_policy_name' => $this->whenLoaded('shippingPolicy', fn () => $this->shippingPolicy?->getLocalizedName()),

            // 구매 수량 제한
            'min_purchase_qty' => $this->min_purchase_qty,
            'max_purchase_qty' => $this->max_purchase_qty,

            // 옵션
            'has_options' => $this->has_options,
            'options_count' => $this->relationLoaded('options')
                ? $this->options->where('is_active', true)->count()
                : $this->whenLoaded('activeOptions', fn () => $this->activeOptions->count()),
            'options' => ProductOptionResource::collection(
                $this->relationLoaded('options') ? $this->options : $this->whenLoaded('activeOptions')
            ),

            // 라벨
            'labels' => $this->whenLoaded('activeLabelAssignments', fn () => $this->activeLabelAssignments
                ->filter(fn ($a) => $a->label && $a->label->is_active)
                ->sortBy(fn ($a) => $a->label->sort_order)
                ->map(fn ($a) => [
                    'name' => $a->label->name[app()->getLocale()]
                        ?? $a->label->name[config('app.fallback_locale')]
                        ?? array_values($a->label->name ?? [])[0] ?? '',
                    'color' => $a->label->color,
                ])->values()
            ),

            // 리뷰 통계 (visibleReviews withCount/withAvg eager loading 필요)
            'review_count' => (int) ($this->review_count ?? 0),
            'rating_avg' => $this->rating_avg !== null ? round((float) $this->rating_avg, 1) : 0.0,

            // 날짜
            'created_at' => $this->formatDateTimeStringForUser($this->created_at),
            'updated_at' => $this->formatDateTimeStringForUser($this->updated_at),

            // 권한 정보 (is_owner + abilities)
            ...$this->resourceMeta($request),
        ];
    }

    /**
     * 가격 변환 결과를 같은 요청 안에서 재사용합니다.
     *
     * @return array{raw: float|int, formatted: string, multi_currency: array}
     */
    private function resolvePriceFields(float|int|null $price, Request $request): array
    {
        if (config('benchmark.ecommerce_variant') !== 'optimized') {
            return [
                'raw' => $this->roundToBaseCurrency($price),
                'formatted' => $this->formatBaseCurrency($price),
                'multi_currency' => $this->buildMultiCurrencyPrices($price ?? 0),
            ];
        }

        $cache = $request->attributes->get('g7_ecommerce_price_resource_cache', []);
        $context = $this->resolvePriceCacheContext($request);
        $cacheKey = $context['key'].':'.serialize($price ?? 0);

        if (isset($cache[$cacheKey])) {
            return $cache[$cacheKey];
        }

        $multiCurrency = $this->buildMultiCurrencyPrices($price ?? 0);
        $cache[$cacheKey] = [
            'raw' => $this->roundToCurrency($price, $context['default_currency']),
            'formatted' => $multiCurrency[$context['default_currency']]['formatted']
                ?? $this->formatCurrencyPrice($price ?? 0, $context['default_currency']),
            'multi_currency' => $multiCurrency,
        ];
        $request->attributes->set('g7_ecommerce_price_resource_cache', $cache);

        return $cache[$cacheKey];
    }

    /**
     * 요청 동안 고정되는 locale/통화 설정 식별자는 한 번만 계산합니다.
     *
     * @return array{key: string, locale: string, default_currency: string}
     */
    private function resolvePriceCacheContext(Request $request): array
    {
        $contexts = $request->attributes->get('g7_ecommerce_price_resource_contexts', []);
        $locale = app()->getLocale();
        $context = $contexts[static::class] ?? null;

        if (is_array($context) && ($context['locale'] ?? null) === $locale) {
            return $context;
        }

        $defaultCurrency = $this->getDefaultCurrencyCode();
        $context = [
            'key' => implode(':', [
                static::class,
                $locale,
                $defaultCurrency,
                hash('xxh3', serialize($this->getCurrencySettings())),
            ]),
            'locale' => $locale,
            'default_currency' => $defaultCurrency,
        ];
        $contexts[static::class] = $context;
        $request->attributes->set('g7_ecommerce_price_resource_contexts', $contexts);

        return $context;
    }

    /**
     * 동일 카테고리의 브레드크럼을 한 번만 계산합니다.
     *
     * @return array{id: int, path: array, path_string: string, is_primary: bool}
     */
    private function resolveCategoryPath($category): array
    {
        if (config('benchmark.ecommerce_variant') !== 'optimized') {
            return [
                'id' => $category->id,
                'path' => $category->getBreadcrumb(),
                'path_string' => collect($category->getBreadcrumb())->pluck('name')->implode(' > '),
                'is_primary' => $category->pivot->is_primary,
            ];
        }

        $breadcrumb = $category->getBreadcrumb();

        return [
            'id' => $category->id,
            'path' => $breadcrumb,
            'path_string' => collect($breadcrumb)->pluck('name')->implode(' > '),
            'is_primary' => $category->pivot->is_primary,
        ];
    }

    /**
     * 권한 체크 매핑을 반환합니다.
     *
     * @return array<string, string>
     */
    protected function abilityMap(): array
    {
        return [
            'can_update' => 'sirsoft-ecommerce.products.update',
            'can_delete' => 'sirsoft-ecommerce.products.delete',
        ];
    }

    /**
     * 동일 요청에서 반복되는 컬렉션/행 권한 조회를 재사용합니다.
     *
     * @param  array<string, string>  $map
     * @return array<string, bool>
     */
    public static function resolveRequestAbilityMap(array $map, Request $request): array
    {
        $cache = $request->attributes->get('g7_ecommerce_ability_cache', []);
        $user = $request->user();
        $userKey = $user ? (string) $user->id : 'guest';
        $abilities = [];

        foreach ($map as $key => $identifier) {
            $cacheKey = $userKey.':'.$identifier;

            if (! array_key_exists($cacheKey, $cache)) {
                $cache[$cacheKey] = PermissionHelper::check($identifier, $user);
            }

            $abilities[$key] = $cache[$cacheKey];
        }

        $request->attributes->set('g7_ecommerce_ability_cache', $cache);

        return $abilities;
    }

    /**
     * 행별 스코프 판정은 유지하고 권한 보유 여부만 요청 단위로 재사용합니다.
     *
     * @return array<string, bool>
     */
    protected function resolveAbilities(Request $request): array
    {
        if (config('benchmark.ecommerce_variant') !== 'optimized') {
            return parent::resolveAbilities($request);
        }

        $map = $this->abilityMap();
        $abilities = self::resolveRequestAbilityMap($map, $request);
        $resource = $this->resource;

        while ($resource instanceof JsonResource) {
            $resource = $resource->resource;
        }

        foreach ($map as $key => $identifier) {
            if ($abilities[$key] && $resource instanceof Model) {
                $abilities[$key] = PermissionHelper::checkScopeAccess($resource, $identifier, $request->user());
            }
        }

        return $abilities;
    }

    /**
     * 소유자 필드명을 반환합니다.
     */
    protected function ownerField(): ?string
    {
        return 'created_by';
    }
}
