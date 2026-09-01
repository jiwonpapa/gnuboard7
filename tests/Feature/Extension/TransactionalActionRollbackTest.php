<?php

namespace Tests\Feature\Extension;

use App\Extension\HookManager;
use App\Models\Role;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use RuntimeException;
use Tests\TestCase;

final class TransactionalActionRollbackTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();
        HookManager::resetAll();
    }

    protected function tearDown(): void
    {
        HookManager::resetAll();
        parent::tearDown();
    }

    public function test_transactional_listener_failure_rolls_back_caller_write(): void
    {
        HookManager::addAction(
            HookManager::transactionalHookName('test.transaction.rollback'),
            static fn () => throw new RuntimeException('listener failed'),
        );

        try {
            DB::transaction(function () {
                Role::factory()->create(['identifier' => 'transaction-rollback-target']);
                HookManager::doTransactionalAction('test.transaction.rollback');
            });

            self::fail('transactional 리스너 예외가 호출자에게 전파되어야 합니다.');
        } catch (RuntimeException $e) {
            self::assertSame('listener failed', $e->getMessage());
        }

        self::assertDatabaseMissing('roles', ['identifier' => 'transaction-rollback-target']);
    }
}
