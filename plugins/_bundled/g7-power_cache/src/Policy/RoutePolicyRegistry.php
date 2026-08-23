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
            'api.modules.sirsoft-board.boards.posts.index' => $this->settings->publicBoardListsEnabled()
                ? new RoutePolicy(
                    'board-public-hot-list-v1',
                    $routeName,
                    ['site', 'board:all'],
                    ['page', 'per_page'],
                    [
                        'api',
                        'optional.sanctum',
                        'throttle:600,1',
                        'permission:user,sirsoft-board.{slug}.posts.read',
                    ],
                    originFilterHooks: [],
                    guestPermission: 'sirsoft-board.{slug}.posts.read',
                    varyByDeviceClass: true,
                    clockBucketSeconds: 60,
                    maxPage: 3,
                    maxPerPage: 50,
                    retentionSeconds: 600,
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
            'api.modules.sirsoft-board.boards.posts.index',
        ];
    }

    /** @return array<int, string> */
    public function expectedMiddleware(string $routeName): array
    {
        return match ($routeName) {
            'api.modules.sirsoft-page.pages.show' => ['api', 'optional.sanctum', 'throttle:600,1'],
            'api.modules.sirsoft-ecommerce.categories.index',
            'api.modules.sirsoft-ecommerce.categories.show' => ['api'],
            'api.modules.sirsoft-board.boards.posts.index' => [
                'api',
                'optional.sanctum',
                'throttle:600,1',
                'permission:user,sirsoft-board.{slug}.posts.read',
            ],
            default => [],
        };
    }
}
