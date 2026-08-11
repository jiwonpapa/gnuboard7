<?php

namespace App\Listeners;

use App\Contracts\Extension\HookListenerInterface;
use App\Support\OctaneRuntimeManager;

/**
 * 확장·언어팩·설정 변경 후 장기 실행 중인 Octane 워커를 갱신합니다.
 */
class ExtensionOctaneReloadListener implements HookListenerInterface
{
    public function __construct(private readonly OctaneRuntimeManager $octaneRuntime) {}

    /**
     * @return array<string, array{method: string, priority: int, sync: bool}>
     */
    public static function getSubscribedHooks(): array
    {
        $hooks = [];
        $hookNames = [
            'core.modules.installed',
            'core.modules.updated',
            'core.modules.activated',
            'core.modules.after_deactivate',
            'core.modules.after_uninstall',
            'core.plugins.installed',
            'core.plugins.updated',
            'core.plugins.activated',
            'core.plugins.after_deactivate',
            'core.plugins.after_uninstall',
            'core.templates.installed',
            'core.templates.updated',
            'core.templates.activated',
            'core.templates.after_deactivate',
            'core.templates.after_uninstall',
            'core.language_packs.installed',
            'core.language_packs.updated',
            'core.language_packs.activated',
            'core.language_packs.deactivated',
            'core.language_packs.uninstalled',
            'core.settings.after_save',
            'core.settings.after_set',
            'core.module_settings.after_save',
            'core.module_settings.after_reset',
            'core.plugin_settings.after_save',
            'core.plugin_settings.after_reset',
        ];

        foreach ($hookNames as $hookName) {
            $hooks[$hookName] = [
                'method' => 'onRuntimeChanged',
                'priority' => 40,
                'sync' => true,
            ];
        }

        return $hooks;
    }

    public function handle(...$args): void
    {
        $this->onRuntimeChanged(...$args);
    }

    public function onRuntimeChanged(...$args): void
    {
        $this->octaneRuntime->requestReload('extension_or_settings_changed');
    }
}
