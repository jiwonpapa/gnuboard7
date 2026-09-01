<?php

namespace App\Console\Commands;

use Illuminate\Database\Console\Seeds\SeedCommand as BaseSeedCommand;
use Illuminate\Database\Seeder;

/**
 * db:seed 커맨드 확장
 *
 * Laravel 기본 db:seed 커맨드에 --count 옵션을 추가하여
 * 시더에 데이터 개수를 전달할 수 있게 합니다.
 *
 * 사용 예시:
 * php artisan db:seed --class=SomeSeeder --count=items=50000
 */
class SeedCommand extends BaseSeedCommand
{
    /**
     * Laravel 13의 기본 SeedCommand는 getOptions() 대신 signature를 사용합니다.
     * 기본 옵션을 유지하면서 G7의 count/sample 옵션을 함께 선언합니다.
     *
     * @var string
     */
    protected $signature = 'db:seed
                    {class? : The class name of the root seeder}
                    {--class=Database\\Seeders\\DatabaseSeeder : The class name of the root seeder}
                    {--database= : The database connection to seed}
                    {--force : Force the operation to run when in production}
                    {--count=* : 시더에 전달할 카운트 옵션 (형식: key=value, 예: --count=products=1000)}
                    {--sample : 샘플 데이터 시더도 함께 실행}';

    /**
     * 시더 인스턴스를 컨테이너에서 생성합니다.
     *
     * 부모 메서드를 호출한 뒤, --count 옵션이 있으면
     * 시더에 setSeederCounts()로 전달합니다.
     *
     * @return Seeder
     */
    protected function getSeeder()
    {
        $seeder = parent::getSeeder();

        // --sample 옵션 전파
        if (method_exists($seeder, 'setIncludeSample')) {
            $seeder->setIncludeSample((bool) $this->option('sample'));
        }

        // --count 옵션 전파
        $counts = $this->parseCountOptions();
        if (! empty($counts) && method_exists($seeder, 'setSeederCounts')) {
            $seeder->setSeederCounts($counts);
        }

        return $seeder;
    }

    /**
     * --count 옵션을 파싱하여 연관 배열로 반환합니다.
     *
     * 입력: ['products=1000', 'orders=500']
     * 출력: ['products' => 1000, 'orders' => 500]
     *
     * @return array<string, int>
     */
    public function parseCountOptions(): array
    {
        $countOptions = $this->option('count');
        $counts = [];

        foreach ($countOptions as $option) {
            if (str_contains($option, '=')) {
                [$key, $value] = explode('=', $option, 2);
                $key = trim($key);
                if ($key !== '') {
                    $counts[$key] = (int) trim($value);
                }
            }
        }

        return $counts;
    }
}
