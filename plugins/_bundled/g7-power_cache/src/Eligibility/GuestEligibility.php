<?php

namespace Plugins\G7\PowerCache\Eligibility;

use App\Contracts\Extension\ExtensionMiddlewareRegistryInterface;
use App\Extension\HookManager;
use Closure;
use Illuminate\Http\Request;
use Plugins\G7\PowerCache\Http\Middleware\GuestResponseCache;
use Plugins\G7\PowerCache\Policy\RoutePolicy;

final class GuestEligibility
{
    public function __construct(
        private readonly ?ExtensionMiddlewareRegistryInterface $extensionMiddleware = null,
    ) {}

    private const SENSITIVE_HEADERS = [
        'Authorization',
        'Proxy-Authorization',
        'X-XSRF-TOKEN',
        'X-CSRF-TOKEN',
        'X-G7-Guest-Order-Token',
        'X-Guest-Order-Token',
        'X-Cart-Key',
        'X-Preview-Token',
        'X-Signature',
    ];

    public function evaluate(Request $request, RoutePolicy $policy): EligibilityResult
    {
        if (! in_array($request->getRealMethod(), ['GET', 'HEAD'], true)) {
            return EligibilityResult::bypass('method');
        }

        foreach (self::SENSITIVE_HEADERS as $header) {
            if ($request->headers->has($header)) {
                return EligibilityResult::bypass('sensitive_header');
            }
        }

        if ($request->user() !== null) {
            return EligibilityResult::bypass('authenticated_user');
        }

        if ($request->cookies->count() > 0) {
            return EligibilityResult::bypass('cookie');
        }

        $queryKeys = array_keys($request->query->all());
        $unknownQuery = array_diff($queryKeys, $policy->allowedQueryKeys);
        if ($unknownQuery !== []) {
            return EligibilityResult::bypass('unknown_query');
        }

        $registeredFilters = HookManager::getFilters();
        foreach ($policy->originFilterHooks as $filterHook) {
            if (($registeredFilters[$filterHook] ?? []) !== []) {
                return EligibilityResult::bypass('origin_filter');
            }
        }

        $middlewareResult = $this->routeMiddlewareIsSafe($request, $policy);
        if ($middlewareResult !== null) {
            return EligibilityResult::bypass($middlewareResult);
        }

        $extensionMiddlewareResult = $this->extensionMiddlewareIsSafe($request);
        if ($extensionMiddlewareResult !== null) {
            return EligibilityResult::bypass($extensionMiddlewareResult);
        }

        return EligibilityResult::allow();
    }

    private function routeMiddlewareIsSafe(Request $request, RoutePolicy $policy): ?string
    {
        $route = $request->route();
        if ($route === null) {
            return 'route_missing';
        }

        foreach ($route->gatherMiddleware() as $middleware) {
            if ($middleware instanceof Closure || ! is_string($middleware)) {
                return 'unknown_route_middleware';
            }

            if (! in_array($middleware, $policy->allowedRouteMiddleware, true)) {
                return 'unknown_route_middleware';
            }
        }

        return null;
    }

    private function extensionMiddlewareIsSafe(Request $request): ?string
    {
        if ($this->extensionMiddleware === null) {
            return 'extension_registry_unavailable';
        }

        $routeName = $request->route()?->getName() ?? '';
        $path = $request->path();
        $before = $this->extensionMiddleware->resolveForRoute($routeName, $path, 'api', 'before_core');
        $after = $this->extensionMiddleware->resolveForRoute($routeName, $path, 'api', 'after_core');

        if ($before !== [] || $after !== [GuestResponseCache::class]) {
            return 'unknown_extension_middleware';
        }

        return null;
    }
}
