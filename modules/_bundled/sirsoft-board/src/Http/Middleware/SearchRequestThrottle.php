<?php

namespace Modules\Sirsoft\Board\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Routing\Middleware\ThrottleRequests;
use Symfony\Component\HttpFoundation\Response;

/**
 * 게시글 목록 중 실제 검색 요청만 별도 속도 제한합니다.
 *
 * 일반 목록은 기존 600회/분 제한을 그대로 사용하고, 검색은 사용자 ID 또는
 * 비회원 IP를 기준으로 모듈 전체에서 공유하는 10회/분 버킷을 적용합니다.
 */
final class SearchRequestThrottle
{
    public function __construct(
        private readonly ThrottleRequests $throttleRequests,
    ) {}

    public function handle(Request $request, Closure $next): Response
    {
        $filters = $request->query('filters', []);
        $adminSearch = is_array($filters) ? data_get($filters, '0.value') : null;
        if (blank($request->query('search')) && blank($adminSearch)) {
            return $next($request);
        }

        return $this->throttleRequests->handle(
            $request,
            $next,
            10,
            1,
            'sirsoft-board-search:',
        );
    }
}
