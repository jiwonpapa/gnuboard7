<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Default Search Engine
    |--------------------------------------------------------------------------
    |
    | 기본 검색 엔진 드라이버를 지정합니다.
    | mysql-fulltext: MySQL FULLTEXT + ngram 파서 (기본값)
    |
    | 플러그인에서 core.search.engine_drivers 필터 훅을 통해
    | 추가 드라이버(meilisearch, elasticsearch 등)를 등록할 수 있습니다.
    | .env에서 SCOUT_DRIVER=meilisearch 등으로 전환하면 즉시 적용됩니다.
    |
    */

    'driver' => env('SCOUT_DRIVER', 'mysql-fulltext'),

    /*
    |--------------------------------------------------------------------------
    | Public integrated search backend
    |--------------------------------------------------------------------------
    |
    | mysql keeps the built-in FULLTEXT implementation. manticore routes only
    | the public integrated-search post/product/page lookups to the local
    | Manticore daemon. General board and admin searches stay on MySQL.
    |
    */

    'integrated' => [
        'driver' => env('G7_INTEGRATED_SEARCH_DRIVER', 'mysql'),
        'manticore' => [
            'host' => env('MANTICORE_HOST', '127.0.0.1'),
            'port' => (int) env('MANTICORE_PORT', 9306),
            'connect_timeout' => (int) env('MANTICORE_CONNECT_TIMEOUT', 1),
            'query_timeout_ms' => (int) env('MANTICORE_QUERY_TIMEOUT_MS', 2000),
            'max_result_window' => (int) env('MANTICORE_MAX_RESULT_WINDOW', 10000),
            'tables' => [
                'posts' => env('MANTICORE_POSTS_TABLE', 'g7_posts'),
                'products' => env('MANTICORE_PRODUCTS_TABLE', 'g7_products'),
                'pages' => env('MANTICORE_PAGES_TABLE', 'g7_pages'),
            ],
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Index Prefix
    |--------------------------------------------------------------------------
    */

    'prefix' => env('SCOUT_PREFIX', ''),

    /*
    |--------------------------------------------------------------------------
    | Queue Data Syncing
    |--------------------------------------------------------------------------
    */

    'queue' => env('SCOUT_QUEUE', false),

    /*
    |--------------------------------------------------------------------------
    | Database Transactions
    |--------------------------------------------------------------------------
    */

    'after_commit' => false,

    /*
    |--------------------------------------------------------------------------
    | Chunk Sizes
    |--------------------------------------------------------------------------
    */

    'chunk' => [
        'searchable' => 500,
        'unsearchable' => 500,
    ],

    /*
    |--------------------------------------------------------------------------
    | Soft Deletes
    |--------------------------------------------------------------------------
    */

    'soft_delete' => true,

    /*
    |--------------------------------------------------------------------------
    | Identify User
    |--------------------------------------------------------------------------
    */

    'identify' => env('SCOUT_IDENTIFY', false),

];
