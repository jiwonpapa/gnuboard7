<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Carbon\CarbonImmutable;
use Modules\Sirsoft\Benchmark\Models\GenerationJob;

class SyntheticProfileFactory
{
    private array $firstNames = [
        '민준', '서준', '도윤', '예준', '시우', '하준', '지호', '주원', '지후', '준우',
        '서연', '서윤', '지우', '서현', '민서', '하은', '하윤', '윤서', '지민', '지유',
        'James', 'John', 'Michael', 'David', 'William', 'Emma', 'Olivia', 'Sophia', 'Isabella', 'Mia',
    ];

    private array $lastNames = [
        '김', '이', '박', '최', '정', '강', '조', '윤', '장', '임',
        'Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis', 'Rodriguez', 'Martinez',
    ];

    public function __construct(
        private DictionaryLoader $dictionaryLoader
    ) {}

    /**
     * @return array<string, mixed>
     */
    public function buildUserRow(GenerationJob $job, int $offset, int $seed, string $passwordHash): array
    {
        $nickname = $this->nicknameForOffset($offset, $seed);
        $name = $this->nameForOffset($offset, $seed);
        $anchor = CarbonImmutable::create(2025, 1, 1, 0, 0, 0, 'Asia/Seoul');
        $verifiedAt = (($offset + $seed) % 4) === 0 ? null : $anchor->subDays(($offset % 720) + 1);
        $createdAt = $anchor->subSeconds(max(1, ($offset % 86400)));

        return [
            'uuid' => $this->uuidForOffset($job, $offset),
            'name' => $name,
            'nickname' => $nickname,
            'email' => $this->emailForOffset($job, $offset),
            'email_verified_at' => $verifiedAt,
            'password' => $passwordHash,
            'language' => (($offset + $seed) % 5) === 0 ? 'en' : 'ko',
            'is_super' => false,
            'timezone' => 'Asia/Seoul',
            'country' => 'KR',
            'status' => 'active',
            'mobile' => '010-'.str_pad((string) (($offset % 9000) + 1000), 4, '0', STR_PAD_LEFT).'-'.str_pad((string) ((($offset * 7) % 9000) + 1000), 4, '0', STR_PAD_LEFT),
            'bio' => 'Benchmark dataset user #'.($offset + 1),
            'admin_memo' => "[sirsoft-benchmark][dataset:{$job->dataset_slug}]",
            'ip_address' => $this->ipForOffset($offset, $seed),
            'remember_token' => null,
            'created_at' => $createdAt,
            'updated_at' => $createdAt,
            'last_login_at' => $verifiedAt,
        ];
    }

    public function nicknameForOffset(int $offset, int $seed): string
    {
        $nicknames = $this->dictionaryLoader->get('nicknames');
        $base = $nicknames[($offset + $seed) % max(1, count($nicknames))] ?? 'bench';

        return mb_substr($base, 0, 18).str_pad((string) ($offset + 1), 6, '0', STR_PAD_LEFT);
    }

    public function nameForOffset(int $offset, int $seed): string
    {
        $first = $this->firstNames[($offset + $seed) % count($this->firstNames)];
        $last = $this->lastNames[(($offset * 7) + $seed) % count($this->lastNames)];

        return trim($last.' '.$first);
    }

    public function emailForOffset(GenerationJob $job, int $offset): string
    {
        return "{$job->dataset_slug}.user".str_pad((string) ($offset + 1), 8, '0', STR_PAD_LEFT).'@bench.g7.local';
    }

    public function ipForOffset(int $offset, int $seed): string
    {
        return sprintf(
            '10.%d.%d.%d',
            (($seed + $offset) % 240) + 10,
            (($offset * 3) % 250) + 1,
            (($offset * 7) % 250) + 1
        );
    }

    public function datasetMarker(GenerationJob $job): string
    {
        return "[sirsoft-benchmark][dataset:{$job->dataset_slug}]";
    }

    private function uuidForOffset(GenerationJob $job, int $offset): string
    {
        $hash = md5($job->dataset_slug.'|'.$offset);
        $timeHi = substr($hash, 12, 4);
        $clockSeq = substr($hash, 16, 4);

        return sprintf(
            '%s-%s-4%s-%s%s-%s',
            substr($hash, 0, 8),
            substr($hash, 8, 4),
            substr($timeHi, 1, 3),
            dechex((hexdec(substr($clockSeq, 0, 1)) & 0x3) | 0x8),
            substr($clockSeq, 1, 3),
            substr($hash, 20, 12)
        );
    }
}
