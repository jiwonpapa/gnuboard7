<?php

namespace Plugins\G7\PowerCache\Tests\Unit;

use App\Contracts\Extension\ExtensionMiddlewareRegistryInterface;
use App\Extension\HookManager;
use PHPUnit\Framework\Attributes\DataProvider;
use Plugins\G7\PowerCache\Eligibility\GuestEligibility;
use Plugins\G7\PowerCache\Http\Middleware\GuestResponseCache;
use Plugins\G7\PowerCache\Policy\RoutePolicy;
use Plugins\G7\PowerCache\Tests\Support\PowerCacheTestCase;

final class GuestEligibilityTest extends PowerCacheTestCase
{
    private RoutePolicy $policy;

    protected function setUp(): void
    {
        parent::setUp();
        $this->policy = new RoutePolicy(
            'page-public-show-v1',
            'api.modules.sirsoft-page.pages.show',
            ['site', 'page:all'],
            [],
            ['api', 'optional.sanctum', 'throttle:600,1'],
        );
    }

    public function test_clean_guest_request_is_eligible(): void
    {
        $registry = new class implements ExtensionMiddlewareRegistryInterface
        {
            public function resolveForRoute(string $routeName, string $path, string $group, string $timing): array
            {
                return $timing === 'after_core' ? [GuestResponseCache::class] : [];
            }
        };
        $result = (new GuestEligibility($registry))->evaluate($this->request(), $this->policy);

        self::assertTrue($result->eligible);
    }

    public function test_registered_origin_response_filter_forces_bypass(): void
    {
        $filterHook = 'sirsoft-ecommerce.category.filter_public_list_result';
        $policy = new RoutePolicy(
            'ecommerce-public-category-v1',
            'api.modules.sirsoft-ecommerce.categories.index',
            ['site', 'category:tree'],
            [],
            ['api'],
            [$filterHook],
        );
        $registry = new class implements ExtensionMiddlewareRegistryInterface
        {
            public function resolveForRoute(string $routeName, string $path, string $group, string $timing): array
            {
                return $timing === 'after_core' ? [GuestResponseCache::class] : [];
            }
        };
        HookManager::addFilter($filterHook, static fn (mixed $value): mixed => $value);

        try {
            $result = (new GuestEligibility($registry))->evaluate(
                $this->request(
                    routeName: 'api.modules.sirsoft-ecommerce.categories.index',
                    middleware: ['api'],
                    uri: '/api/modules/sirsoft-ecommerce/categories',
                ),
                $policy,
            );
        } finally {
            HookManager::clearFilter($filterHook);
        }

        self::assertFalse($result->eligible);
        self::assertSame('origin_filter', $result->reason);
    }

    #[DataProvider('unsafeRequestProvider')]
    public function test_personalized_or_unknown_inputs_bypass(string $kind, string $expected): void
    {
        $request = match ($kind) {
            'authorization' => $this->request(headers: ['Authorization' => 'Bearer expired']),
            'cookie' => $this->request(cookies: ['laravel_session' => 'x']),
            'query' => $this->request(query: ['preview' => '1']),
            'middleware' => $this->request(middleware: ['api', 'permission:user,anything']),
            'extension_middleware' => $this->request(),
        };

        $eligibility = $kind === 'extension_middleware'
            ? new GuestEligibility(new class implements ExtensionMiddlewareRegistryInterface
            {
                public function resolveForRoute(string $routeName, string $path, string $group, string $timing): array
                {
                    return $timing === 'after_core'
                        ? [GuestResponseCache::class, 'Plugins\\Vendor\\Personalizer']
                        : [];
                }
            })
            : new GuestEligibility;
        $result = $eligibility->evaluate($request, $this->policy);

        self::assertFalse($result->eligible);
        self::assertSame($expected, $result->reason);
    }

    public static function unsafeRequestProvider(): array
    {
        return [
            ['authorization', 'sensitive_header'],
            ['cookie', 'cookie'],
            ['query', 'unknown_query'],
            ['middleware', 'unknown_route_middleware'],
            ['extension_middleware', 'unknown_extension_middleware'],
        ];
    }
}
