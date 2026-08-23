<?php

namespace Plugins\G7\PowerCache\Tests\Support;

use Illuminate\Cache\ArrayStore;
use Illuminate\Cache\Repository as CacheRepository;
use Illuminate\Config\Repository as ConfigRepository;
use Illuminate\Database\Capsule\Manager as Capsule;
use Illuminate\Database\DatabaseTransactionsManager;
use Illuminate\Foundation\Application;
use Illuminate\Http\Request;
use Illuminate\Routing\Route;
use Illuminate\Support\Facades\Facade;
use PHPUnit\Framework\TestCase;
use Plugins\G7\PowerCache\Infrastructure\DatabaseInvalidationRepository;
use Plugins\G7\PowerCache\Store\LaravelPowerCacheStore;
use Psr\Log\NullLogger;

abstract class PowerCacheTestCase extends TestCase
{
    protected Application $app;

    protected Capsule $database;

    protected function setUp(): void
    {
        parent::setUp();

        Facade::clearResolvedInstances();
        $this->app = new Application(dirname(__DIR__, 5));
        $this->app->detectEnvironment(fn (): string => 'testing');
        $this->app->instance('log', new NullLogger);
        $this->app->instance('config', new ConfigRepository([
            'app' => ['locale' => 'ko', 'fallback_locale' => 'en'],
            'database' => ['default' => 'testing'],
            'g7_power_cache' => [
                'format_version' => 1,
                'policy_version' => 'guest-api-v1',
                'file' => ['single_node_ack' => true],
            ],
        ]));
        Facade::setFacadeApplication($this->app);

        $this->database = new Capsule($this->app);
        $this->database->addConnection([
            'driver' => 'sqlite',
            'database' => ':memory:',
            'prefix' => '',
        ], 'testing');
        $this->database->setAsGlobal();
        $this->database->bootEloquent();
        $this->database->getDatabaseManager()->setDefaultConnection('testing');
        $transactions = new DatabaseTransactionsManager;
        $this->database->getConnection('testing')->setTransactionManager($transactions);
        $this->app->instance('db.transactions', $transactions);
        $this->app->instance('db', $this->database->getDatabaseManager());
        $this->app->instance('db.schema', $this->database->getConnection('testing')->getSchemaBuilder());

        $migration = require dirname(__DIR__, 2).'/database/migrations/2026_08_23_000001_create_g7_power_cache_tables.php';
        $migration->up();
    }

    protected function repository(): DatabaseInvalidationRepository
    {
        return new DatabaseInvalidationRepository;
    }

    protected function arrayStore(): LaravelPowerCacheStore
    {
        return new LaravelPowerCacheStore(new CacheRepository(new ArrayStore(true)), 'array');
    }

    /** @param array<int, string> $middleware */
    protected function request(
        string $routeName = 'api.modules.sirsoft-page.pages.show',
        array $middleware = ['api', 'optional.sanctum', 'throttle:600,1'],
        string $uri = '/api/modules/sirsoft-page/pages/about',
        array $query = [],
        array $cookies = [],
        array $headers = [],
    ): Request {
        $server = [];
        foreach ($headers as $name => $value) {
            $server['HTTP_'.strtoupper(str_replace('-', '_', $name))] = $value;
        }

        $request = Request::create($uri, 'GET', $query, $cookies, [], $server);
        $route = new Route(['GET', 'HEAD'], 'api/modules/sirsoft-page/pages/{slug}', fn () => null);
        $route->name($routeName);
        $route->middleware($middleware);
        $route->bind($request);
        $request->setRouteResolver(fn () => $route);
        $request->setUserResolver(fn () => null);

        return $request;
    }
}
