<?php

namespace Plugins\G7\PowerCache\Tests\Unit;

use App\Rules\ValidLayoutStructure;
use App\Rules\WhitelistedEndpoint;
use PHPUnit\Framework\TestCase;
use Plugins\G7\PowerCache\Listeners\ContentInvalidationListener;
use Plugins\G7\PowerCache\Listeners\CoreInvalidationListener;
use Plugins\G7\PowerCache\Plugin;

final class PluginContractTest extends TestCase
{
    public function test_manifest_middleware_and_settings_contracts(): void
    {
        $plugin = new Plugin;

        self::assertSame('g7-power_cache', $plugin->getIdentifier());
        self::assertSame('0.2.0', $plugin->getVersion());
        self::assertSame('observe', $plugin->getConfigValues()['mode']);
        self::assertSame('file', $plugin->getConfigValues()['store_driver']);

        $middleware = $plugin->getMiddleware();
        self::assertCount(1, $middleware);
        self::assertSame(['api'], $middleware[0]['groups']);
        self::assertSame('after_core', $middleware[0]['timing']);
        self::assertCount(4, $middleware[0]['targets']);
        self::assertContains('api.modules.sirsoft-board.boards.posts.index', $middleware[0]['targets']);
    }

    public function test_every_invalidation_hook_is_forced_synchronous(): void
    {
        foreach ([ContentInvalidationListener::class, CoreInvalidationListener::class] as $listener) {
            foreach ($listener::getSubscribedHooks() as $hook => $config) {
                self::assertTrue($config['sync'] ?? false, "{$hook} must be synchronous");
                self::assertSame('action', $config['type'] ?? null);
            }
        }
    }

    public function test_board_list_mutations_and_guest_presentation_changes_are_covered(): void
    {
        $contentHooks = ContentInvalidationListener::getSubscribedHooks();
        foreach ([
            'sirsoft-board.board.after_update',
            'sirsoft-board.post.after_create',
            'sirsoft-board.post.after_update',
            'sirsoft-board.post.after_delete',
            'sirsoft-board.comment.after_create',
            'sirsoft-board.attachment.after_upload',
            'sirsoft-board.permissions.after_update',
        ] as $hook) {
            self::assertSame('handleBoardMutation', $contentHooks[$hook]['method'] ?? null, $hook);
        }

        $coreHooks = CoreInvalidationListener::getSubscribedHooks();
        foreach ([
            'core.role.after_sync_permissions',
            'core.user.after_update',
            'core.attachment.after_upload',
        ] as $hook) {
            self::assertSame('handleBoardPresentationMutation', $coreHooks[$hook]['method'] ?? null, $hook);
        }
    }

    public function test_operational_settings_are_not_exposed_to_public_frontend_config(): void
    {
        $settings = json_decode(
            file_get_contents(dirname(__DIR__, 2).'/config/settings/defaults.json'),
            true,
            flags: JSON_THROW_ON_ERROR,
        );

        foreach ($settings['frontend_schema'] as $name => $schema) {
            self::assertFalse($schema['expose'] ?? true, "{$name} must stay admin-only");
        }
    }

    public function test_admin_settings_layout_passes_core_structure_and_endpoint_rules(): void
    {
        $layout = json_decode(
            file_get_contents(dirname(__DIR__, 2).'/resources/layouts/admin/plugin_settings.json'),
            true,
            flags: JSON_THROW_ON_ERROR,
        );
        $failures = [];
        (new ValidLayoutStructure)->validate(
            'layout',
            $layout,
            static function (string $message) use (&$failures): void {
                $failures[] = $message;
            },
        );

        foreach ($layout['data_sources'] ?? [] as $source) {
            (new WhitelistedEndpoint)->validate(
                'endpoint',
                $source['endpoint'] ?? '',
                static function (string $message) use (&$failures): void {
                    $failures[] = $message;
                },
            );
        }

        self::assertSame([], $failures);
    }
}
