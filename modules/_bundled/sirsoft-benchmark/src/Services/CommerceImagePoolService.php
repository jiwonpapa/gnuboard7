<?php

namespace Modules\Sirsoft\Benchmark\Services;

use App\Contracts\Extension\StorageInterface;
use App\Extension\ModuleManager;
use Illuminate\Http\Client\Pool;
use Illuminate\Support\Facades\Http;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;

class CommerceImagePoolService
{
    public function __construct(private ModuleManager $moduleManager) {}

    /**
     * @param  array<string, mixed>  $state
     * @return array<string, mixed>
     */
    public function generateChunk(GenerationJob $job, array $state, int $limit = 10): array
    {
        $options = $job->options ?? [];
        $total = (int) ($options['image_pool_size'] ?? 100);
        $start = (int) ($state['image_pool_index'] ?? 0);

        if ($start >= $total) {
            return $state;
        }
        $indexes = range($start, min($total, $start + $limit) - 1);

        $responses = [];
        if (($options['image_source'] ?? 'picsum') === 'picsum') {
            $responses = Http::pool(function (Pool $pool) use ($indexes, $job) {
                foreach ($indexes as $index) {
                    $pool->as((string) $index)
                        ->withoutVerifying()
                        ->timeout(20)
                        ->get("https://picsum.photos/seed/g7-benchmark-{$job->seed}-{$index}/480/480");
                }
            });
        }

        $storage = $this->storage();
        $poolState = $state['image_pool'] ?? [];

        foreach ($indexes as $index) {
            $response = $responses[(string) $index] ?? null;
            $content = is_object($response) && method_exists($response, 'successful') && $response->successful()
                ? $response->body()
                : null;
            $image = $this->normalizeImage($content, (int) $job->seed, $index);
            $filename = sprintf('pool-%03d.%s', $index + 1, $image['extension']);
            $path = "benchmark/job-{$job->id}/pool/{$filename}";

            if (! $storage->put('images', $path, $image['content'])) {
                throw new \RuntimeException("쇼핑몰 이미지 풀 파일 저장에 실패했습니다: {$path}");
            }

            $poolState[] = [
                'index' => $index,
                'path' => $path,
                'disk' => $storage->getDisk(),
                'filename' => $filename,
                'mime_type' => $image['mime_type'],
                'file_size' => strlen($image['content']),
                'width' => $image['width'],
                'height' => $image['height'],
            ];
        }

        $state['image_pool'] = $poolState;
        $state['image_pool_index'] = min($total, $start + count($indexes));

        return $state;
    }

    public function storage(): StorageInterface
    {
        $module = $this->moduleManager->getModule('sirsoft-ecommerce');
        if (! $module) {
            throw new \RuntimeException('sirsoft-ecommerce 모듈이 설치되어 있지 않습니다.');
        }

        return $module->getStorage();
    }

    /**
     * @return array{content:string,extension:string,mime_type:string,width:int,height:int}
     */
    private function normalizeImage(?string $content, int $seed, int $index): array
    {
        $source = $content && function_exists('imagecreatefromstring') ? @imagecreatefromstring($content) : false;
        if (! $source) {
            $source = $this->createFallbackImage($seed, $index);
        }

        if ($source !== false) {
            $canvas = imagecreatetruecolor(480, 480);
            imagecopyresampled($canvas, $source, 0, 0, 0, 0, 480, 480, imagesx($source), imagesy($source));
            ob_start();
            if (function_exists('imagewebp')) {
                imagewebp($canvas, null, 65);
                $extension = 'webp';
                $mimeType = 'image/webp';
            } else {
                imagejpeg($canvas, null, 78);
                $extension = 'jpg';
                $mimeType = 'image/jpeg';
            }
            $normalized = (string) ob_get_clean();
            imagedestroy($canvas);
            imagedestroy($source);

            return [
                'content' => $normalized,
                'extension' => $extension,
                'mime_type' => $mimeType,
                'width' => 480,
                'height' => 480,
            ];
        }

        if ($content !== null) {
            $size = @getimagesizefromstring($content);

            return [
                'content' => $content,
                'extension' => (($size['mime'] ?? '') === 'image/png') ? 'png' : 'jpg',
                'mime_type' => $size['mime'] ?? 'image/jpeg',
                'width' => (int) ($size[0] ?? 480),
                'height' => (int) ($size[1] ?? 480),
            ];
        }

        throw new \RuntimeException('GD 확장이 없고 원격 이미지도 가져오지 못해 이미지 풀을 만들 수 없습니다.');
    }

    private function createFallbackImage(int $seed, int $index): mixed
    {
        if (! function_exists('imagecreatetruecolor')) {
            return false;
        }

        $image = imagecreatetruecolor(480, 480);
        $base = abs(crc32("{$seed}:{$index}"));
        $background = imagecolorallocate($image, 45 + ($base % 150), 55 + (($base >> 8) % 140), 65 + (($base >> 16) % 130));
        $accent = imagecolorallocate($image, 235, 238, 230);
        imagefilledrectangle($image, 0, 0, 480, 480, $background);
        imagefilledellipse($image, 240, 210, 260, 260, $accent);
        imagestring($image, 5, 180, 365, 'G7 BENCH '.($index + 1), $accent);

        return $image;
    }
}
