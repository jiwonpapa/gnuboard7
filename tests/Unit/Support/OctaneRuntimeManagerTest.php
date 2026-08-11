<?php

namespace Tests\Unit\Support;

use App\Support\OctaneRuntimeManager;
use Illuminate\Support\Facades\Artisan;
use Tests\TestCase;

class OctaneRuntimeManagerTest extends TestCase
{
    public function test_noops_when_octane_commands_are_not_installed(): void
    {
        Artisan::shouldReceive('all')->once()->andReturn([]);

        $manager = new OctaneRuntimeManager($this->app);

        $this->assertSame(OctaneRuntimeManager::UNAVAILABLE, $manager->requestReload('test'));
    }

    public function test_schedules_one_reload_and_runs_it_when_application_terminates(): void
    {
        Artisan::shouldReceive('all')->once()->andReturn([
            'octane:status' => new \stdClass,
            'octane:reload' => new \stdClass,
        ]);
        Artisan::shouldReceive('call')
            ->once()
            ->with('octane:status', ['--no-interaction' => true])
            ->andReturn(0);
        Artisan::shouldReceive('call')
            ->once()
            ->with('octane:reload', ['--no-interaction' => true])
            ->andReturn(0);

        $manager = new OctaneRuntimeManager($this->app);

        $this->assertSame(OctaneRuntimeManager::SCHEDULED, $manager->requestReload('extension_changed'));
        $this->assertSame(OctaneRuntimeManager::ALREADY_SCHEDULED, $manager->requestReload('settings_changed'));

        $this->app->terminate();
    }

    public function test_does_not_reload_when_octane_server_is_not_running(): void
    {
        Artisan::shouldReceive('all')->once()->andReturn([
            'octane:status' => new \stdClass,
            'octane:reload' => new \stdClass,
        ]);
        Artisan::shouldReceive('call')
            ->once()
            ->with('octane:status', ['--no-interaction' => true])
            ->andReturn(1);
        Artisan::shouldReceive('call')
            ->with('octane:reload', ['--no-interaction' => true])
            ->never();

        $manager = new OctaneRuntimeManager($this->app);
        $manager->requestReload('extension_changed');

        $this->app->terminate();
    }
}
