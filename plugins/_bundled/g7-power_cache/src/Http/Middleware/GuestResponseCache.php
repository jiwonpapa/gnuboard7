<?php

namespace Plugins\G7\PowerCache\Http\Middleware;

use Closure;
use Illuminate\Contracts\Cache\Lock;
use Illuminate\Http\Request;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Eligibility\GuestEligibility;
use Plugins\G7\PowerCache\Keys\CanonicalRequestKey;
use Plugins\G7\PowerCache\Policy\ResponsePolicy;
use Plugins\G7\PowerCache\Policy\RoutePolicy;
use Plugins\G7\PowerCache\Policy\RoutePolicyRegistry;
use Plugins\G7\PowerCache\Runtime\PowerCacheSettings;
use Plugins\G7\PowerCache\Runtime\RecoveryBarrier;
use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;
use Symfony\Component\HttpFoundation\Response;
use Throwable;

final class GuestResponseCache
{
    private const STORED_HEADER_ALLOWLIST = [
        'content-type',
        'content-language',
        'cache-control',
        'vary',
        'etag',
        'last-modified',
    ];

    public function __construct(
        private readonly PowerCacheSettings $settings,
        private readonly RoutePolicyRegistry $policies,
        private readonly GuestEligibility $eligibility,
        private readonly CanonicalRequestKey $keys,
        private readonly ResponsePolicy $responsePolicy,
        private readonly PowerCacheStoreInterface $store,
        private readonly RecoveryBarrier $barrier,
    ) {}

    public function handle(Request $request, Closure $next): Response
    {
        $mode = $this->settings->mode();
        if ($mode === 'bypass') {
            return $this->pass($request, $next, 'BYPASS', 'mode');
        }

        $policy = $this->policies->resolve($request);
        if ($policy === null) {
            return $this->pass($request, $next, 'BYPASS', 'policy');
        }

        $eligibility = $this->eligibility->evaluate($request, $policy);
        if (! $eligibility->eligible) {
            return $this->pass($request, $next, 'BYPASS', $eligibility->reason);
        }

        if ($mode === 'observe') {
            $response = $next($request);
            $decision = $this->responsePolicy->evaluate($response, $this->settings->maxResponseBytes());
            $this->metric('observe.'.($decision->cacheable ? 'cacheable' : $decision->reason));

            return $this->debug($response, 'OBSERVE', $decision->reason);
        }

        $barrier = $this->barrier->inspect();
        if (! $barrier->ready || $barrier->snapshot === null) {
            return $this->pass($request, $next, 'BYPASS', $barrier->reason);
        }

        try {
            $requestKey = $this->keys->build(
                $request,
                $policy,
                $barrier->snapshot,
                app()->getLocale(),
                date_default_timezone_get(),
            );
            $entry = $this->validEntry($requestKey, $policy);
            if ($entry !== null) {
                $this->metric('hit.'.$policy->id);

                return $this->responseFromEntry($entry, $request->isMethod('HEAD'), 'HIT');
            }
        } catch (Throwable) {
            return $this->pass($request, $next, 'BYPASS', 'store_read_error');
        }

        $this->metric('miss.'.$policy->id);
        if ($request->isMethod('HEAD')) {
            return $this->pass($request, $next, 'MISS', 'head_no_fill');
        }

        $lock = null;
        try {
            $lock = $this->store->acquireLock('fill:'.$requestKey, $this->settings->lockLeaseSeconds());
        } catch (Throwable) {
            return $this->pass($request, $next, 'MISS', 'lock_error');
        }

        if ($lock === null) {
            $entry = $this->waitForWinner($requestKey, $policy);
            if ($entry !== null) {
                $this->metric('hit_after_wait.'.$policy->id);

                return $this->responseFromEntry($entry, false, 'HIT-AFTER-WAIT');
            }

            return $this->pass($request, $next, 'MISS', 'lock_contended');
        }

        return $this->fill($request, $next, $policy, $barrier->snapshot, $requestKey, $lock);
    }

