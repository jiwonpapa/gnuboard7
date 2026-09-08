<?php

namespace Tests\Unit\Services;

use App\Contracts\Extension\CacheInterface;
use App\Contracts\Repositories\LayoutRepositoryInterface;
use App\Contracts\Repositories\LayoutVersionRepositoryInterface;
use App\Contracts\Repositories\TemplateRepositoryInterface;
use App\Services\LayoutExtensionService;
use App\Services\LayoutResolverService;
use App\Services\LayoutService;
use Illuminate\Container\Container;
use Illuminate\Events\Dispatcher;
use Illuminate\Support\Facades\Facade;
use PHPUnit\Framework\TestCase;

/** DB 없이 실제 상속/슬롯 병합 출처 계약을 검증한다. */
final class LayoutCompositionSourceTest extends TestCase
{
    private LayoutService $service;

    protected function setUp(): void
    {
        $container = new Container;
        $container->instance('events', new Dispatcher($container));
        Facade::setFacadeApplication($container);
        $this->service = new LayoutService(
            $this->createStub(LayoutRepositoryInterface::class),
            $this->createStub(LayoutVersionRepositoryInterface::class),
            $this->createStub(TemplateRepositoryInterface::class),
            $this->createStub(LayoutResolverService::class),
            $this->createStub(LayoutExtensionService::class),
            $this->createStub(CacheInterface::class),
        );
    }

    protected function tearDown(): void
    {
        Facade::clearResolvedInstances();
        Facade::setFacadeApplication(null);
    }

    public function test_child_route_owner_and_parent_wrapper_are_distinct_without_public_metadata(): void
    {
        $parent = ['components' => [['id' => 'outer', 'name' => 'Div', 'children' => [
            ['id' => 'slot', 'name' => 'Div', 'slot' => 'content'],
        ]]]];
        $child = ['layout_name' => 'child', 'slots' => ['content' => [
            ['id' => 'own', 'name' => 'Div', 'children' => [['id' => 'leaf', 'name' => 'P', 'text' => 'kept']]],
        ]]];
        $result = $this->service->mergeLayouts($parent, $child, ['kind' => 'base', 'layout' => 'parent']);
        $slot = $result['components'][0]['children'][0];
        self::assertSame(['kind' => 'base', 'layout' => 'parent'], $slot['__source']);
        self::assertSame(['kind' => 'route', 'layout' => 'child'], $slot['children'][0]['__source']);
        self::assertSame(['kind' => 'route', 'layout' => 'child'], $slot['children'][0]['children'][0]['__source']);
        self::assertSame('kept', $slot['children'][0]['children'][0]['text']);
        $public = $this->service->mergeLayouts($parent, $child);
        self::assertArrayNotHasKey('__source', $public['components'][0]);
        self::assertArrayNotHasKey('__source', $public['components'][0]['children'][0]['children'][0]);
        $actualName = $this->service->mergeLayouts($parent, $child, ['kind' => 'base', 'layout' => 'parent'], 'actual-file');
        self::assertSame('actual-file', $actualName['components'][0]['children'][0]['children'][0]['__source']['layout']);
    }
}
