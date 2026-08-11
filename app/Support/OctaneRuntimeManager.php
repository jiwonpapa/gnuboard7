<?php

namespace App\Support;

use Illuminate\Foundation\Application;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Log;

/**
 * 설치 여부가 선택적인 Laravel Octane 런타임을 안전하게 갱신합니다.
 *
 * 확장 및 설정 변경 도중 워커를 즉시 재시작하면 현재 HTTP 응답이나 Artisan 명령이
 * 끊길 수 있습니다. 따라서 애플리케이션 종료 콜백에 reload를 한 번만 예약하고,
 * 실제 Octane 서버가 실행 중인 경우에만 워커를 갱신합니다.
 */
class OctaneRuntimeManager
{
    public const UNAVAILABLE = 'unavailable';

    public const ALREADY_SCHEDULED = 'already_scheduled';

    public const SCHEDULED = 'scheduled';

    public const NOT_RUNNING = 'not_running';

    public const RELOADED = 'reloaded';

    public const FAILED = 'failed';

    private bool $reloadScheduled = false;

    public function __construct(private readonly Application $app) {}

    /**
     * 현재 요청 또는 Artisan 명령이 끝난 뒤 Octane 워커 갱신을 예약합니다.
     *
     * Octane 패키지가 설치되지 않은 일반 PHP-FPM 환경에서는 아무 작업도 하지 않습니다.
     */
    public function requestReload(string $reason): string
    {
        if ($this->reloadScheduled) {
            return self::ALREADY_SCHEDULED;
        }

        if (! $this->commandsAvailable()) {
            return self::UNAVAILABLE;
        }

        $this->reloadScheduled = true;

        $this->app->terminating(function () use ($reason): void {
            $this->reloadIfRunning($reason);
        });

        Log::info('[Octane] 워커 갱신 예약', ['reason' => $reason]);

        return self::SCHEDULED;
    }

    /**
     * 실행 중인 Octane 서버가 있을 때만 워커를 graceful reload 합니다.
     */
    public function reloadIfRunning(string $reason): string
    {
        try {
            if (Artisan::call('octane:status', ['--no-interaction' => true]) !== 0) {
                return self::NOT_RUNNING;
            }

            $exitCode = Artisan::call('octane:reload', ['--no-interaction' => true]);
            if ($exitCode !== 0) {
                Log::warning('[Octane] 워커 갱신 실패', [
                    'reason' => $reason,
                    'exit_code' => $exitCode,
                    'output' => trim(Artisan::output()),
                ]);

                return self::FAILED;
            }

            Log::info('[Octane] 워커 갱신 완료', ['reason' => $reason]);

            return self::RELOADED;
        } catch (\Throwable $e) {
            Log::warning('[Octane] 워커 갱신 중 예외 발생', [
                'reason' => $reason,
                'error' => $e->getMessage(),
            ]);

            return self::FAILED;
        }
    }

    /**
     * Octane 패키지가 선택적으로 설치된 경우에만 명령을 사용합니다.
     */
    private function commandsAvailable(): bool
    {
        try {
            $commands = Artisan::all();

            return isset($commands['octane:status'], $commands['octane:reload']);
        } catch (\Throwable) {
            return false;
        }
    }
}
