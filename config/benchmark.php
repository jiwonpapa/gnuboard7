<?php

$commonVariant = env('G7_COMMON_PERFORMANCE_VARIANT', 'optimized');
$boardListVariant = env('G7_BOARD_PERFORMANCE_VARIANT', 'optimized');
$ecommerceVariant = env('G7_ECOMMERCE_PERFORMANCE_VARIANT', 'optimized');

return [
    /*
    |--------------------------------------------------------------------------
    | Common bootstrap performance variant
    |--------------------------------------------------------------------------
    |
    | optimized: aggregate high-volume bootstrap diagnostics such as hook
    | listener registration logs. baseline: preserve the original per-item
    | diagnostics for controlled A/B benchmarks and troubleshooting.
    |
    */
    'common_variant' => in_array($commonVariant, ['baseline', 'optimized'], true)
        ? $commonVariant
        : 'optimized',

    /*
    |--------------------------------------------------------------------------
    | Board list performance variant
    |--------------------------------------------------------------------------
    |
    | optimized: ID-only deferred join, bounded notice/reply expansion, and
    | request-level query reuse. baseline: the original G7 7.0.4 code paths.
    |
    */
    'board_list_variant' => in_array($boardListVariant, ['baseline', 'optimized'], true)
        ? $boardListVariant
        : 'optimized',

    /*
    |--------------------------------------------------------------------------
    | Synchronous board search result cap
    |--------------------------------------------------------------------------
    |
    | Optimized search never performs an unbounded synchronous COUNT. The API
    | returns an exact total below this boundary and a documented lower bound
    | once the boundary is reached. Baseline keeps the original exact COUNT.
    |
    */
    'board_search_sync_cap' => max(10, (int) env('G7_BOARD_SEARCH_SYNC_CAP', 1000)),

    /*
    |--------------------------------------------------------------------------
    | Board search fallback scan cap
    |--------------------------------------------------------------------------
    |
    | If InnoDB rejects a broad FULLTEXT query at its per-query memory guard,
    | search only this many recent eligible posts. This keeps the fallback
    | physically bounded instead of degrading into a full-table LIKE scan.
    |
    */
    'board_search_fallback_scan_cap' => max(
        100,
        min(5000, (int) env('G7_BOARD_SEARCH_FALLBACK_SCAN_CAP', 1000))
    ),

    /*
    |--------------------------------------------------------------------------
    | Ecommerce storefront performance variant
    |--------------------------------------------------------------------------
    |
    | optimized: batched category/breadcrumb resolution, ID-first pagination,
    | request-level ability reuse, and short-lived storefront caches.
    |
    */
    'ecommerce_variant' => in_array($ecommerceVariant, ['baseline', 'optimized'], true)
        ? $ecommerceVariant
        : 'optimized',
];
