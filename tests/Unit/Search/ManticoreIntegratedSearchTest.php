<?php

namespace Tests\Unit\Search;

use App\Search\ManticoreIntegratedSearch;
use PHPUnit\Framework\TestCase;
use ReflectionMethod;

class ManticoreIntegratedSearchTest extends TestCase
{
    public function test_keyword_normalization_removes_query_operators_and_limits_tokens(): void
    {
        $client = new ManticoreIntegratedSearch;
        $method = new ReflectionMethod($client, 'normalizeKeyword');

        $normalized = $method->invoke(
            $client,
            '@title 운영 | 노트북-파우치 ! 위험 '.implode(' ', range(1, 30)),
        );

        $this->assertSame(
            'title 운영 노트북 파우치 위험 1 2 3 4 5 6 7 8 9 10 11',
            $normalized,
        );
    }

    public function test_sort_clause_is_whitelisted_per_index(): void
    {
        $client = new ManticoreIntegratedSearch;
        $method = new ReflectionMethod($client, 'orderClause');

        $this->assertSame(
            'WEIGHT() DESC, created_at DESC, id DESC',
            $method->invoke($client, 'posts', 'relevance', 'asc'),
        );
        $this->assertSame(
            'selling_price ASC, id ASC',
            $method->invoke($client, 'products', 'selling_price', 'asc'),
        );
        $this->assertSame(
            'created_at DESC, id DESC',
            $method->invoke($client, 'pages', 'not_a_column', 'desc'),
        );
    }
}
