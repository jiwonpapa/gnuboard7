<?php

namespace Plugins\G7\PowerCache\Policy;

use Illuminate\Http\Request;
use Plugins\G7\PowerCache\Runtime\PowerCacheSettings;

final class RoutePolicyRegistry
{
    public function __construct(private readonly PowerCacheSettings $settings) {}

    public function resolve(Request $request): ?RoutePolicy
    {
        $routeName = $request->route()?->getName();

        return match ($routeName) {
            'api.modules.sirsoft-page.pages.show' => $this->settings->publicPagesEnabled()
                ? new RoutePolicy(
                    'page-public-show-v1',
                    $routeName,
                    ['site', 'page:all'],
                    [],
                    ['api', 'optional.sanctum', 'throttle:600,1'],
                )
                : null,
            'api.modules.sirsoft-ecommerce.categories.index',
            'api.modules.sirsoft-ecommerce.categories.show' => $this->settings->publicCategoriesEnabled()
                ? new RoutePolicy(
                    'ecommerce-public-category-v1',
                    $routeName,
                    ['site', 'category:tree'],
                    [],
                    ['api'],
                    [$routeName === 'api.modules.sirsoft-ecommerce.categories.index'
                        ? 'sirsoft-ecommerce.category.filter_public_list_result'
                        : 'sirsoft-ecommerce.category.filter_public_show_result'],
                )
                : null,
            default => null,
        };
    }

    /** @return array<int, string> */
    public function routeNames(): array
    {
        return [
            'api.modules.sirsoft-page.pages.show',
            'api.modules.sirsoft-ecommerce.categories.index',
            'api.modules.sirsoft-ecommerce.categories.show',
        ];
    }

    /** @return array<int, string> */
    public function expectedMiddleware(string $routeName): array
    {
        return match ($routeName) {
            'api.modules.sirsoft-page.pages.show' => ['api', 'optional.sanctum', 'throttle:600,1'],
            'api.modules.sirsoft-ecommerce.categories.index',
            'api.modules.sirsoft-ecommerce.categories.show' => ['api'],
            default => [],
        };
    }
}
