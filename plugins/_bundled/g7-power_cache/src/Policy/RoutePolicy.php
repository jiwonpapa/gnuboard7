<?php

namespace Plugins\G7\PowerCache\Policy;

final readonly class RoutePolicy
{
    /**
     * @param  array<int, string>  $scopes
     * @param  array<int, string>  $allowedQueryKeys
     * @param  array<int, string>  $allowedRouteMiddleware
     * @param  array<int, string>  $originFilterHooks
     */
    public function __construct(
        public string $id,
        public string $routeName,
        public array $scopes,
        public array $allowedQueryKeys,
        public array $allowedRouteMiddleware,
        public array $originFilterHooks = [],
        public ?string $guestPermission = null,
        public bool $varyByDeviceClass = false,
        public ?int $clockBucketSeconds = null,
        public ?int $maxPage = null,
        public ?int $maxPerPage = null,
        public ?int $retentionSeconds = null,
    ) {}
}
