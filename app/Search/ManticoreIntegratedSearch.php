<?php

namespace App\Search;

use Illuminate\Support\Facades\Log;
use PDO;
use Throwable;

/**
 * 통합검색 전용 Manticore 읽기 클라이언트.
 *
 * 일반 게시판/관리자 검색은 기존 MySQL 경로를 유지하고, 공개 통합검색에서만
 * 현재 페이지 ID와 정확한 전체 건수를 Manticore에서 조회합니다.
 */
class ManticoreIntegratedSearch
{
    private ?PDO $connection = null;

    private bool $failureLogged = false;

    public function isEnabled(): bool
    {
        return config('scout.integrated.driver', 'mysql') === 'manticore';
    }

    /** @return array{total: int, ids: array<int, int>}|null */
    public function searchPosts(
        array $boardIds,
        string $keyword,
        string $orderBy,
        string $direction,
        int $limit,
        int $page = 1,
    ): ?array {
        $boardIds = array_values(array_unique(array_filter(
            array_map('intval', $boardIds),
            static fn (int $id): bool => $id > 0,
        )));

        if ($boardIds === []) {
            return ['total' => 0, 'ids' => []];
        }

        return $this->search(
            'posts',
            $keyword,
            'board_id IN ('.implode(',', $boardIds).')',
            $orderBy,
            $direction,
            $limit,
            max(0, ($page - 1) * $limit),
        );
    }

    public function countPosts(array $boardIds, string $keyword): ?int
    {
        $boardIds = array_values(array_unique(array_filter(
            array_map('intval', $boardIds),
            static fn (int $id): bool => $id > 0,
        )));

        if ($boardIds === []) {
            return 0;
        }

        return $this->count(
            'posts',
            $keyword,
            'board_id IN ('.implode(',', $boardIds).')',
        );
    }

    /** @return array{total: int, ids: array<int, int>}|null */
    public function searchProducts(
        string $keyword,
        string $orderBy,
        string $direction,
        ?int $categoryId,
        int $offset,
        int $limit,
    ): ?array {
        $filter = $categoryId !== null && $categoryId > 0
            ? 'ANY(category_ids) = '.(int) $categoryId
            : '';

        return $this->search(
            'products',
            $keyword,
            $filter,
            $orderBy,
            $direction,
            $limit,
            $offset,
        );
    }

    public function countProducts(string $keyword, ?int $categoryId): ?int
    {
        $filter = $categoryId !== null && $categoryId > 0
            ? 'ANY(category_ids) = '.(int) $categoryId
            : '';

        return $this->count('products', $keyword, $filter);
    }

    /** @return array{total: int, ids: array<int, int>}|null */
    public function searchPages(
        string $keyword,
        string $orderBy,
        string $direction,
        int $limit,
        int $offset = 0,
    ): ?array {
        return $this->search('pages', $keyword, '', $orderBy, $direction, $limit, $offset);
    }

    public function countPages(string $keyword): ?int
    {
        return $this->count('pages', $keyword, '');
    }

    public function isHealthy(): bool
    {
        if (! $this->isEnabled()) {
            return false;
        }

        try {
            $this->pdo()->query('SELECT 1')->fetchColumn();

            return true;
        } catch (Throwable $e) {
            $this->logFailure('health', $e);

            return false;
        }
    }

