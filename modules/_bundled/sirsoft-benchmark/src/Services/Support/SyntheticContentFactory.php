<?php

namespace Modules\Sirsoft\Benchmark\Services\Support;

use Carbon\CarbonImmutable;

class SyntheticContentFactory
{
    private CarbonImmutable $anchor;

    public function __construct(
        private DictionaryLoader $dictionaryLoader
    ) {
        $this->anchor = CarbonImmutable::create(2025, 12, 31, 23, 59, 59, 'Asia/Seoul');
    }

    public function makePostTitle(array $boardPlan, SeededRandom $rng, int $sequence): string
    {
        $fragments = $this->dictionaryLoader->get('post_titles');
        $left = (string) $rng->pick($fragments, '운영');
        $right = (string) $rng->pick($fragments, '가이드');
        $category = $boardPlan['categories'] !== [] ? '['.$rng->pick($boardPlan['categories']).'] ' : '';

        return mb_substr($category.$left.' '.$right.' #'.($sequence + 1), 0, 190);
    }

    public function makePostContent(array $boardPlan, SeededRandom $rng): string
    {
        $sentences = $this->dictionaryLoader->get('post_sentences');
        $count = $rng->nextInt(2, 5);
        $chunks = [];

        for ($i = 0; $i < $count; $i++) {
            $chunks[] = $rng->pick($sentences, '벤치마크 데이터 문장입니다.');
        }

        $tone = $boardPlan['type'] === 'gallery'
            ? '이미지/첨부형 게시판을 가정한 더미 본문입니다.'
            : '실운영과 유사한 패턴을 위해 템플릿 조합으로 생성되었습니다.';

        return implode("\n\n", array_merge([$tone], $chunks));
    }

    public function makeCommentContent(SeededRandom $rng): string
    {
        $sentences = $this->dictionaryLoader->get('comment_sentences');
        $count = $rng->chance(0.75) ? 1 : $rng->nextInt(2, 3);
        $chunks = [];

        for ($i = 0; $i < $count; $i++) {
            $chunks[] = $rng->pick($sentences, '벤치마크 댓글입니다.');
        }

        return implode(' ', $chunks);
    }

    public function makePostTimestamp(string $distribution, SeededRandom $rng): CarbonImmutable
    {
        return match ($distribution) {
            'recent_burst' => $this->recentBurstTimestamp($rng),
            'long_span' => $this->anchor->subDays($rng->nextInt(0, 365 * 5))->subMinutes($rng->nextInt(0, 1440)),
            default => $this->anchor->subDays($rng->nextInt(0, 365 * 2))->subMinutes($rng->nextInt(0, 1440)),
        };
    }

    public function makeCommentTimestamp(\DateTimeInterface|string $postCreatedAt, SeededRandom $rng): CarbonImmutable
    {
        $base = CarbonImmutable::parse($postCreatedAt);

        return $base->addMinutes($rng->nextInt(1, 60 * 24 * 10));
    }

    private function recentBurstTimestamp(SeededRandom $rng): CarbonImmutable
    {
        if ($rng->chance(0.72)) {
            return $this->anchor->subMinutes($rng->nextInt(0, 60 * 24 * 30));
        }

        return $this->anchor->subDays($rng->nextInt(30, 365 * 3))->subMinutes($rng->nextInt(0, 720));
    }
}
