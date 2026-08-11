<?php

namespace Tests\Unit\Listeners;

use App\Contracts\Extension\HookListenerInterface;
use App\Listeners\ExtensionOctaneReloadListener;
use App\Support\OctaneRuntimeManager;
use Tests\TestCase;

class ExtensionOctaneReloadListenerTest extends TestCase
{
    public function test_subscribes_to_runtime_changing_extension_and_settings_hooks(): void
    {
        $hooks = ExtensionOctaneReloadListener::getSubscribedHooks();

        $expected = [
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

        $this->assertInstanceOf(
            HookListenerInterface::class,
            new ExtensionOctaneReloadListener($this->createMock(OctaneRuntimeManager::class))
        );
        $this->assertEqualsCanonicalizing($expected, array_keys($hooks));

        foreach ($hooks as $configuration) {
            $this->assertSame('onRuntimeChanged', $configuration['method']);
            $this->assertSame(40, $configuration['priority']);
            $this->assertTrue($configuration['sync']);
        }
    }

    public function test_requests_one_deferred_reload_when_hook_runs(): void
    {
        $runtime = $this->createMock(OctaneRuntimeManager::class);
        $runtime->expects($this->once())
            ->method('requestReload')
            ->with('extension_or_settings_changed')
            ->willReturn(OctaneRuntimeManager::SCHEDULED);

        $listener = new ExtensionOctaneReloadListener($runtime);
        $listener->onRuntimeChanged('sirsoft-example');
    }
}
