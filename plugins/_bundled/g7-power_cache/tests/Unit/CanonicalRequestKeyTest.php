<?php

namespace Plugins\G7\PowerCache\Tests\Unit;

use Plugins\G7\PowerCache\Keys\CanonicalRequestKey;
use Plugins\G7\PowerCache\Policy\RoutePolicy;
use Plugins\G7\PowerCache\Runtime\RuntimeSnapshot;
use Plugins\G7\PowerCache\Tests\Support\PowerCacheTestCase;

final class CanonicalRequestKeyTest extends PowerCacheTestCase
{
    public function test_equivalent_query_order_is_stable_but_locale_and_epoch_are_isolated(): void
    {
        $policy = new RoutePolicy(
            'test-v1',
            'api.modules.sirsoft-page.pages.show',
            ['site', 'page:all'],
            ['a', 'b'],
            ['api', 'optional.sanctum', 'throttle:600,1'],
        );
        $snapshot = new RuntimeSnapshot('site-a', 'epoch-a', 0);
        $keys = new CanonicalRequestKey;

        $first = $keys->build($this->request(query: ['a' => '1', 'b' => '2']), $policy, $snapshot, 'ko', 'Asia/Seoul');
        $second = $keys->build($this->request(query: ['b' => '2', 'a' => '1']), $policy, $snapshot, 'ko', 'Asia/Seoul');
        $english = $keys->build($this->request(query: ['a' => '1', 'b' => '2']), $policy, $snapshot, 'en', 'Asia/Seoul');
        $newEpoch = $keys->build(
            $this->request(query: ['a' => '1', 'b' => '2']),
            $policy,
            new RuntimeSnapshot('site-a', 'epoch-b', 0),
            'ko',
            'Asia/Seoul',
        );

        self::assertSame($first, $second);
        self::assertNotSame($first, $english);
        self::assertNotSame($first, $newEpoch);
    }

    public function test_board_policy_separates_mobile_and_desktop_variants(): void
    {
        $policy = new RoutePolicy(
            'board-public-hot-list-v1',
            'api.modules.sirsoft-board.boards.posts.index',
            ['site', 'board:all'],
            ['page'],
            ['api'],
            varyByDeviceClass: true,
        );
        $snapshot = new RuntimeSnapshot('site-a', 'epoch-a', 0);
        $keys = new CanonicalRequestKey;
        $desktop = $keys->build(
            $this->request(headers: ['User-Agent' => 'Mozilla/5.0 Macintosh']),
            $policy,
            $snapshot,
            'ko',
            'Asia/Seoul',
        );
        $mobile = $keys->build(
            $this->request(headers: ['User-Agent' => 'Mozilla/5.0 iPhone Mobile']),
            $policy,
            $snapshot,
            'ko',
            'Asia/Seoul',
        );

        self::assertNotSame($desktop, $mobile);
    }
}