    private function fill(
        Request $request,
        Closure $next,
        RoutePolicy $policy,
        RuntimeSnapshot $initialSnapshot,
        string $requestKey,
        Lock $lock,
    ): Response {
        $originStarted = false;

        try {
            $existing = $this->validEntry($requestKey, $policy);
            if ($existing !== null) {
                $this->metric('hit_after_lock.'.$policy->id);

                return $this->responseFromEntry($existing, false, 'HIT-AFTER-LOCK');
            }

            $before = $this->store->generations($policy->scopes);
            $originStarted = true;
            $response = $next($request);
            $decision = $this->responsePolicy->evaluate($response, $this->settings->maxResponseBytes());
            if (! $decision->cacheable) {
                $this->metric('not_stored.'.$decision->reason);

                return $this->debug($response, 'MISS', $decision->reason);
            }

            $after = $this->store->generations($policy->scopes);
            if ($before !== $after) {
                $this->metric('not_stored.generation_changed');

                return $this->debug($response, 'MISS', 'generation_changed');
            }

            $finalBarrier = $this->barrier->inspect();
            if (! $finalBarrier->ready
                || $finalBarrier->snapshot === null
                || $finalBarrier->snapshot->siteId !== $initialSnapshot->siteId
                || $finalBarrier->snapshot->runtimeEpoch !== $initialSnapshot->runtimeEpoch) {
                $this->metric('not_stored.barrier_changed');

                return $this->debug($response, 'MISS', 'barrier_changed');
            }

            $body = $response->getContent();
            $this->store->putResponse($requestKey, [
                'version' => 1,
                'status' => $response->getStatusCode(),
                'headers' => $decision->headers,
                'body' => is_string($body) ? $body : '',
                'scopes' => $policy->scopes,
                'generations' => $after,
                'stored_at' => time(),
            ], $policy->retentionSeconds === null
                ? $this->settings->retentionSeconds()
                : min($this->settings->retentionSeconds(), $policy->retentionSeconds));
            $this->metric('stored.'.$policy->id);

            return $this->debug($response, 'MISS-STORED', 'cacheable');
        } catch (Throwable $e) {
            if (isset($response) && $response instanceof Response) {
                $this->metric('not_stored.store_error');

                return $this->debug($response, 'MISS', 'store_error');
            }

            if ($originStarted) {
                throw $e;
            }

            return $this->pass($request, $next, 'MISS', 'store_error');
        } finally {
            try {
                $lock->release();
            } catch (Throwable) {
                // 락 해제 실패도 이미 생성된 원본 응답을 실패시키지 않습니다.
            }
        }
    }

    /** @return array<string, mixed>|null */
    private function waitForWinner(string $requestKey, RoutePolicy $policy): ?array
    {
        $waitMilliseconds = $this->settings->lockWaitMilliseconds();
        if ($waitMilliseconds <= 0) {
            return null;
        }

        $deadline = hrtime(true) + ($waitMilliseconds * 1_000_000);
        do {
            usleep(random_int(40_000, 80_000));
            try {
                $entry = $this->validEntry($requestKey, $policy);
                if ($entry !== null) {
                    return $entry;
                }
            } catch (Throwable) {
                return null;
            }
        } while (hrtime(true) < $deadline);

        return null;
    }

    /** @return array<string, mixed>|null */
    private function validEntry(string $requestKey, RoutePolicy $policy): ?array
    {
        $entry = $this->store->getResponse($requestKey);
        if ($entry === null
            || ($entry['version'] ?? null) !== 1
            || ($entry['status'] ?? null) !== 200
            || ! is_string($entry['body'] ?? null)
            || ! is_array($entry['headers'] ?? null)
            || ! is_array($entry['scopes'] ?? null)
            || ! is_array($entry['generations'] ?? null)
            || strlen($entry['body']) > $this->settings->maxResponseBytes()) {
            return null;
        }

        foreach ($entry['headers'] as $name => $values) {
            if (! is_string($name)
                || ! in_array(strtolower($name), self::STORED_HEADER_ALLOWLIST, true)
                || ! is_array($values)) {
                return null;
            }
            foreach ($values as $value) {
                if (! is_string($value) || str_contains($value, "\r") || str_contains($value, "\n")) {
                    return null;
                }
            }
        }

        $entryScopes = array_values($entry['scopes']);
        if (array_filter($entryScopes, static fn (mixed $scope): bool => ! is_string($scope)) !== []) {
            return null;
        }
        $policyScopes = array_values($policy->scopes);
        sort($entryScopes, SORT_STRING);
        sort($policyScopes, SORT_STRING);
        if ($entryScopes !== $policyScopes) {
            return null;
        }

        $current = $this->store->generations($entryScopes);

        return $current === $entry['generations'] ? $entry : null;
    }

    /** @param array<string, mixed> $entry */
    private function responseFromEntry(array $entry, bool $head, string $state): Response
    {
        $response = new Response(
            $head ? '' : $entry['body'],
            (int) ($entry['status'] ?? 200),
            $entry['headers'],
        );

        return $this->debug($response, $state, 'fresh_generation');
    }

    private function pass(Request $request, Closure $next, string $state, string $reason): Response
    {
        $this->metric(strtolower($state).'.'.$reason);

        return $this->debug($next($request), $state, $reason);
    }

    private function debug(Response $response, string $state, string $reason): Response
    {
        if ($this->settings->debugHeaders()) {
            $response->headers->set('X-G7-Power-Cache', $state.'; reason='.$reason);
        }

        return $response;
    }

    private function metric(string $metric): void
    {
        if (! $this->settings->metricsEnabled()) {
            return;
        }

        try {
            $this->store->incrementMetric($metric);
        } catch (Throwable) {
            // 관측 실패는 원본 요청을 실패시키지 않습니다.
        }
    }
}
