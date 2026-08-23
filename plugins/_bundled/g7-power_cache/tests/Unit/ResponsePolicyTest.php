<?php

namespace Plugins\G7\PowerCache\Tests\Unit;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Plugins\G7\PowerCache\Policy\ResponsePolicy;
use Symfony\Component\HttpFoundation\Cookie;
use Symfony\Component\HttpFoundation\JsonResponse;

final class ResponsePolicyTest extends TestCase
{
    public function test_default_private_no_cache_json_is_safe_for_internal_origin_cache(): void
    {
        $response = new JsonResponse(['ok' => true]);

        $decision = (new ResponsePolicy)->evaluate($response, 1024);

        self::assertTrue($decision->cacheable);
        self::assertArrayHasKey('cache-control', $decision->headers);
    }

    #[DataProvider('rejectedResponseProvider')]
    public function test_sensitive_responses_are_rejected(string $kind, string $reason): void
    {
        $response = new JsonResponse(['ok' => true]);
        match ($kind) {
            'cookie' => $response->headers->setCookie(Cookie::create('token', 'secret')),
            'no_store' => $response->headers->set('Cache-Control', 'no-store'),
            'vary_cookie' => $response->headers->set('Vary', 'Cookie'),
            'large' => $response->setData(['body' => str_repeat('x', 2048)]),
        };

        $decision = (new ResponsePolicy)->evaluate($response, 1024);

        self::assertFalse($decision->cacheable);
        self::assertSame($reason, $decision->reason);
    }

    public static function rejectedResponseProvider(): array
    {
        return [
            ['cookie', 'set_cookie'],
            ['no_store', 'no_store'],
            ['vary_cookie', 'unsupported_vary'],
            ['large', 'body_size'],
        ];
    }
}
