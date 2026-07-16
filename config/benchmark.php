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
