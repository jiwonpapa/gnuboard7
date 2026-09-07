<?php

namespace App\Support;

/**
 * 현재 PHP 프로세스가 코어 업데이트 프로세스 트리 안에 있는지 판정하는 단일 SSoT.
 *
 * 코어 업데이트는 부모 `core:update` 가 `core:execute-upgrade-steps` 를 `proc_open` 으로
 * spawn 하고, 그 자식이 다시 `config:cache` 등으로 일회용 Application 을 부팅하는 다층 구조다.
 * 이 트리 안에서만 켜져야 하는 예외 동작이 여럿이라(확장 자동 비활성화 스킵, 코어 버전의
 * env 우선 판독, `bootstrap/app.php` 의 패키지 매니페스트 자가 치유) 판정이 흩어지면
 * 한 곳만 어긋나도 그 경로가 조용히 다르게 동작한다 — 판정을 여기 한 곳에 둔다.
 *
 * 판정 채널이 둘인 이유: `G7_UPDATE_IN_PROGRESS` env 는 부모가 세우고 spawn 자식에게
 * `$env` 로 전파되지만, `variables_order` 에 `E` 가 없는 호스팅에서는 `$_ENV` 가 비어 있을 수
 * 있어 argv 보조 판정을 함께 둔다.
 *
 * 주의: `bootstrap/app.php` 의 자가 치유 블록은 부팅 전이라 이 클래스를 참조할 수 없어
 * 같은 판정을 순수 PHP 로 복제한다. 조건을 바꾸면 그쪽도 함께 고친다.
 */
final class CoreUpdateContext
{
    /**
     * 코어 업데이트를 수행하는 artisan 커맨드 이름 (argv 보조 판정용)
     */
    private const UPDATE_COMMANDS = ['core:update', 'core:execute-upgrade-steps'];

    /**
     * 현재 프로세스가 코어 업데이트 트리(부모 core:update 또는 그 spawn 자식) 안에 있는지 판정합니다.
     *
     * 판정 조건 (OR):
     *   1. 환경변수 `G7_UPDATE_IN_PROGRESS=1` — 부모가 시작 시 설정하고 spawn 자식에 전파
     *   2. artisan 커맨드 이름이 `core:update` / `core:execute-upgrade-steps` — 1 이 전파되지
     *      않은 극단 상황 대비 보조 판정
     *
     * @return bool 업데이트 트리 안이면 true
     */
    public static function isInProgress(): bool
    {
        if (self::hasEnvFlag()) {
            return true;
        }

        $argv = $_SERVER['argv'] ?? [];

        return in_array($argv[1] ?? '', self::UPDATE_COMMANDS, true);
    }

    /**
     * `G7_UPDATE_IN_PROGRESS=1` 환경변수 플래그만 확인합니다 (argv 보조 판정 없음).
     *
     * spawn 자식 여부를 가려야 하는 지점(자식은 사전·사후 단계를 부모에 위임)에서 쓴다.
     * argv 판정을 섞으면 `core:execute-upgrade-steps` 단독 실행이 자식으로 오판된다.
     *
     * @return bool env 플래그가 켜져 있으면 true
     */
    public static function hasEnvFlag(): bool
    {
        $flag = $_ENV['G7_UPDATE_IN_PROGRESS'] ?? $_SERVER['G7_UPDATE_IN_PROGRESS'] ?? getenv('G7_UPDATE_IN_PROGRESS');

        return $flag === '1' || $flag === 1 || $flag === true;
    }
}
