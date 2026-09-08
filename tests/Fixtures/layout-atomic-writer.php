<?php

declare(strict_types=1);

use App\Exceptions\ConcurrentModificationException;
use App\Extension\Testing\ExtensionTestAllowlist;
use App\Repositories\LayoutRepository;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';
if (getenv('APP_ENV') !== 'testing') {
    throw new RuntimeException('This worker requires the testing environment.');
}
ExtensionTestAllowlist::set([]);
$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();
$repository = $app->make(LayoutRepository::class);
$layout = $repository->findById((int) $argv[1]);
if ($layout === null) {
    throw new RuntimeException('Missing fixture layout.');
}
// 두 독립 프로세스가 같은 revision을 읽은 뒤 부모의 명시적 신호로 저장한다.
fwrite(STDOUT, "ready\n");
fflush(STDOUT);
if (trim((string) fgets(STDIN)) !== 'save') {
    throw new RuntimeException('Missing save barrier.');
}
try {
    $repository->updateContent($layout->id, ['components' => [], 'extends' => $argv[2]], $layout->lock_version + 1);
    fwrite(STDOUT, "saved\n");
} catch (ConcurrentModificationException $error) {
    fwrite(STDOUT, "conflict\n");
}
