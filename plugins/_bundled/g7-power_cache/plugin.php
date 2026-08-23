<?php

namespace Plugins\G7\PowerCache;

use App\Extension\AbstractPlugin;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;
use Plugins\G7\PowerCache\Http\Middleware\GuestResponseCache;
use Plugins\G7\PowerCache\Listeners\ContentInvalidationListener;
use Plugins\G7\PowerCache\Listeners\CoreInvalidationListener;

final class Plugin extends AbstractPlugin
{
    public function getConfig(): array
    {
        return ['g7_power_cache' => __DIR__.'/config/power_cache.php'];
    }

    public function getMiddleware(): array
    {
        return [[
            'class' => GuestResponseCache::class,
            'groups' => ['api'],
            'timing' => 'after_core',
            'targets' => [
                'api.modules.sirsoft-page.pages.show',
                'api.modules.sirsoft-ecommerce.categories.index',
                'api.modules.sirsoft-ecommerce.categories.show',
                'api.modules.sirsoft-board.boards.posts.index',
            ],
        ]];
    }

    public function getHookListeners(): array
    {
        return [
            ContentInvalidationListener::class,
            CoreInvalidationListener::class,
        ];
    }

    public function getSchedules(): array
    {
        return [[
            'command' => 'power-cache:gc',
            'schedule' => 'daily',
            'description' => 'G7PowerCache 적용 완료 아웃박스 이력 정리',
            'enabled_config' => null,
        ]];
    }

    public function getPermissions(): array
    {
        return [
            [
                'identifier' => 'g7-power_cache.operations.view',
                'name' => ['ko' => '파워캐시 상태 조회', 'en' => 'View PowerCache status'],
                'description' => ['ko' => '캐시 상태와 진단 결과를 조회합니다.', 'en' => 'View cache status and diagnostics.'],
                'type' => 'admin',
                'roles' => ['admin'],
            ],
            [
                'identifier' => 'g7-power_cache.operations.purge',
                'name' => ['ko' => '파워캐시 무효화', 'en' => 'Invalidate PowerCache'],
                'description' => ['ko' => '세대를 회전하고 복구 작업을 실행합니다.', 'en' => 'Rotate generations and run recovery.'],
                'type' => 'admin',
                'roles' => ['admin'],
            ],
        ];
    }

    public function getSettingsSchema(): array
    {
        return [
            'mode' => $this->enumSetting('실행 모드', 'Mode', ['observe', 'active', 'bypass'], 'observe'),
            'store_driver' => $this->enumSetting('저장소', 'Store driver', ['file', 'redis'], 'file'),
            'cache_public_pages' => $this->booleanSetting('공개 페이지 캐시', 'Cache public pages', true),
            'cache_public_categories' => $this->booleanSetting('공개 카테고리 캐시', 'Cache public categories', true),
            'cache_public_board_lists' => $this->booleanSetting('공개 게시판 목록 캐시', 'Cache public board lists', true),
            'automatic_recovery' => $this->booleanSetting('자동 아웃박스 복구', 'Automatic outbox recovery', true),
            'metrics_enabled' => $this->booleanSetting('메트릭 기록', 'Record metrics', true),
            'debug_headers' => $this->booleanSetting('디버그 응답 헤더', 'Debug response headers', false),
            'max_response_kb' => $this->integerSetting('최대 응답 크기(KB)', 'Maximum response size (KB)', 512, 16, 4096),
            'retention_seconds' => $this->integerSetting('백엔드 보존시간(초)', 'Backend retention (seconds)', 604800, 3600, 2592000),
            'lock_wait_ms' => $this->integerSetting('MISS 락 대기(ms)', 'MISS lock wait (ms)', 500, 0, 5000),
            'lock_lease_seconds' => $this->integerSetting('MISS 락 임대(초)', 'MISS lock lease (seconds)', 15, 1, 120),
            'recovery_batch' => $this->integerSetting('복구 배치 크기', 'Recovery batch size', 100, 1, 1000),
        ];
    }

    public function getConfigValues(): array
    {
        return [
            'mode' => 'observe',
            'store_driver' => 'file',
            'cache_public_pages' => true,
            'cache_public_categories' => true,
            'cache_public_board_lists' => true,
            'automatic_recovery' => true,
            'metrics_enabled' => true,
            'debug_headers' => false,
            'max_response_kb' => 512,
            'retention_seconds' => 604800,
            'lock_wait_ms' => 500,
            'lock_lease_seconds' => 15,
            'recovery_batch' => 100,
        ];
    }

    public function activate(): bool
    {
        $this->rotateRuntimeEpoch();

        return true;
    }

    public function deactivate(): bool
    {
        $this->rotateRuntimeEpoch();

        return true;
    }

    /** @return array<string, mixed> */
    private function enumSetting(string $ko, string $en, array $options, string $default): array
    {
        return [
            'type' => 'enum',
            'options' => $options,
            'default' => $default,
            'label' => ['ko' => $ko, 'en' => $en],
            'required' => true,
        ];
    }

    /** @return array<string, mixed> */
    private function booleanSetting(string $ko, string $en, bool $default): array
    {
        return [
            'type' => 'boolean',
            'default' => $default,
            'label' => ['ko' => $ko, 'en' => $en],
            'required' => false,
        ];
    }

    /** @return array<string, mixed> */
    private function integerSetting(string $ko, string $en, int $default, int $min, int $max): array
    {
        return [
            'type' => 'integer',
            'default' => $default,
            'min' => $min,
            'max' => $max,
            'label' => ['ko' => $ko, 'en' => $en],
            'required' => true,
        ];
    }

    private function rotateRuntimeEpoch(): void
    {
        if (! Schema::hasTable('g7_power_cache_state')) {
            return;
        }

        DB::table('g7_power_cache_state')->updateOrInsert(
            ['state_key' => 'runtime_epoch'],
            [
                'state_value' => (string) Str::uuid(),
                'created_at' => now(),
                'updated_at' => now(),
            ],
        );
    }
}
