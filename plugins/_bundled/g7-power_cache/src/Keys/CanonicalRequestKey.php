<?php

namespace Plugins\G7\PowerCache\Keys;

use BackedEnum;
use Illuminate\Contracts\Routing\UrlRoutable;
use Illuminate\Http\Request;
use JsonException;
use Plugins\G7\PowerCache\Policy\RoutePolicy;
use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;
use Stringable;

final class CanonicalRequestKey
{
    /**
     * @throws JsonException
     */
    public function build(
        Request $request,
        RoutePolicy $policy,
        RuntimeSnapshot $snapshot,
        string $locale,
        string $timezone,
    ): string {
        $routeParameters = [];
        foreach ($request->route()?->parameters() ?? [] as $key => $value) {
            $routeParameters[(string) $key] = $this->scalar($value);
        }
        ksort($routeParameters, SORT_STRING);

        $query = array_intersect_key($request->query->all(), array_flip($policy->allowedQueryKeys));
        $query = $this->sortRecursive($query);

        $payload = [
            'format' => (int) config('g7_power_cache.format_version', 1),
            'policy_version' => (string) config('g7_power_cache.policy_version', 'guest-api-v1'),
            'policy' => $policy->id,
            'site' => $snapshot->siteId,
            'epoch' => $snapshot->runtimeEpoch,
            'origin' => strtolower($request->getSchemeAndHttpHost()),
            'method' => 'GET',
            'route' => $policy->routeName,
            'route_parameters' => $routeParameters,
            'query' => $query,
            'locale' => $locale,
            'timezone' => $timezone,
        ];

        return hash('sha256', json_encode(
            $payload,
            JSON_THROW_ON_ERROR | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES,
        ));
    }

    private function scalar(mixed $value): string|int|float|bool|null
    {
        if ($value === null || is_scalar($value)) {
            return $value;
        }

        if ($value instanceof BackedEnum) {
            return $value->value;
        }

        if ($value instanceof UrlRoutable) {
            return (string) $value->getRouteKey();
        }

        if ($value instanceof Stringable) {
            return (string) $value;
        }

        return hash('sha256', serialize($value));
    }

    /** @return array<string|int, mixed> */
    private function sortRecursive(array $value): array
    {
        foreach ($value as $key => $item) {
            if (is_array($item)) {
                $value[$key] = $this->sortRecursive($item);
            }
        }

        if (! array_is_list($value)) {
            ksort($value, SORT_STRING);
        }

        return $value;
    }
}
