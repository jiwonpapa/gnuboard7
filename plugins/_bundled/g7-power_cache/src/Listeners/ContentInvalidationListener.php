<?php

namespace Plugins\G7\PowerCache\Listeners;

use App\Contracts\Extension\HookListenerInterface;
use Plugins\G7\PowerCache\Invalidation\InvalidationCoordinator;

final class ContentInvalidationListener implements HookListenerInterface
{
    public function __construct(private readonly InvalidationCoordinator $coordinator) {}

    public static function getSubscribedHooks(): array
    {
        $hooks = [];

        foreach ([
            'sirsoft-page.page.after_create',
            'sirsoft-page.page.after_update',
            'sirsoft-page.page.after_delete',
            'sirsoft-page.page.after_publish',
            'sirsoft-page.page.after_restore',
            'sirsoft-page.attachment.after_upload',
            'sirsoft-page.attachment.after_delete',
            'sirsoft-page.attachment.after_reorder',
        ] as $hook) {
            $hooks[$hook] = ['method' => 'handlePageMutation', 'type' => 'action', 'sync' => true];
        }

        foreach ([
            'sirsoft-ecommerce.category.after_create',
            'sirsoft-ecommerce.category.after_update',
            'sirsoft-ecommerce.category.after_delete',
            'sirsoft-ecommerce.category.after_toggle_status',
            'sirsoft-ecommerce.category.after_reorder',
            'sirsoft-ecommerce.category-image.after_upload',
            'sirsoft-ecommerce.category-image.after_delete',
            'sirsoft-ecommerce.category-image.after_reorder',
            'sirsoft-ecommerce.category-image.after_update',
        ] as $hook) {
            $hooks[$hook] = ['method' => 'handleCategoryMutation', 'type' => 'action', 'sync' => true];
        }

        foreach ([
            'sirsoft-ecommerce.product.after_create',
            'sirsoft-ecommerce.product.after_update',
            'sirsoft-ecommerce.product.after_delete',
            'sirsoft-ecommerce.product.after_bulk_update',
            'sirsoft-ecommerce.product.after_bulk_price_update',
            'sirsoft-ecommerce.product.after_bulk_stock_update',
            'sirsoft-ecommerce.product.after_stock_sync',
        ] as $hook) {
            $hooks[$hook] = ['method' => 'handleProductMutation', 'type' => 'action', 'sync' => true];
        }

        return $hooks;
    }

    public function handle(...$args): void
    {
        $this->coordinator->invalidate(['site'], 'unknown-content-mutation');
    }

    public function handlePageMutation(...$args): void
    {
        $this->coordinator->invalidate(['page:all'], 'page-mutation');
    }

    public function handleCategoryMutation(...$args): void
    {
        $this->coordinator->invalidate(['category:tree'], 'category-mutation');
    }

    public function handleProductMutation(...$args): void
    {
        // 카테고리 트리는 공개 상품 수를 포함하므로 상품 변경도 트리 세대를 회전합니다.
        $this->coordinator->invalidate(['category:tree'], 'product-category-count-mutation');
    }
}
