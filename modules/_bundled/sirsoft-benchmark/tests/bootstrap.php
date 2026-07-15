<?php

$projectRoot = dirname(__DIR__, 4);
$loader = require $projectRoot.'/vendor/autoload.php';
$loader->addPsr4('Modules\\Sirsoft\\Benchmark\\', dirname(__DIR__).'/src/', true);
$loader->addPsr4('Modules\\Sirsoft\\Ecommerce\\', $projectRoot.'/modules/_bundled/sirsoft-ecommerce/src/', true);
