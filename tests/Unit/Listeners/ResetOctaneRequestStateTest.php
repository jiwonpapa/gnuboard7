<?php

namespace Tests\Unit\Listeners;

use App\Extension\HookManager;
use App\Listeners\ResetOctaneRequestState;
use App\Models\Role;
use Illuminate\Support\Facades\Config;
use ReflectionClass;
use Tests\TestCase;

class ResetOctaneRequestStateTest extends TestCase
{
    public function test_flushes_g7_static_request_state(): void
    {
        Config::set('logging.channels.deprecations', null);
        Config::set('logging.deprecations.channel', 'null');
        $role = new Role;
        request()->attributes->set('_guest_role_cache', $role);
        $this->setStaticProperty(HookManager::class, 'dispatching', ['test' => true]);
        $this->setStaticProperty(HookManager::class, 'runningHookStack', ['test']);

        (new ResetOctaneRequestState)->handle();

        $this->assertFalse(request()->attributes->has('_guest_role_cache'));
        $this->assertSame([], $this->getStaticProperty(HookManager::class, 'dispatching'));
        $this->assertSame([], $this->getStaticProperty(HookManager::class, 'runningHookStack'));
        $this->assertSame(
            Config::get('logging.channels.null'),
            Config::get('logging.channels.deprecations')
        );
    }

    private function setStaticProperty(string $class, string $property, mixed $value): void
    {
        $reflection = new ReflectionClass($class);
        $reflection->getProperty($property)->setValue(null, $value);
    }

    private function getStaticProperty(string $class, string $property): mixed
    {
        $reflection = new ReflectionClass($class);

        return $reflection->getProperty($property)->getValue();
    }
}
