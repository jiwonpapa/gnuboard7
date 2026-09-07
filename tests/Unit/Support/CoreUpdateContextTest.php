<?php

namespace Tests\Unit\Support;

use App\Support\CoreUpdateContext;
use PHPUnit\Framework\Attributes\Test;
use Tests\TestCase;

/**
 * 코어 업데이트 트리 판정 단일 SSoT 테스트 (dev-g7 #658).
 *
 * 이 판정 하나가 세 가지를 게이트한다 — 확장 자동 비활성화 스킵, 코어 버전의 env 우선 판독,
 * `bootstrap/app.php` 의 패키지 매니페스트 자가 치유. 판정이 어긋나면 그중 한 경로만 조용히
 * 다르게 동작하므로 세 채널($_ENV/$_SERVER/putenv)과 argv 를 각각 잠근다.
 */
class CoreUpdateContextTest extends TestCase
{
    /** @var string|null 원래 env 값 (3채널 복원용) */
    private ?string $originalFlag = null;

    /** @var array<int, string> 원래 argv */
    private array $originalArgv = [];

    protected function setUp(): void
    {
        parent::setUp();

        $current = $_ENV['G7_UPDATE_IN_PROGRESS'] ?? $_SERVER['G7_UPDATE_IN_PROGRESS'] ?? getenv('G7_UPDATE_IN_PROGRESS');
        $this->originalFlag = ($current === false || $current === null) ? null : (string) $current;
        $this->originalArgv = $_SERVER['argv'] ?? [];

        $this->clearFlag();
        $_SERVER['argv'] = ['artisan', 'inspire'];
    }

    protected function tearDown(): void
    {
        if ($this->originalFlag === null) {
            $this->clearFlag();
        } else {
            $_ENV['G7_UPDATE_IN_PROGRESS'] = $this->originalFlag;
            $_SERVER['G7_UPDATE_IN_PROGRESS'] = $this->originalFlag;
            putenv('G7_UPDATE_IN_PROGRESS='.$this->originalFlag);
        }

        $_SERVER['argv'] = $this->originalArgv;

        parent::tearDown();
    }

    /**
     * 플래그도 업데이트 argv 도 없으면 트리 밖이다.
     *
     * @effects CoreUpdateContext_isInProgress_detects_env_flag_or_update_argv
     */
    #[Test]
    public function 플래그와_argv_가_모두_없으면_트리_밖이다(): void
    {
        $this->assertFalse(CoreUpdateContext::isInProgress());
        $this->assertFalse(CoreUpdateContext::hasEnvFlag());
    }

    /**
     * `$_ENV` 채널만으로도 감지한다.
     */
    #[Test]
    public function env_배열_채널의_플래그를_감지한다(): void
    {
        $_ENV['G7_UPDATE_IN_PROGRESS'] = '1';

        $this->assertTrue(CoreUpdateContext::isInProgress());
        $this->assertTrue(CoreUpdateContext::hasEnvFlag());
    }

    /**
     * `$_SERVER` 채널만으로도 감지한다 (`variables_order` 에 `E` 가 없으면 `$_ENV` 가 빈다).
     */
    #[Test]
    public function server_배열_채널의_플래그를_감지한다(): void
    {
        $_SERVER['G7_UPDATE_IN_PROGRESS'] = '1';

        $this->assertTrue(CoreUpdateContext::isInProgress());
        $this->assertTrue(CoreUpdateContext::hasEnvFlag());
    }

    /**
     * putenv 채널만으로도 감지한다 (proc_open 이 자식에 넘긴 프로세스 환경 테이블).
     */
    #[Test]
    public function putenv_채널의_플래그를_감지한다(): void
    {
        putenv('G7_UPDATE_IN_PROGRESS=1');

        $this->assertTrue(CoreUpdateContext::isInProgress());
        $this->assertTrue(CoreUpdateContext::hasEnvFlag());
    }

    /**
     * '1' 이 아닌 값은 플래그가 아니다.
     */
    #[Test]
    public function 플래그_값이_1_이_아니면_트리_밖이다(): void
    {
        $_ENV['G7_UPDATE_IN_PROGRESS'] = '0';

        $this->assertFalse(CoreUpdateContext::isInProgress());
        $this->assertFalse(CoreUpdateContext::hasEnvFlag());
    }

    /**
     * 플래그가 전파되지 않은 극단 상황 대비 — argv 로도 판정한다.
     */
    #[Test]
    public function 업데이트_커맨드_argv_로도_트리_안으로_판정한다(): void
    {
        foreach (['core:update', 'core:execute-upgrade-steps'] as $command) {
            $_SERVER['argv'] = ['artisan', $command, '--force'];

            $this->assertTrue(CoreUpdateContext::isInProgress(), "argv {$command} 는 업데이트 트리로 판정한다");
        }
    }

