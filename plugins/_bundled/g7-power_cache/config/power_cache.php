<?php

use Illuminate\Support\Str;

return [
    'format_version' => 1,
    'policy_version' => 'guest-api-v1',
    'outbox_retention_days' => (int) env('G7_POWER_CACHE_OUTBOX_RETENTION_DAYS', 7),

    'stores' => [
        'file' => 'g7_power_cache_file',
        'redis' => 'g7_power_cache_redis',
        'array' => 'g7_power_cache_array',
    ],

    'file' => [
        'path' => env('G7_POWER_CACHE_FILE_PATH', storage_path('app/g7-power-cache/cache')),
        'gc_safe_root' => env('G7_POWER_CACHE_FILE_GC_SAFE_ROOT', storage_path('app/g7-power-cache')),
        'single_node_ack' => (bool) env('G7_POWER_CACHE_FILE_SINGLE_NODE', false),
    ],

    'redis' => [
        'connection' => 'g7_power_cache',
        'url' => env('G7_POWER_CACHE_REDIS_URL'),
        'host' => env('G7_POWER_CACHE_REDIS_HOST', env('REDIS_HOST', '127.0.0.1')),
        'username' => env('G7_POWER_CACHE_REDIS_USERNAME', env('REDIS_USERNAME')),
        'password' => env('G7_POWER_CACHE_REDIS_PASSWORD', env('REDIS_PASSWORD')),
        'port' => env('G7_POWER_CACHE_REDIS_PORT', env('REDIS_PORT', 6379)),
        'database' => env('G7_POWER_CACHE_REDIS_DB', 7),
        'prefix' => env('G7_POWER_CACHE_REDIS_PREFIX', Str::slug((string) env('APP_NAME', 'gnuboard7')).':g7pc:'),
    ],
];
