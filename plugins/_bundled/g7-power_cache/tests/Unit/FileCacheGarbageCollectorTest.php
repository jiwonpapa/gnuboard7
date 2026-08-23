<?php

namespace Plugins\G7\PowerCache\Tests\Unit;

use Illuminate\Filesystem\Filesystem;
use PHPUnit\Framework\TestCase;
use Plugins\G7\PowerCache\Store\FileCacheGarbageCollector;

final class FileCacheGarbageCollectorTest extends TestCase
{
    public function test_only_expired_cache_payloads_are_deleted_and_lock_directory_is_untouched(): void
    {
        $root = sys_get_temp_dir().'/g7pc-gc-'.bin2hex(random_bytes(6));
        mkdir($root.'/aa/bb', 0777, true);
        mkdir($root.'/locks', 0777, true);

        $expired = $root.'/aa/bb/expired';
        $fresh = $root.'/aa/bb/fresh';
        $forever = $root.'/aa/bb/forever';
        $lock = $root.'/locks/expired-lock';
        file_put_contents($expired, '0000000001'.serialize(['expired' => true]));
        file_put_contents($fresh, (string) (time() + 3600).serialize(['fresh' => true]));
        file_put_contents($forever, '9999999999'.serialize(['forever' => true]));
        file_put_contents($lock, '0000000001'.serialize(['lock' => true]));

        try {
            $result = (new FileCacheGarbageCollector)->collect($root, time());

            self::assertTrue($result['supported']);
            self::assertSame(1, $result['deleted']);
            self::assertFileDoesNotExist($expired);
            self::assertFileExists($fresh);
            self::assertFileExists($forever);
            self::assertFileExists($lock);
        } finally {
            (new Filesystem)->deleteDirectory($root);
        }
    }

    public function test_path_outside_explicit_safe_root_is_never_scanned_or_deleted(): void
    {
        $root = sys_get_temp_dir().'/g7pc-gc-'.bin2hex(random_bytes(6));
        $safeRoot = sys_get_temp_dir().'/g7pc-safe-'.bin2hex(random_bytes(6));
        mkdir($root, 0777, true);
        mkdir($safeRoot, 0777, true);
        $expired = $root.'/expired';
        file_put_contents($expired, '0000000001'.serialize(['expired' => true]));

        try {
            $result = (new FileCacheGarbageCollector)->collect($root, time(), $safeRoot);

            self::assertFalse($result['supported']);
            self::assertSame(0, $result['deleted']);
            self::assertFileExists($expired);
        } finally {
            (new Filesystem)->deleteDirectory($root);
            (new Filesystem)->deleteDirectory($safeRoot);
        }
    }
}
