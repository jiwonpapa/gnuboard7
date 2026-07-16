<?php

namespace Modules\Sirsoft\Board\Tests\Feature;

use Illuminate\Support\Facades\Route;
use Modules\Sirsoft\Board\Http\Middleware\SearchRequestThrottle;
use Modules\Sirsoft\Board\Tests\ModuleTestCase;

class SearchRequestThrottleTest extends ModuleTestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Route::middleware(['api', SearchRequestThrottle::class])
            ->get('/api/test-board-search-throttle', fn () => response()->json(['ok' => true]));
    }

    public function test_search_requests_are_limited_per_guest_ip(): void
    {
        $firstIp = ['REMOTE_ADDR' => '203.0.113.10'];

        for ($attempt = 0; $attempt < 10; $attempt++) {
            $this->withServerVariables($firstIp)
                ->getJson('/api/test-board-search-throttle?search=needle')
                ->assertOk();
        }

        $this->withServerVariables($firstIp)
            ->getJson('/api/test-board-search-throttle?search=needle')
            ->assertTooManyRequests()
            ->assertHeader('Retry-After');

        $this->withServerVariables(['REMOTE_ADDR' => '203.0.113.11'])
            ->getJson('/api/test-board-search-throttle?search=needle')
            ->assertOk();
    }

    public function test_search_requests_are_limited_per_authenticated_user(): void
    {
        $firstUser = $this->createUser();
        $secondUser = $this->createUser();

        for ($attempt = 0; $attempt < 10; $attempt++) {
            $this->actingAs($firstUser)
                ->getJson('/api/test-board-search-throttle?search=needle')
                ->assertOk();
        }

        $this->actingAs($firstUser)
            ->getJson('/api/test-board-search-throttle?search=needle')
            ->assertTooManyRequests();

        $this->actingAs($secondUser)
            ->getJson('/api/test-board-search-throttle?search=needle')
            ->assertOk();
    }

    public function test_non_search_requests_bypass_search_guard(): void
    {
        for ($attempt = 0; $attempt < 11; $attempt++) {
            $this->getJson('/api/test-board-search-throttle')->assertOk();
            $this->getJson('/api/test-board-search-throttle?search=%20%20')->assertOk();
            $this->getJson('/api/test-board-search-throttle?filters[0][value]=%20')->assertOk();
        }
    }

    public function test_admin_filter_search_shape_uses_the_same_guard(): void
    {
        $server = ['REMOTE_ADDR' => '203.0.113.12'];

        for ($attempt = 0; $attempt < 10; $attempt++) {
            $this->withServerVariables($server)
                ->getJson('/api/test-board-search-throttle?filters[0][field]=all&filters[0][value]=needle')
                ->assertOk();
        }

        $this->withServerVariables($server)
            ->getJson('/api/test-board-search-throttle?filters[0][field]=all&filters[0][value]=needle')
            ->assertTooManyRequests()
            ->assertHeader('Retry-After');
    }

    public function test_user_and_admin_post_indexes_keep_base_throttle_and_add_search_guard(): void
    {
        Route::getRoutes()->refreshNameLookups();

        foreach ([
            'api.modules.sirsoft-board.boards.posts.index',
            'api.modules.sirsoft-board.admin.board.posts.index',
        ] as $routeName) {
            $route = Route::getRoutes()->getByName($routeName);

            $this->assertNotNull($route, "{$routeName} 라우트가 등록되어야 합니다.");

            $middleware = $route->middleware();

            $this->assertContains(SearchRequestThrottle::class, $middleware);
            $this->assertTrue(
                collect($middleware)->contains(
                    fn (string $entry): bool => $entry === 'throttle:600,1'
                        || str_contains($entry, 'ThrottleRequests:600,1')
                ),
                "{$routeName} 라우트는 기존 600회/분 제한을 유지해야 합니다.",
            );
        }
    }
}