    /**
     * `hasEnvFlag()` 는 argv 보조 판정을 섞지 않는다 — 섞으면 단독 실행이 spawn 자식으로
     * 오판되어 사전·사후 단계를 통째로 건너뛴다.
     */
    #[Test]
    public function has_env_flag_는_argv_만으로는_참이_되지_않는다(): void
    {
        $_SERVER['argv'] = ['artisan', 'core:execute-upgrade-steps', '--force'];

        $this->assertTrue(CoreUpdateContext::isInProgress(), 'isInProgress 는 argv 로도 참');
        $this->assertFalse(CoreUpdateContext::hasEnvFlag(), 'hasEnvFlag 는 env 플래그만 본다');
    }

    /**
     * `bootstrap/app.php` 자가 치유 블록의 판정 조건이 이 클래스와 동형이다.
     *
     * 그 블록은 부팅 전이라 `App\` 클래스를 참조할 수 없어 같은 판정을 순수 PHP 로 **복제**한다.
     * 복제본은 어긋나도 예외를 내지 않는다 — 옛 부모(7.0.9·7.0.10) 아래에서 도는 신버전 자식의
     * 유일한 방어가 조용히 사라지고, 증상은 그 조합에서만 나타나므로 개발 저장소에서는 영영
     * 드러나지 않는다. 그래서 두 조건이 같은지를 여기서 잠근다 — 종전에는 양쪽 주석의 상호
     * 참조가 유일한 방어였다.
     *
     * 대조 항목은 판정을 이루는 네 축 전부다: 환경변수 이름 · 읽는 채널 3종 · 참으로 받는 값
     * 3종 · argv 로 인정하는 커맨드 목록(리플렉션으로 이 클래스에서 파생 — 손으로 적으면
     * 커맨드가 하나 늘어도 통과한다).
     */
    #[Test]
    public function bootstrap_자가치유_조건이_이_판정기와_동형이다(): void
    {
        $bootstrap = (string) file_get_contents(base_path('bootstrap/app.php'));

        $start = strpos($bootstrap, 'Core Update: Stale Package Manifest Self-Heal');
        $this->assertNotFalse($start, '자가 치유 블록의 주석 마커를 찾지 못했다 — 마커가 바뀌었다면 이 검사부터 고친다');

        $end = strpos($bootstrap, 'return $app;', $start);
        $this->assertNotFalse($end, '자가 치유 블록의 끝(return $app;)을 찾지 못했다');

        $block = substr($bootstrap, $start, $end - $start);

        // ① 환경변수 이름 · ② 읽는 채널 3종 — CoreUpdateContext::hasEnvFlag() 와 같아야 한다.
        foreach ([
            "\$_ENV['G7_UPDATE_IN_PROGRESS']",
            "\$_SERVER['G7_UPDATE_IN_PROGRESS']",
            "getenv('G7_UPDATE_IN_PROGRESS')",
        ] as $channel) {
            $this->assertStringContainsString(
                $channel,
                $block,
                "자가 치유 블록이 판정 채널 {$channel} 을 읽지 않는다 — 그 채널만 살아 있는 호스팅에서 방어가 빠진다"
            );
        }

        // ③ 참으로 받는 값 3종.
        foreach (["=== '1'", '=== 1', '=== true'] as $accepted) {
            $this->assertStringContainsString(
                $accepted,
                $block,
                "자가 치유 블록이 플래그 값 비교 `{$accepted}` 를 갖지 않는다"
            );
        }

        // ④ argv 로 인정하는 커맨드 — 목록은 이 클래스에서 파생한다.
        $reflection = new \ReflectionClass(CoreUpdateContext::class);
        $commands = $reflection->getConstant('UPDATE_COMMANDS');

        $this->assertIsArray($commands);
        $this->assertNotEmpty($commands, '커맨드 목록이 비면 이 대조는 공허하게 통과한다');

        foreach ($commands as $command) {
            $this->assertStringContainsString(
                "'{$command}'",
                $block,
                "자가 치유 블록의 argv 판정에 `{$command}` 가 없다 — 그 커맨드로 도는 자식은 방어를 받지 못한다"
            );
        }
    }

    /**
     * 세 채널($_ENV/$_SERVER/putenv)에서 플래그를 제거합니다.
     */
    private function clearFlag(): void
    {
        unset($_ENV['G7_UPDATE_IN_PROGRESS'], $_SERVER['G7_UPDATE_IN_PROGRESS']);
        putenv('G7_UPDATE_IN_PROGRESS');
    }
}
