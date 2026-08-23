<?php

namespace Plugins\G7\PowerCache\Store;

use FilesystemIterator;
use RecursiveDirectoryIterator;
use RecursiveIteratorIterator;
use Throwable;

final class FileCacheGarbageCollector
{
    /** @return array{supported:bool, deleted:int} */
    public function collect(string $root, ?int $now = null, ?string $safeRoot = null): array
    {
        $root = rtrim($root, DIRECTORY_SEPARATOR);
        if ($root === '' || ! is_dir($root)) {
            return ['supported' => true, 'deleted' => 0];
        }

        $root = realpath($root) ?: $root;
        if ($root === DIRECTORY_SEPARATOR || dirname($root) === $root) {
            return ['supported' => false, 'deleted' => 0];
        }

        if ($safeRoot !== null) {
            $safeRoot = rtrim(realpath($safeRoot) ?: $safeRoot, DIRECTORY_SEPARATOR);
            $insideSafeRoot = $root === $safeRoot
                || str_starts_with($root, $safeRoot.DIRECTORY_SEPARATOR);
            if ($safeRoot === '' || $safeRoot === DIRECTORY_SEPARATOR || ! $insideSafeRoot) {
                return ['supported' => false, 'deleted' => 0];
            }
        }

        $now ??= time();
        $deleted = 0;
        try {
            $iterator = new RecursiveIteratorIterator(
                new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
                RecursiveIteratorIterator::CHILD_FIRST,
            );

            foreach ($iterator as $item) {
                $path = $item->getPathname();
                $relative = ltrim(substr($path, strlen($root)), DIRECTORY_SEPARATOR);
                if ($relative === 'locks' || str_starts_with($relative, 'locks'.DIRECTORY_SEPARATOR)) {
                    continue;
                }

                if ($item->isDir()) {
                    @rmdir($path);

                    continue;
                }

                if (! $item->isFile()) {
                    continue;
                }

                $handle = @fopen($path, 'rb');
                if ($handle === false) {
                    continue;
                }
                $expiration = fread($handle, 10);
                fclose($handle);

                if (is_string($expiration)
                    && strlen($expiration) === 10
                    && ctype_digit($expiration)
                    && (int) $expiration <= $now
                    && @unlink($path)) {
                    $deleted++;
                }
            }
        } catch (Throwable) {
            return ['supported' => false, 'deleted' => $deleted];
        }

        return ['supported' => true, 'deleted' => $deleted];
    }
}
