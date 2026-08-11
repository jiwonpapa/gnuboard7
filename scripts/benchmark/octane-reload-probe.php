#!/usr/bin/env php
<?php

declare(strict_types=1);

use App\Extension\HookManager;
use Illuminate\Contracts\Console\Kernel;

define('LARAVEL_START', microtime(true));

$root = dirname(__DIR__, 2);

require $root.'/vendor/autoload.php';

$app = require $root.'/bootstrap/app.php';
$kernel = $app->make(Kernel::class);
$kernel->bootstrap();

$hookName = 'core.plugins.updated';
$registeredHooks = HookManager::getHooks();

if (! isset($registeredHooks[$hookName])) {
    fwrite(STDERR, "Octane reload listener is not registered for {$hookName}.\n");
    exit(2);
}

HookManager::doAction($hookName, 'octane-reload-probe');
$app->terminate();

fwrite(STDOUT, json_encode([
    'hook' => $hookName,
    'registered_callbacks' => count($registeredHooks[$hookName]),
    'dispatched' => true,
], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES).PHP_EOL);
