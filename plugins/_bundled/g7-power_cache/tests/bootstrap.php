<?php

$root = dirname(__DIR__, 4);
require_once $root.'/vendor/autoload.php';

spl_autoload_register(static function (string $class): void {
    $prefix = 'Plugins\\G7\\PowerCache\\';
    if (! str_starts_with($class, $prefix)) {
        return;
    }

    $relative = substr($class, strlen($prefix));
    $root = dirname(__DIR__);
    foreach ([$root.'/src/', $root.'/'] as $base) {
        $path = $base.str_replace('\\', '/', $relative).'.php';
        if (is_file($path)) {
            require_once $path;

            return;
        }
    }
});

require_once dirname(__DIR__).'/plugin.php';
