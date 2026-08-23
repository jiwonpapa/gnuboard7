<?php

namespace Plugins\G7\PowerCache\Listeners;

use App\Contracts\Extension\HookListenerInterface;
use Illuminate\Support\Facades\Log;
use Plugins\G7\PowerCache\Contracts\InvalidationRepositoryInterface;
use Plugins\G7\PowerCache\Contracts\PowerCacheStoreInterface;
use Plugins\G7\PowerCache\Invalidation\InvalidationCoordinator;
use Plugins\G7\PowerCache\Runtime\PowerCacheSettings;
use Throwable;

final class CoreInvalidationListener implements HookListenerInterface
{
    public function __construct(
        private readonly InvalidationCoordinator $coordinator,
        private readonly InvalidationRepositoryInterface $repository,
        private readonly PowerCacheStoreInterface $store,
    ) {}

    public static function getSubscribedHooks(): array
    {
        $hooks = [
            'core.plugin_settings.after_save' => [
                'method' => 'handlePluginSettings',
                'type' => 'action',
                'sync' => true,
            ],
            'core.plugin_settings.after_reset' => [
                'method' => 'handlePluginSettings',
                'type' => 'action',
                'sync' => true,
            ],
            'core.plugin_settings.after_delete_directory' => [
                'method' => 'handlePluginSettings',
                'type' => 'action',
                'sync' => true,
            ],
        ];

        foreach ([
            'core.settings.after_save',
            'core.settings.after_set',
            'core.module_settings.after_save',
            'core.module_settings.after_reset',
            'core.module_settings.after_delete_directory',
            'core.menu.after_create',
            'core.menu.after_update',
            'core.menu.after_delete',
            'core.menu.after_update_order',
            'core.menu.after_toggle_status',
            'core.menu.after_sync_roles',
            'core.layout.after_update',
            'core.layout.after_version_restore',
            'core.layout_extension.after_update',
            'core.layout_extension.after_version_restore',
            'core.modules.installed',
            'core.modules.activated',
            'core.modules.after_deactivate',
            'core.modules.after_uninstall',
            'core.modules.after_refresh_layouts',
            'core.modules.updated',
            'core.plugins.installed',
            'core.plugins.activated',
            'core.plugins.after_deactivate',
            'core.plugins.after_uninstall',
            'core.plugins.updated',
            'core.templates.installed',
            'core.templates.activated',
            'core.templates.after_deactivate',
            'core.templates.after_uninstall',
            'core.templates.after_delete',
            'core.templates.after_update',
            'core.templates.after_version_update',
            'core.templates.after_refresh_layouts',
            'core.templates.updated',
            'core.language_packs.installed',
            'core.language_packs.updated',
            'core.language_packs.activated',
            'core.language_packs.deactivated',
            'core.language_packs.uninstalled',
        ] as $hook) {
            $hooks[$hook] = ['method' => 'handleSiteMutation', 'type' => 'action', 'sync' => true];
        }

        foreach ([
            'core.role.after_create',
            'core.role.after_update',
            'core.role.after_delete',
            'core.role.after_sync_permissions',
            'core.role.after_toggle_status',
            'core.user.after_create',
            'core.user.after_update',
            'core.user.after_withdraw',
            'core.user.after_delete',
            'sirsoft-core.user.after_bulk_update',
            'core.attachment.after_upload',
            'core.attachment.after_delete',
            'core.attachment.after_reorder',
            'core.attachment.after_bulk_delete',
        ] as $hook) {
            $hooks[$hook] = ['method' => 'handleBoardPresentationMutation', 'type' => 'action', 'sync' => true];
        }

        return $hooks;
    }

    public function handle(...$args): void
    {
        $this->handleSiteMutation(...$args);
    }

    public function handleSiteMutation(...$args): void
    {
        $this->coordinator->invalidate(['site'], 'core-presentation-mutation');
    }

    public function handleBoardPresentationMutation(...$args): void
    {
        $this->coordinator->invalidate(['board:all'], 'board-presentation-mutation');
    }

    public function handlePluginSettings(string $identifier, ...$args): void
    {
        if ($identifier !== PowerCacheSettings::IDENTIFIER) {
            $this->coordinator->invalidate(['site'], 'plugin-settings-mutation', [
                'plugin' => $identifier,
            ]);

            return;
        }

        try {
            // 저장소 드라이버가 바뀌어도 이전 저장소 키가 재활성화되지 않도록 DB epoch를 회전합니다.
            $this->store->markEmergencyDirty('power_cache_settings_change');
            $this->repository->rotateRuntimeEpoch();
            $this->store->putRuntimeSnapshot($this->repository->snapshot());
            $this->store->clearEmergencyDirty();
        } catch (Throwable $e) {
            Log::critical('G7PowerCache 자체 설정 저장 후 runtime epoch 회전에 실패했습니다.', [
                'error' => $e->getMessage(),
            ]);
            $this->coordinator->invalidate(['site'], 'power-cache-settings-fallback');
        }
    }
}