    /** @return array{total: int, ids: array<int, int>}|null */
    private function search(
        string $logicalTable,
        string $keyword,
        string $filter,
        string $orderBy,
        string $direction,
        int $limit,
        int $offset,
    ): ?array {
        if (! $this->isEnabled()) {
            return null;
        }

        $normalizedKeyword = $this->normalizeKeyword($keyword);
        if ($normalizedKeyword === '') {
            return ['total' => 0, 'ids' => []];
        }

        try {
            $pdo = $this->pdo();
            $table = $this->table($logicalTable);
            $where = 'MATCH('.$pdo->quote($normalizedKeyword).')';
            if ($filter !== '') {
                $where .= ' AND '.$filter;
            }

            $timeout = $this->maxQueryTime();
            $total = (int) $pdo->query(
                "SELECT COUNT(*) AS total FROM {$table} WHERE {$where} OPTION max_query_time={$timeout}"
            )->fetchColumn();

            $maxWindow = max(1, (int) config('scout.integrated.manticore.max_result_window', 10000));
            $offset = max(0, $offset);
            $limit = max(1, min($limit, 1000, max(1, $maxWindow - $offset)));

            if ($offset >= $maxWindow || $offset >= $total) {
                return ['total' => $total, 'ids' => []];
            }

            $order = $this->orderClause($logicalTable, $orderBy, $direction);
            $statement = $pdo->query(
                "SELECT id FROM {$table} WHERE {$where} ORDER BY {$order} "
                ."LIMIT {$offset}, {$limit} OPTION max_query_time={$timeout}"
            );

            return [
                'total' => $total,
                'ids' => array_map('intval', $statement->fetchAll(PDO::FETCH_COLUMN)),
            ];
        } catch (Throwable $e) {
            $this->logFailure($logicalTable, $e);

            return null;
        }
    }

    private function count(string $logicalTable, string $keyword, string $filter): ?int
    {
        if (! $this->isEnabled()) {
            return null;
        }

        $normalizedKeyword = $this->normalizeKeyword($keyword);
        if ($normalizedKeyword === '') {
            return 0;
        }

        try {
            $pdo = $this->pdo();
            $table = $this->table($logicalTable);
            $where = 'MATCH('.$pdo->quote($normalizedKeyword).')';
            if ($filter !== '') {
                $where .= ' AND '.$filter;
            }

            return (int) $pdo->query(
                "SELECT COUNT(*) AS total FROM {$table} WHERE {$where} "
                .'OPTION max_query_time='.$this->maxQueryTime()
            )->fetchColumn();
        } catch (Throwable $e) {
            $this->logFailure($logicalTable, $e);

            return null;
        }
    }

    private function pdo(): PDO
    {
        if ($this->connection instanceof PDO) {
            return $this->connection;
        }

        $host = (string) config('scout.integrated.manticore.host', '127.0.0.1');
        $port = (int) config('scout.integrated.manticore.port', 9306);
        $timeout = max(1, (int) config('scout.integrated.manticore.connect_timeout', 1));

        $this->connection = new PDO(
            "mysql:host={$host};port={$port}",
            null,
            null,
            [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
                PDO::ATTR_TIMEOUT => $timeout,
                PDO::ATTR_EMULATE_PREPARES => true,
            ],
        );

        return $this->connection;
    }

    private function table(string $logicalTable): string
    {
        $table = (string) config("scout.integrated.manticore.tables.{$logicalTable}", '');
        if ($table === '' || preg_match('/^[A-Za-z0-9_]+$/', $table) !== 1) {
            throw new \RuntimeException("Invalid Manticore table for {$logicalTable}");
        }

        return $table;
    }

    private function normalizeKeyword(string $keyword): string
    {
        preg_match_all('/[\p{L}\p{N}_]+/u', mb_substr(trim($keyword), 0, 100), $matches);

        return implode(' ', array_slice($matches[0] ?? [], 0, 16));
    }

    private function maxQueryTime(): int
    {
        return max(50, min(10000, (int) config('scout.integrated.manticore.query_timeout_ms', 2000)));
    }

    private function orderClause(string $logicalTable, string $orderBy, string $direction): string
    {
        $allowed = match ($logicalTable) {
            'posts' => ['created_at', 'view_count', 'comments_count'],
            'products' => ['created_at', 'selling_price'],
            'pages' => ['created_at'],
            default => [],
        };
        $direction = strtolower($direction) === 'asc' ? 'ASC' : 'DESC';

        if ($orderBy === 'relevance') {
            return 'WEIGHT() DESC, created_at DESC, id DESC';
        }

        $column = in_array($orderBy, $allowed, true) ? $orderBy : 'created_at';

        return "{$column} {$direction}, id {$direction}";
    }

    private function logFailure(string $logicalTable, Throwable $e): void
    {
        if ($this->failureLogged) {
            return;
        }

        $this->failureLogged = true;
        Log::warning('Manticore integrated search unavailable; falling back to MySQL', [
            'table' => $logicalTable,
            'error' => mb_substr($e->getMessage(), 0, 300),
        ]);
    }
}
