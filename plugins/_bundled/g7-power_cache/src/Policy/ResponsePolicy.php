<?php

namespace Plugins\G7\PowerCache\Policy;

use Symfony\Component\HttpFoundation\Response;

final class ResponsePolicy
{
    private const SAFE_HEADERS = [
        'content-type',
        'content-language',
        'cache-control',
        'vary',
        'etag',
        'last-modified',
    ];

    private const SAFE_VARY = [
        'accept-encoding',
        'accept-language',
        'x-timezone',
    ];

    public function evaluate(Response $response, int $maxBytes): ResponseDecision
    {
        if ($response->getStatusCode() !== 200) {
            return ResponseDecision::reject('status');
        }

        $contentType = strtolower((string) $response->headers->get('Content-Type'));
        if (! preg_match('~^application/(?:[a-z0-9.+-]+\+)?json(?:\s*;|$)~i', $contentType)) {
            return ResponseDecision::reject('content_type');
        }

        if ($response->headers->getCookies() !== [] || $response->headers->has('Set-Cookie')) {
            return ResponseDecision::reject('set_cookie');
        }

        $cacheControl = strtolower((string) $response->headers->get('Cache-Control'));
        if (preg_match('/(?:^|,)\s*no-store(?:\s*(?:,|$|=))/', $cacheControl)) {
            return ResponseDecision::reject('no_store');
        }

        foreach (['Location', 'WWW-Authenticate', 'Content-Disposition'] as $header) {
            if ($response->headers->has($header)) {
                return ResponseDecision::reject('sensitive_response_header');
            }
        }

        $vary = strtolower((string) $response->headers->get('Vary'));
        if ($vary !== '') {
            $varyHeaders = array_filter(array_map('trim', explode(',', $vary)));
            if (array_diff($varyHeaders, self::SAFE_VARY) !== []) {
                return ResponseDecision::reject('unsupported_vary');
            }
        }

        $body = $response->getContent();
        if (! is_string($body) || strlen($body) > $maxBytes) {
            return ResponseDecision::reject('body_size');
        }

        $headers = [];
        foreach ($response->headers->all() as $name => $values) {
            if (in_array(strtolower($name), self::SAFE_HEADERS, true)) {
                $headers[$name] = array_values(array_map('strval', $values));
            }
        }

        return ResponseDecision::allow($headers);
    }
}
