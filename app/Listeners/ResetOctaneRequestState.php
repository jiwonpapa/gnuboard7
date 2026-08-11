<?php

namespace App\Listeners;

use App\Extension\HookManager;
use App\Support\GuestRoleResolver;
use Illuminate\Support\Facades\Config;

/**
 * Octane 요청 사이에 남아서는 안 되는 그누보드7 정적 상태를 초기화합니다.
 *
 * Octane 패키지가 설치된 경우 CoreServiceProvider가 RequestReceived 이벤트에
 * 이 리스너를 조건부로 연결합니다. 일반 PHP-FPM 실행에는 영향을 주지 않습니다.
 */
class ResetOctaneRequestState
{
    public function handle(mixed $event = null): void
    {
        $this->ensureDeprecationLogChannel();
        GuestRoleResolver::flush();
        HookManager::flushRequestState();
    }

    /**
     * Laravel가 동적으로 만드는 deprecations 채널은 Octane의 요청별 설정
     * 샌드박스에서 사라질 수 있으므로 매 요청 시작 시 안전하게 복원합니다.
     */
    private function ensureDeprecationLogChannel(): void
    {
        if (Config::get('logging.channels.deprecations') !== null) {
            return;
        }

        $driver = Config::get('logging.deprecations.channel', 'null');
        $definition = is_string($driver)
            ? Config::get("logging.channels.{$driver}")
            : null;

        if (is_array($definition)) {
            Config::set('logging.channels.deprecations', $definition);
        }
    }
}
