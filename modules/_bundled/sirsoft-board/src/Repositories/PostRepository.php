<?php

namespace Modules\Sirsoft\Board\Repositories;

use App\Contracts\Extension\CacheInterface;
use App\Enums\PermissionType;
use App\Helpers\PermissionHelper;
use App\Search\Engines\DatabaseFulltextEngine;
use Carbon\CarbonImmutable;
use Illuminate\Contracts\Pagination\Paginator;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\ModelNotFoundException;
use Illuminate\Database\QueryException;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Modules\Sirsoft\Board\Enums\PostStatus;
use Modules\Sirsoft\Board\Enums\TriggerType;
use Modules\Sirsoft\Board\Models\Attachment;
use Modules\Sirsoft\Board\Models\Board;
use Modules\Sirsoft\Board\Models\Comment;
use Modules\Sirsoft\Board\Models\Post;
use Modules\Sirsoft\Board\Repositories\Contracts\PostRepositoryInterface;
use Modules\Sirsoft\Board\Traits\ChecksBoardPermission;
use Modules\Sirsoft\Board\Traits\FormatsBoardDate;
use Symfony\Component\HttpKernel\Exception\TooManyRequestsHttpException;

/**
 * 게시글 Repository
 *
 * 게시글 데이터 접근 계층을 담당합니다.
 */
class PostRepository implements PostRepositoryInterface
{
    use ChecksBoardPermission;
    use FormatsBoardDate;

    /** 검색 window total을 Controller까지 전달하는 내부 모델 속성 */
    private const INTERNAL_TOTAL_ATTRIBUTE = '__g7_normal_posts_total';

    /** 검색 total이 정확한 값인지 전달하는 내부 모델 속성 */
    private const INTERNAL_TOTAL_EXACT_ATTRIBUTE = '__g7_normal_posts_total_is_exact';

    /** 검색 total의 의미(eq/gte/unknown)를 전달하는 내부 모델 속성 */
    private const INTERNAL_TOTAL_RELATION_ATTRIBUTE = '__g7_normal_posts_total_relation';

    /** 작성자 검색 사전 존재 여부를 요청 안에서 재사용합니다. */
    private ?bool $authorTermsAvailable = null;

    /** 첫 페이지에 함께 노출할 공지글 최대 수 */
    private const MAX_NOTICE_POSTS = 10;

    /** 한 페이지에서 본문과 함께 펼칠 답글 최대 수 */
    private const MAX_INLINE_REPLIES = 100;

    /** 메모리 상한을 넘긴 FULLTEXT 키워드의 재시도 억제 시간 */
    private const BROAD_FULLTEXT_CACHE_TTL_SECONDS = 600;

    /**
     * PostRepository 생성자
     */
    public function __construct(private readonly CacheInterface $cache) {}

    /**
     * 게시판의 게시글 목록을 페이지네이션하여 조회합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  array  $filters  필터 조건
     * @param  int  $perPage  페이지당 항목 수 (일반 게시글 기준)
     * @param  bool  $withTrashed  삭제된 게시글 포함 여부
     * @return Paginator 페이지네이션된 게시글 목록 (simplePaginate — COUNT 쿼리 제거)
     */
    public function paginate(string $slug, array $filters = [], int $perPage = 15, bool $withTrashed = false, ?Board $board = null): Paginator
    {
        $currentPage = $filters['page'] ?? request()->input('page', 1);

        // 목록 전용 컬럼: content(본문 HTML) 제외 → content_preview로 대체
        $listColumns = [
            'id', 'board_id', 'user_id', 'parent_id', 'category',
            'title', 'author_name', 'content_mode',
            'is_notice', 'is_secret', 'status', 'depth',
            'view_count', 'comments_count', 'replies_count', 'attachments_count',
            'trigger_type', 'ip_address', 'created_at', 'updated_at', 'deleted_at',
            DB::raw('SUBSTRING(content, 1, 200) as content_preview_raw'),
        ];

        // buildSortedPostList를 사용하여 페이지네이션된 목록 조회
        // attachments, board 제거 — 목록에서는 has_attachment(attachments_count) 사용, board는 Controller에서 전달
        $query = fn () => $this->buildSortedPostList(
            slug: $slug,
            columns: $listColumns,
            withTrashed: $withTrashed,
            relations: ['user', 'user.avatarAttachment', 'thumbnailAttachment'],
            withCount: [],
            filters: $filters,
            perPage: $perPage,
            currentPage: $currentPage,
            board: $board,
        );

        return ! empty($filters['search'])
            ? $this->withSearchConcurrencyGuard($query)
            : $query();
    }

    /**
     * MySQL 서버 한 대에서 무거운 게시판 검색을 한 번만 실행합니다.
     *
     * 대기 시간이 0인 advisory lock이므로 중복 검색은 DB 자원을 기다리며 쌓이지
     * 않고 즉시 429 성격으로 실패합니다. SQLite 등 테스트 DB에서는 no-op입니다.
     */
    private function withSearchConcurrencyGuard(callable $callback): mixed
    {
        if (DB::getDriverName() !== 'mysql') {
            return $callback();
        }

        $lockName = 'g7:board-search:sync';
        $result = DB::selectOne('SELECT GET_LOCK(?, 0) AS acquired', [$lockName]);
        if ((int) ($result->acquired ?? 0) !== 1) {
            throw new TooManyRequestsHttpException(1, __('errors.503.message'));
        }

        try {
            return $callback();
        } finally {
            try {
                DB::selectOne('SELECT RELEASE_LOCK(?) AS released', [$lockName]);
            } catch (\Throwable) {
                // 연결 장애로 인한 해제 실패가 원래 검색 예외를 덮지 않게 합니다.
                // MySQL named lock은 해당 연결이 끊기면 자동 해제됩니다.
            }
        }
    }

    /**
     * 쿼리에 필터를 적용합니다.
     *
     * @param  Builder  $query  쿼리 빌더
     * @param  array  $filters  필터 조건
     */
    private function applyFilters($query, array $filters): void
    {
        // 상태 필터
        if (! empty($filters['status'])) {
            if ($filters['status'] === 'secret') {
                // 비밀글 필터
                $query->where('is_secret', true);
            } else {
                // 일반 상태 필터 (published, blinded, deleted)
                $query->where('status', $filters['status']);
            }
        }

        // 분류 필터
        if (isset($filters['category']) && $filters['category'] !== '' && $filters['category'] !== null) {
            if ($filters['category'] === 'unclassified') {
                // 미분류: category가 NULL/빈 문자열이거나, 게시판 설정에 등록되지 않은 분류
                $boardCategories = $filters['board_categories'] ?? [];
                $query->where(function ($q) use ($boardCategories) {
                    $q->whereNull('category')->orWhere('category', '');
                    if (! empty($boardCategories)) {
                        $q->orWhereNotIn('category', $boardCategories);
                    }
                });
            } else {
                $query->where('category', $filters['category']);
            }
        }

        // 공지사항 필터
        if (isset($filters['is_notice'])) {
            $query->where('is_notice', $filters['is_notice']);
        }

        // 작성자 필터
        if (! empty($filters['user_id'])) {
            $query->where('user_id', $filters['user_id']);
        }

        // 작성일 필터 (시작일~종료일, 시작일~, ~종료일 모두 가능)
        if (! empty($filters['created_at_from']) && $filters['created_at_from'] !== '') {
            // 시작일 00:00:00부터 검색
            $query->where('created_at', '>=', $filters['created_at_from'].' 00:00:00');
        }

        if (! empty($filters['created_at_to']) && $filters['created_at_to'] !== '') {
            // 종료일 23:59:59까지 검색
            $query->where('created_at', '<=', $filters['created_at_to'].' 23:59:59');
        }

        // optimized ID branch가 나머지 필터를 포함하도록 검색은 마지막에 적용한다.
        if (! empty($filters['search'])) {
            $this->applySearchFilter(
                $query,
                $filters['search'],
                $filters['search_field'] ?? 'all'
            );
        }
    }

    /**
     * 게시글 검색 조건을 적용합니다.
     *
     * baseline은 기존 OR 쿼리를 보존하고, optimized all 검색은 FULLTEXT,
     * 작성자 스냅샷, 회원 정보 매칭을 별도 ID 집합으로 분리합니다.
     */
    private function applySearchFilter(Builder $query, string $search, string $searchField): void
    {
        $keyword = $this->escapeLikeKeyword($search);

        if (
            $searchField === 'all'
            && config('benchmark.board_list_variant', 'optimized') === 'optimized'
        ) {
            $this->applyOptimizedAllSearch($query, $search, $keyword);

            return;
        }

        // G7 7.0.4 기준 경로. baseline A/B 비교와 개별 search_field 계약을 보존한다.
        $query->where(function ($q) use ($keyword, $searchField) {
            if ($searchField === 'all' || $searchField === 'title_content') {
                if (DatabaseFulltextEngine::supportsFulltext()) {
                    $q->orWhereRaw('MATCH(`title`, `content`) AGAINST(? IN BOOLEAN MODE)', [$keyword]);
                } else {
                    $q->orWhere('title', 'like', "%{$keyword}%")
                        ->orWhere('content', 'like', "%{$keyword}%");
                }
            }

            if ($searchField === 'all' || $searchField === 'author' || $searchField === 'author_name') {
                $q->orWhere('author_name', 'like', "%{$keyword}%")
                    ->orWhereHas('user', function ($uq) use ($keyword) {
                        $uq->where('name', 'like', "%{$keyword}%")
                            ->orWhere('email', 'like', "%{$keyword}%");
                    });
            }
        });
    }

    /**
     * all 검색을 인덱스 가능한 ID UNION 서브쿼리로 변환합니다.
     */
    private function applyOptimizedAllSearch(Builder $query, string $search, string $likeKeyword): void
    {
        // 게시판/공지/원글/권한/삭제 및 필터 조건을 각 branch에 복제해 스캔을 줄인다.
        $fulltextIds = (clone $query)->select('board_posts.id as matched_post_id');
        if (DatabaseFulltextEngine::supportsFulltext()) {
            $fulltextKeyword = $this->sanitizeOptimizedBooleanKeyword($search);
            if ($fulltextKeyword === '') {
                $fulltextIds->whereRaw('1 = 0');
            } else {
                $fulltextIds->whereRaw(
                    'MATCH(`title`, `content`) AGAINST(? IN BOOLEAN MODE)',
                    [$fulltextKeyword]
                );
            }
        } else {
            $fulltextIds->where(function ($q) use ($likeKeyword) {
                $q->where('title', 'like', "%{$likeKeyword}%")
                    ->orWhere('content', 'like', "%{$likeKeyword}%");
            });
        }

        if ($this->hasAuthorTermsTable()) {
            // 게시글 전체가 아니라 게시판별 고유 작성자명만 부분검색하고,
            // 매칭된 이름을 기존 (board_id, author_name) 인덱스로 equality join한다.
            // 컬럼을 별칭 처리해 원본 쿼리의 board_id 조건과 모호해지지 않게 한다.
            $matchingAuthorTerms = DB::table('board_post_author_terms')
                ->select([
                    'board_id as matched_board_id',
                    'author_name as matched_author_name',
                ])
                ->where('author_name', 'like', "%{$likeKeyword}%");
            $authorNameIds = (clone $query)
                ->select('board_posts.id as matched_post_id')
                ->joinSub($matchingAuthorTerms, 'board_search_author_terms', function ($join) {
                    $join->on('board_search_author_terms.matched_board_id', '=', 'board_posts.board_id')
                        ->on('board_search_author_terms.matched_author_name', '=', 'board_posts.author_name');
                });
        } else {
            // 마이그레이션 전·정확 복구 상태에서는 기존 의미를 보존합니다.
            $authorNameIds = (clone $query)
                ->select('board_posts.id as matched_post_id')
                ->where('author_name', 'like', "%{$likeKeyword}%");
        }

        // 회원을 먼저 선별한 뒤 board_posts.user_id 인덱스로 연결해
        // 대량 게시글 각 행의 상관 EXISTS 반복을 피한다.
        $matchingUserIds = DB::table('users')
            ->select('users.id as matched_user_id')
            ->where(function ($users) use ($likeKeyword) {
                $users->where('name', 'like', "%{$likeKeyword}%")
                    ->orWhere('email', 'like', "%{$likeKeyword}%");
            })
            ->distinct();

        $eligibleUserPosts = (clone $query)->select([
            'board_posts.id as matched_post_id',
            'board_posts.user_id as matched_user_id',
        ]);
        // 작성자 회원 집합과 조회 대상 게시글을 각각 derived table로 유지한다.
        // JOIN_ORDER 같은 강제 힌트는 실제 MySQL EXPLAIN으로 효과를 확인하기 전에는 사용하지 않는다.
        $userIds = DB::query()
            ->fromSub($matchingUserIds, 'board_search_users')
            ->select('board_search_user_posts.matched_post_id')
            ->joinSub(
                query: $eligibleUserPosts,
                as: 'board_search_user_posts',
                first: function ($join) {
                    $join->on(
                        'board_search_user_posts.matched_user_id',
                        '=',
                        'board_search_users.matched_user_id'
                    );
                }
            );

        // derived UNION을 먼저 materialize한 후 outer list와 조인한다.
        // WHERE IN + UNION은 MySQL이 outer 행마다 DEPENDENT SUBQUERY로 변환할 수 있어
        // FULLTEXT branch조차 PK eq_ref로 평가되므로 사용하지 않는다.
        // UNION(distinct)으로 여러 branch에 동시 매칭된 ID 중복을 제거해 목록 중복을 막는다.
        $matchingIds = $fulltextIds
            ->union($authorNameIds)
            ->union($userIds);

        $query->joinSub($matchingIds, 'board_search_matches', function ($join) {
            $join->on('board_posts.id', '=', 'board_search_matches.matched_post_id');
        });
    }

    /**
     * 작성자 검색 사전 테이블이 준비됐는지 확인합니다.
     */
    private function hasAuthorTermsTable(): bool
    {
        return $this->authorTermsAvailable ??= Schema::hasTable('board_post_author_terms');
    }

    /**
     * 동기 검색이 확인할 최대 후보 수입니다.
     *
     * cap + 1건을 조회해야 total이 하한값인지 정확한 값인지 구분할 수 있습니다.
     */
    private function searchCandidateLimit(): int
    {
        return max(10, (int) config('benchmark.board_search_sync_cap', 1000)) + 1;
    }

    /**
     * optimized 게시판 검색용 BOOLEAN MODE 토큰 정제입니다.
     *
     * 공용 sanitizer의 토큰별 exact phrase는 대량 인덱스에서 FULLTEXT
     * initialization을 길게 만들 수 있어 연산자만 제거하고 일반 토큰으로 검색합니다.
     */
    private function sanitizeOptimizedBooleanKeyword(string $keyword): string
    {
        $cleaned = preg_replace('/[+\-<>()~*"@]/u', ' ', $keyword);
        $cleaned = preg_replace('/[\x00-\x1F\x7F]/u', ' ', (string) $cleaned);
        $tokens = preg_split('/\s+/u', trim((string) $cleaned), -1, PREG_SPLIT_NO_EMPTY);

        return empty($tokens) ? '' : implode(' ', $tokens);
    }

    /** FULLTEXT 메모리 차단 시 확인할 최근 게시글 수입니다. */
    private function searchFallbackScanCap(): int
    {
        return max(100, min(5000, (int) config('benchmark.board_search_fallback_scan_cap', 1000)));
    }

    /** 동일한 광범위 FULLTEXT 검색의 반복 실행을 막는 캐시 키입니다. */
    private function broadFulltextCacheKey(string $keyword): string
    {
        $normalized = mb_strtolower(trim((string) preg_replace('/\s+/u', ' ', $keyword)));

        return 'search:fts-result-cache-limit:'.hash('sha256', $normalized);
    }

    private function shouldBypassFulltext(string $keyword): bool
    {
        try {
            return (bool) $this->cache->get($this->broadFulltextCacheKey($keyword), false);
        } catch (\Throwable) {
            // 캐시 장애가 검색 자체를 막지 않게 하며 DB 안전장치는 계속 적용됩니다.
            return false;
        }
    }

    private function rememberBroadFulltext(string $keyword): void
    {
        try {
            $this->cache->put(
                $this->broadFulltextCacheKey($keyword),
                true,
                self::BROAD_FULLTEXT_CACHE_TTL_SECONDS
            );
        } catch (\Throwable) {
            // 캐시 실패 시에도 현재 요청은 제한형 fallback으로 복구합니다.
        }
    }

    /** MySQL InnoDB FULLTEXT 결과 캐시 상한 오류인지 판별합니다. */
    private function isFulltextResultCacheLimitExceeded(QueryException $exception): bool
    {
        $driverError = is_array($exception->errorInfo ?? null)
            ? (int) ($exception->errorInfo[1] ?? 0)
            : 0;

        return $driverError === 188
            || str_contains(strtolower($exception->getMessage()), 'fts query exceeds result cache limit');
    }

    /**
     * 최근 eligible ID를 먼저 고정한 뒤 그 범위 안에서만 LIKE를 수행합니다.
     *
     * ID 조회와 본문 검색을 두 쿼리로 분리해 optimizer의 join 순서와 무관하게
     * LIKE 대상 행 수를 고정합니다. 결과는 완전 검색이 아닌 제한형 하한값입니다.
     */
    private function buildBoundedSearchFallbackQuery(Builder $baseQuery, string $keyword): Builder
    {
        $recentIds = (clone $baseQuery)
            ->reorder()
            ->orderBy('board_posts.id', 'desc')
            ->limit($this->searchFallbackScanCap())
            ->pluck('board_posts.id')
            ->map(static fn ($id) => (int) $id)
            ->all();
        $escapedKeyword = $this->escapeLikeKeyword($keyword);

        return (clone $baseQuery)
            ->reorder()
            ->forceIndex('PRIMARY')
            ->whereIntegerInRaw('board_posts.id', $recentIds)
            ->where(function ($query) use ($escapedKeyword) {
                $query->where('board_posts.title', 'like', "%{$escapedKeyword}%")
                    ->orWhere('board_posts.content', 'like', "%{$escapedKeyword}%");
            });
    }

    /**
     * 선택된 검색 채널을 각각 제한한 뒤 ID 후보만 병합합니다.
     *
     * FULLTEXT/작성자명/회원 검색을 UNION derived table 하나로 합치면 MySQL이
     * outer LIMIT 전에 전체 ID를 materialize할 수 있습니다. 각 branch 내부에
     * LIMIT을 먼저 적용하면 한 요청이 만들 수 있는 후보와 임시 테이블 크기가
     * 명시적으로 제한됩니다.
     *
     * @return array{candidates: Collection<int, Post>, total_is_exact: bool, branch_reached_limit: bool, fallback_used: bool}
     */
    private function fetchOptimizedSearchCandidates(
        Builder $baseQuery,
        string $search,
        string $searchField,
        string $likeKeyword,
        string $orderBy,
        string $orderDirection,
        int $limit
    ): array {
        $limit = max(1, min($limit, $this->searchCandidateLimit()));
        if (! in_array($searchField, ['all', 'title_content', 'author', 'author_name'], true)) {
            $searchField = 'all';
        }
        $branches = [];

        if (in_array($searchField, ['all', 'title_content'], true)) {
            $fulltextSupported = DatabaseFulltextEngine::supportsFulltext();
            $bypassFulltext = $fulltextSupported && $this->shouldBypassFulltext($search);
            $fulltext = $bypassFulltext
                ? $this->buildBoundedSearchFallbackQuery($baseQuery, $search)
                : clone $baseQuery;
            if ($fulltextSupported && ! $bypassFulltext) {
                $fulltextKeyword = $this->sanitizeOptimizedBooleanKeyword($search);
                $fulltext->whereRaw(
                    $fulltextKeyword === ''
                        ? '1 = 0'
                        : 'MATCH(`title`, `content`) AGAINST(? IN BOOLEAN MODE)',
                    $fulltextKeyword === '' ? [] : [$fulltextKeyword]
                );
            } elseif (! $fulltextSupported) {
                $fulltext->where(function ($query) use ($likeKeyword) {
                    $query->where('title', 'like', "%{$likeKeyword}%")
                        ->orWhere('content', 'like', "%{$likeKeyword}%");
                });
            }
            // FULLTEXT 전체 결과를 created_at 등으로 먼저 정렬하면 LIMIT 전 대량 filesort가
            // 발생할 수 있으므로 엔진이 반환하는 후보를 먼저 제한하고 아래에서 정렬합니다.
            $branches[] = [
                'query' => $fulltext,
                'order_by_id' => $bypassFulltext,
                'fallback_base' => $fulltextSupported && ! $bypassFulltext ? clone $baseQuery : null,
                'fallback_used' => $bypassFulltext,
            ];
        }

        if (in_array($searchField, ['all', 'author', 'author_name'], true)) {
            if ($this->hasAuthorTermsTable()) {
                // 작성자 사전 자체도 제한해 `%keyword%`가 사전 전체를 materialize하지 않게 합니다.
                $matchingAuthorTerms = DB::table('board_post_author_terms')
                    ->select([
                        'board_id as matched_board_id',
                        'author_name as matched_author_name',
                    ])
                    ->where('author_name', 'like', "%{$likeKeyword}%")
                    ->orderBy('board_id')
                    ->orderBy('author_name')
                    ->limit($limit);
                $authorNames = (clone $baseQuery)
                    ->joinSub($matchingAuthorTerms, 'board_search_author_terms', function ($join) {
                        $join->on('board_search_author_terms.matched_board_id', '=', 'board_posts.board_id')
                            ->on('board_search_author_terms.matched_author_name', '=', 'board_posts.author_name');
                    });
            } else {
                $authorNames = (clone $baseQuery)
                    ->where('author_name', 'like', "%{$likeKeyword}%");
            }
            $branches[] = ['query' => $authorNames, 'order_by_id' => true];

            $matchingUserIds = DB::table('users')
                ->select('users.id')
                ->where(function ($users) use ($likeKeyword) {
                    $users->where('name', 'like', "%{$likeKeyword}%")
                        ->orWhere('email', 'like', "%{$likeKeyword}%");
                })
                ->orderBy('users.id')
                ->limit($limit)
                ->pluck('users.id')
                ->map(static fn ($id) => (int) $id)
                ->all();
            $branches[] = [
                // MySQL은 LIMIT이 있는 IN subquery를 지원하지 않는 버전이 있으므로
                // 제한된 회원 ID를 먼저 materialize한 뒤 정수 IN 목록으로 조회합니다.
                'query' => (clone $baseQuery)->whereIntegerInRaw('board_posts.user_id', $matchingUserIds),
                'order_by_id' => true,
            ];
        }

        $selectColumns = ['board_posts.id'];
        if ($orderBy !== 'id') {
            $selectColumns[] = "board_posts.{$orderBy}";
        }

        $candidates = collect();
        $branchReachedLimit = false;
        $fallbackUsed = false;
        foreach ($branches as $branchConfig) {
            /** @var Builder $branch */
            $branch = $branchConfig['query']->reorder();
            if ($branchConfig['order_by_id']) {
                $branch->orderBy('board_posts.id', $orderDirection);
            }
            try {
                $rows = $branch->limit($limit)->get($selectColumns);
            } catch (QueryException $exception) {
                if (! ($branchConfig['fallback_base'] ?? null)
                    || ! $this->isFulltextResultCacheLimitExceeded($exception)) {
                    throw $exception;
                }

                $this->rememberBroadFulltext($search);
                $fallbackUsed = true;
                $branch = $this->buildBoundedSearchFallbackQuery(
                    $branchConfig['fallback_base'],
                    $search
                );
                $rows = $branch
                    ->orderBy('board_posts.id', $orderDirection)
                    ->limit($limit)
                    ->get($selectColumns);
            }

            $fallbackUsed = $fallbackUsed || ($branchConfig['fallback_used'] ?? false);
            $branchReachedLimit = $branchReachedLimit || $rows->count() === $limit;
            foreach ($rows as $row) {
                $candidates->put((int) $row->id, $row);
            }
        }

        $directionMultiplier = $orderDirection === 'desc' ? -1 : 1;
        $candidates = $candidates->sort(function (Post $left, Post $right) use ($orderBy, $directionMultiplier) {
            $leftValue = $left->getRawOriginal($orderBy);
            $rightValue = $right->getRawOriginal($orderBy);
            $comparison = is_numeric($leftValue) && is_numeric($rightValue)
                ? ((float) $leftValue <=> (float) $rightValue)
                : strcmp((string) $leftValue, (string) $rightValue);

            if ($comparison === 0) {
                $comparison = (int) $left->id <=> (int) $right->id;
            }

            return $comparison * $directionMultiplier;
        })->values();

        return [
            'candidates' => $candidates,
            // 작성자/회원 사전은 의도적으로 제한하므로 해당 검색 total은 보수적으로 하한값입니다.
            'total_is_exact' => $searchField === 'title_content'
                && ! $branchReachedLimit
                && ! $fallbackUsed,
            'branch_reached_limit' => $branchReachedLimit,
            'fallback_used' => $fallbackUsed,
        ];
    }

    /**
     * 검색 메타를 빈 결과에서도 잃지 않는 simple paginator를 생성합니다.
     *
     * @param  array{total: int, total_is_exact: bool, total_relation: string, fallback_used: bool}  $metadata
     */
    private function makeBoundedSearchPaginator(
        Collection $items,
        int $perPage,
        int $currentPage,
        array $metadata
    ): Paginator {
        return new class($items, $perPage, $currentPage, $metadata) extends \Illuminate\Pagination\Paginator
        {
            /** @param  array<string, mixed>  $searchMetadata */
            public function __construct(
                $items,
                int $perPage,
                int $currentPage,
                private readonly array $searchMetadata
            ) {
                parent::__construct($items, $perPage, $currentPage, [
                    'path' => self::resolveCurrentPath(),
                    'pageName' => 'page',
                ]);
            }

            /** @return array<string, mixed> */
            public function searchMetadata(): array
            {
                return $this->searchMetadata;
            }
        };
    }

    /**
     * 제한된 후보에서 simple paginator와 검색 total 메타를 만듭니다.
     *
     * @return array{paginator: \Illuminate\Pagination\Paginator, total: int, total_is_exact: bool, total_relation: string}
     */
    private function paginateOptimizedSearch(
        Builder $baseQuery,
        string $search,
        string $searchField,
        string $orderBy,
        string $orderDirection,
        int $perPage,
        int $currentPage
    ): array {
        $offset = max(0, ($currentPage - 1) * $perPage);
        $resultCap = $this->searchCandidateLimit() - 1;
        if ($offset >= $resultCap) {
            $paginator = $this->makeBoundedSearchPaginator(
                collect(),
                $perPage,
                $currentPage,
                [
                    'total' => $resultCap,
                    'total_is_exact' => false,
                    'total_relation' => 'gte',
                    'fallback_used' => false,
                ]
            );
            $paginator->hasMorePagesWhen(false);

            return [
                'paginator' => $paginator,
                'total' => $resultCap,
                'total_is_exact' => false,
                'total_relation' => 'gte',
            ];
        }

        $requestedCandidates = $offset + $perPage + 1;
        $result = $this->fetchOptimizedSearchCandidates(
            $baseQuery,
            $search,
            $searchField,
            $this->escapeLikeKeyword($search),
            $orderBy,
            $orderDirection,
            $requestedCandidates
        );

        $allCandidates = $result['candidates']->take($resultCap)->values();
        $pageCandidates = $allCandidates->slice($offset, $perPage + 1)->values();
        $paginator = $this->makeBoundedSearchPaginator(
            $pageCandidates,
            $perPage,
            $currentPage,
            [
                'total' => $allCandidates->count(),
                'total_is_exact' => $result['total_is_exact'],
                'total_relation' => $result['total_is_exact'] ? 'eq' : 'gte',
                'fallback_used' => $result['fallback_used'],
            ]
        );
        $paginator->hasMorePagesWhen(
            $allCandidates->count() > $offset + $perPage
            || ($result['branch_reached_limit'] && $offset + $perPage < $resultCap)
        );

        return [
            'paginator' => $paginator,
            'total' => $allCandidates->count(),
            'total_is_exact' => $result['total_is_exact'],
            'total_relation' => $result['total_is_exact'] ? 'eq' : 'gte',
        ];
    }

    /**
     * exact COUNT 대신 cap + 1건만 세어 정확값 또는 하한값을 반환합니다.
     *
     * @return array{total: int, total_is_exact: bool, total_relation: string, result_cap: int, search_truncated: bool}
     */
    private function boundedSearchCount(
        Builder $query,
        Builder $fallbackBaseQuery,
        string $keyword
    ): array {
        $candidateLimit = $this->searchCandidateLimit();
        $fulltextSupported = DatabaseFulltextEngine::supportsFulltext();
        $fallbackUsed = $fulltextSupported && $this->shouldBypassFulltext($keyword);
        if ($fallbackUsed) {
            $query = $this->buildBoundedSearchFallbackQuery($fallbackBaseQuery, $keyword);
        }

        $countCandidates = static function (Builder $source) use ($candidateLimit): int {
            $boundedIds = (clone $source)
                ->reorder()
                ->select('board_posts.id')
                ->limit($candidateLimit);

            return (int) DB::query()
                ->fromSub($boundedIds, 'bounded_board_search')
                ->count();
        };

        try {
            $total = $countCandidates($query);
        } catch (QueryException $exception) {
            if (! $fulltextSupported || ! $this->isFulltextResultCacheLimitExceeded($exception)) {
                throw $exception;
            }

            $this->rememberBroadFulltext($keyword);
            $fallbackUsed = true;
            $query = $this->buildBoundedSearchFallbackQuery($fallbackBaseQuery, $keyword);
            $total = $countCandidates($query);
        }

        $isExact = ! $fallbackUsed && $total < $candidateLimit;
        $resultCap = $candidateLimit - 1;

        return [
            'total' => min($total, $resultCap),
            'total_is_exact' => $isExact,
            'total_relation' => $isExact ? 'eq' : 'gte',
            'result_cap' => $resultCap,
            'search_truncated' => $fallbackUsed,
        ];
    }

    /**
     * 공개 검색 결과를 ID-first + limit 방식으로 조회합니다.
     *
     * 첫 쿼리는 정렬에 필요한 컬럼과 ID만 cap 안에서 읽고, LONGTEXT 본문과 관계는
     * 실제 응답 페이지 ID에 한해서만 hydrate합니다.
     *
     * @param  array<int, string>  $relations
     * @return array{total: int, total_is_exact: bool, total_relation: string, has_more_pages: bool, result_cap: int, search_truncated: bool, items: \Illuminate\Database\Eloquent\Collection}
     */
    private function boundedPublicSearchPage(
        Builder $query,
        Builder $fallbackBaseQuery,
        array $relations,
        string $keyword,
        string $orderBy,
        string $direction,
        int $perPage,
        int $page
    ): array {
        $allowedOrderColumns = ['id', 'created_at', 'view_count', 'relevance'];
        $orderBy = in_array($orderBy, $allowedOrderColumns, true) ? $orderBy : 'created_at';
        $direction = strtolower($direction) === 'asc' ? 'asc' : 'desc';
        $perPage = max(1, $perPage);
        $page = max(1, $page);
        $offset = ($page - 1) * $perPage;
        $resultCap = $this->searchCandidateLimit() - 1;
        $candidateLimit = min($offset + $perPage + 1, $resultCap + 1);

        $fulltextSupported = DatabaseFulltextEngine::supportsFulltext();
        $fallbackUsed = $fulltextSupported && $this->shouldBypassFulltext($keyword);
        if ($fallbackUsed) {
            $query = $this->buildBoundedSearchFallbackQuery($fallbackBaseQuery, $keyword);
        }

        $fetchCandidates = function (Builder $source, bool $useFulltextRelevance) use (
            $orderBy,
            $direction,
            $keyword,
            $candidateLimit
        ): Collection {
            $candidateQuery = (clone $source)->reorder()->select('board_posts.id');
            if ($orderBy === 'relevance' && $useFulltextRelevance) {
                $fulltextKeyword = $this->sanitizeOptimizedBooleanKeyword($keyword);
                $candidateQuery
                    ->selectRaw(
                        'MATCH(`title`, `content`) AGAINST(? IN BOOLEAN MODE) AS search_relevance',
                        [$fulltextKeyword]
                    )
                    ->orderBy('search_relevance', 'desc');
            } else {
                $resolvedOrderBy = $orderBy === 'relevance' ? 'created_at' : $orderBy;
                if ($resolvedOrderBy !== 'id') {
                    $candidateQuery->addSelect("board_posts.{$resolvedOrderBy}");
                }
                $candidateQuery->orderBy("board_posts.{$resolvedOrderBy}", $direction);
            }

            return $candidateQuery
                ->orderBy('board_posts.id', $direction)
                ->limit($candidateLimit)
                ->get();
        };

        try {
            $candidates = $fetchCandidates($query, $fulltextSupported && ! $fallbackUsed);
        } catch (QueryException $exception) {
            if (! $fulltextSupported || ! $this->isFulltextResultCacheLimitExceeded($exception)) {
                throw $exception;
            }

            $this->rememberBroadFulltext($keyword);
            $fallbackUsed = true;
            $query = $this->buildBoundedSearchFallbackQuery($fallbackBaseQuery, $keyword);
            $candidates = $fetchCandidates($query, false);
        }

        $totalIsExact = ! $fallbackUsed && $candidates->count() < $candidateLimit;
        $exposedCandidates = $candidates->take($resultCap);
        $ids = $exposedCandidates->slice($offset, $perPage)->pluck('id')->map(fn ($id) => (int) $id)->all();
        $itemsById = empty($ids)
            ? (new Post)->newCollection()
            : Post::query()->whereIn('id', $ids)->with($relations)->get()->keyBy('id');
        $items = (new Post)->newCollection(
            collect($ids)->map(fn (int $id) => $itemsById->get($id))->filter()->all()
        );
        $hasMorePages = $exposedCandidates->count() > $offset + $perPage;

        return [
            'total' => min($candidates->count(), $resultCap),
            'total_is_exact' => $totalIsExact,
            'total_relation' => $totalIsExact ? 'eq' : 'gte',
            'has_more_pages' => $hasMorePages,
            'result_cap' => $resultCap,
            'search_truncated' => $fallbackUsed,
            'items' => $items,
        ];
    }

    /**
     * 게시글을 생성합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  array  $data  게시글 생성 데이터
     * @return Post 생성된 게시글 모델
     */
    public function create(string $slug, array $data): Post
    {
        return Post::create($data);
    }

    /**
     * ID로 게시글을 조회합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     */
    public function find(string $slug, int $id): ?Post
    {
        $board = Board::where('slug', $slug)->first();

        return Post::withTrashed()->with(['user'])->where('board_id', $board?->id)->find($id);
    }

    /**
     * ID로 게시글을 조회하며, 없으면 예외를 발생시킵니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     *
     * @throws ModelNotFoundException
     */
    public function findOrFail(string $slug, int $id): Post
    {
        $board = Board::where('slug', $slug)->firstOrFail();

        return Post::withTrashed()->with(['user'])->where('board_id', $board->id)->findOrFail($id);
    }

    /**
     * 게시글을 수정합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     * @param  array  $data  수정할 데이터
     *
     * @throws ModelNotFoundException
     */
    public function update(string $slug, int $id, array $data): Post
    {
        $post = $this->findOrFail($slug, $id);
        $post->update($data);

        return $post->fresh();
    }

    /**
     * 게시글을 삭제합니다 (소프트 삭제).
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     *
     * @throws ModelNotFoundException
     */
    public function delete(string $slug, int $id): bool
    {
        $post = $this->findOrFail($slug, $id);

        return $post->delete();
    }

    /**
     * 게시글을 영구 삭제합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     *
     * @throws ModelNotFoundException
     */
    public function forceDelete(string $slug, int $id): bool
    {
        $post = $this->findOrFail($slug, $id);

        return $post->forceDelete();
    }

    /**
     * 게시글 상태를 변경합니다 (블라인드/삭제/복원).
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     * @param  string  $status  변경할 상태 (published/blinded/deleted)
     * @param  array  $actionLog  작업 이력 데이터
     *
     * @throws ModelNotFoundException
     */
    public function updateStatus(string $slug, int $id, string $status, array $actionLog, ?string $triggerType = null): Post
    {
        $post = $this->findOrFail($slug, $id);

        // 기존 작업 이력 가져오기
        $actionLogs = $post->action_logs ?? [];
        $actionLogs[] = $actionLog;

        $updateData = [
            'status' => $status,
            'action_logs' => $actionLogs,
        ];

        // trigger_type이 지정된 경우 함께 업데이트
        if ($triggerType !== null) {
            $updateData['trigger_type'] = $triggerType;
        }

        $post->update($updateData);

        // deleted → published 또는 deleted → blinded 변경 시 deleted_at 복원
        if ($status !== 'deleted' && $post->trashed()) {
            $post->restore();
        }

        $post->refresh();

        return $post;
    }

    /**
     * 조회수를 증가시킵니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     * @return int 증가된 조회수
     */
    public function incrementViewCount(string $slug, int $id): int
    {
        $board = Board::where('slug', $slug)->first();

        Post::where('board_id', $board?->id)
            ->where('id', $id)
            ->increment('view_count');

        $post = $this->find($slug, $id);

        return $post?->view_count ?? 0;
    }

    /**
     * 해당 게시판의 게시글이 공지글인지 경량 조회합니다.
     *
     * 존재하지 않으면 null을 반환합니다. trashed(`deleted_at`) 여부는 고려하지 않으며
     * 스코프/권한 체크를 수행하지 않습니다.
     *
     * @param  int  $id  게시글 ID
     * @param  int  $boardId  게시판 ID
     * @return bool|null 공지 여부 또는 미존재 시 null
     */
    public function isNotice(int $id, int $boardId): ?bool
    {
        $value = Post::withTrashed()
            ->where('id', $id)
            ->where('board_id', $boardId)
            ->value('is_notice');

        return $value === null ? null : (bool) $value;
    }

    /**
     * navigation 판별용 게시글 메타(카테고리·부모 ID)를 경량 조회합니다.
     *
     * isNotice 와 동일하게 trashed 포함, 스코프/권한 체크 없이 조회합니다.
     *
     * @param  int  $id  게시글 ID
     * @param  int  $boardId  게시판 ID
     * @return array{category: string|null, parent_id: int|null}|null 메타 또는 미존재 시 null
     */
    public function getNavigationMeta(int $id, int $boardId): ?array
    {
        $row = Post::withTrashed()
            ->where('id', $id)
            ->where('board_id', $boardId)
            ->first(['category', 'parent_id']);

        if ($row === null) {
            return null;
        }

        return [
            'category' => $row->category,
            'parent_id' => $row->parent_id !== null ? (int) $row->parent_id : null,
        ];
    }

    /**
     * 신고 처리를 위한 게시글 상태를 일괄 업데이트합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     * @param  array  $updates  업데이트할 데이터 (status, trigger_type, deleted_at, action_log)
     * @return Post 수정된 게시글
     *
     * @throws ModelNotFoundException
     */
    public function updateStatusBulk(string $slug, int $id, array $updates): Post
    {
        $board = Board::where('slug', $slug)->firstOrFail();

        $post = Post::withTrashed()->where('board_id', $board->id)->findOrFail($id);

        // action_log가 있으면 기존 이력에 추가
        if (isset($updates['action_log'])) {
            $actionLogs = $post->action_logs ?? [];
            $actionLogs[] = $updates['action_log'];
            $updates['action_logs'] = $actionLogs;
            unset($updates['action_log']);
        }

        // trigger_type 컬럼에 저장 (action_log 내 trigger 값 사용)
        if (isset($updates['trigger_type'])) {
            // trigger_type은 그대로 update에 포함됨
        }

        // deleted_at 처리 (SoftDeletes)
        $shouldDelete = isset($updates['deleted_at']) && $updates['deleted_at'] !== null;
        $shouldRestore = isset($updates['deleted_at']) && $updates['deleted_at'] === null;

        // deleted_at은 update에서 제외 (별도 처리)
        unset($updates['deleted_at']);

        // 상태 및 기타 필드 업데이트
        $post->update($updates);

        // SoftDelete 처리
        if ($shouldDelete && ! $post->trashed()) {
            $post->delete();
        } elseif ($shouldRestore && $post->trashed()) {
            $post->restore();
        }

        return $post->fresh();
    }

    /**
     * ID로 게시글을 조회하며 댓글/첨부파일 카운트를 포함합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  게시글 ID
     * @return Post|null 게시글 모델 (카운트 포함)
     */
    public function findWithCounts(string $slug, int $id, ?int $boardId = null): ?Post
    {
        // boardId가 전달되면 Board 모델 재조회 없이 직접 사용
        if (! $boardId) {
            $board = Board::where('slug', $slug)->first();
            $boardId = $board?->id;
        }

        // 관리 권한자는 삭제된 게시글의 하위 데이터(답글/첨부)까지 열람 가능.
        // 첨부 eager load 클로저에서도 동일 권한 기준으로 cascade 삭제분을 포함하기 위해
        // 조회 이전에 권한을 계산한다 (댓글의 권한 기반 withTrashed 와 비대칭 제거).
        $hasDeletePermission = $this->checkBoardPermission($slug, 'admin.control')
            || $this->checkBoardPermission($slug, 'admin.manage')
            || $this->checkBoardPermission($slug, 'manager', PermissionType::User);

        $post = Post::withTrashed()
            ->where('board_id', $boardId)
            ->with([
                'user',
                'user.avatarAttachment',
                'board',
                'parent' => function ($query) {
                    $query->withTrashed()
                        ->with('user');
                },
                'attachments' => function ($query) use ($boardId, $hasDeletePermission) {
                    $query->where('board_id', $boardId);
                    // 관리 권한자는 게시글 삭제로 cascade soft delete 된 첨부까지 조회한다.
                    // 단, 사용자가 글 삭제 전에 직접 지운 첨부(trigger_type='user' 등)는 제외하고
                    // cascade 분만 포함한다 (살아있는 것 + cascade 만). 댓글의 cascade-only 노출과 일관.
                    if ($hasDeletePermission) {
                        $query->withTrashed()
                            ->where(function ($q) {
                                $q->whereNull('deleted_at')
                                    ->orWhere('trigger_type', TriggerType::Cascade->value);
                            });
                    }
                },
            ])
            ->find($id);

        // 모든 하위 답글을 재귀적으로 로드하여 트리 구조로 설정
        if ($post) {
            // loadAllDescendantReplies는 board_id만 필요하므로 Board 모델 대신 조회된 board 사용
            $board = $board ?? $post->board;
            $allReplies = $this->loadAllDescendantReplies($post->id, $board, $hasDeletePermission);
            $post->setRelation('replies', $allReplies);
        }

        return $post;
    }

    /**
     * 특정 게시글의 모든 하위 답글을 재귀적으로 로드합니다.
     *
     * 직접 자식뿐 아니라 손자, 증손자 등 모든 후손 답글을 한 번의 쿼리로 가져온 후
     * 트리 구조(직접 자식만)로 필터링하여 반환합니다.
     *
     * @param  int  $postId  부모 게시글 ID
     * @param  Board|null  $board  게시판 모델
     * @param  bool  $withTrashed  삭제된 답글 포함 여부 (관리자 권한 시 true)
     * @return \Illuminate\Database\Eloquent\Collection 직접 자식 답글 (각 답글에 하위 replies 관계 설정됨)
     */
    private function loadAllDescendantReplies(int $postId, ?Board $board, bool $withTrashed = false): \Illuminate\Database\Eloquent\Collection
    {
        // 모든 하위 답글을 한 번에 가져오기 (재귀 쿼리 대신 반복 방식)
        $allReplies = collect();
        $parentIds = [$postId];

        while (! empty($parentIds)) {
            $query = Post::query()
                ->whereIn('parent_id', $parentIds)
                ->when($board, fn ($q) => $q->where('board_id', $board->id))
                ->with('user');

            if ($withTrashed) {
                $query->withTrashed();
            }

            $batch = $query->get();

            if ($batch->isEmpty()) {
                break;
            }

            $allReplies = $allReplies->merge($batch);
            $parentIds = $batch->pluck('id')->toArray();
        }

        // 트리 구조로 조합: 각 답글에 하위 replies 관계 설정
        $grouped = $allReplies->groupBy('parent_id');

        foreach ($allReplies as $reply) {
            $children = $grouped->get($reply->id, collect());
            $reply->setRelation('replies', $children);
        }

        // 직접 자식만 반환 (PostResource에서 재귀적으로 replies를 직렬화)
        return new \Illuminate\Database\Eloquent\Collection(
            $grouped->get($postId, collect())->all()
        );
    }

    /**
     * 전체 일반 게시글(원글) 수를 조회합니다.
     * 필터가 적용된 경우 필터 조건을 만족하는 일반 게시글 수를 반환합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  array  $filters  필터 조건
     * @param  bool  $withTrashed  삭제된 게시글 포함 여부
     * @return int 일반 게시글 수 (답글, 공지 제외)
     */
    public function countNormalPosts(string $slug, array $filters = [], bool $withTrashed = false): int
    {
        $count = fn () => $this->countNormalPostsWithoutGuard($slug, $filters, $withTrashed);

        return ! empty($filters['search'])
            ? $this->withSearchConcurrencyGuard($count)
            : $count();
    }

    private function countNormalPostsWithoutGuard(string $slug, array $filters, bool $withTrashed): int
    {
        $board = Board::where('slug', $slug)->first();
        $optimizedSearch = config('benchmark.board_list_variant', 'optimized') === 'optimized'
            && ! empty($filters['search']);
        $search = (string) ($filters['search'] ?? '');
        $searchField = (string) ($filters['search_field'] ?? 'all');

        // 권한 스코프 필터링용 permission identifier (Service에서 컨텍스트 기반으로 전달)
        $scopePermission = $filters['scope_permission'] ?? "sirsoft-board.{$slug}.admin.posts.read";
        unset($filters['scope_permission']);

        $query = Post::query()
            ->where('board_id', $board?->id)
            ->where('is_notice', false)  // 공지글 제외
            ->whereNull('parent_id');    // 원글만 (답글 제외)

        // 권한 스코프 필터링
        PermissionHelper::applyPermissionScope($query, $scopePermission);

        if ($withTrashed) {
            $query->withTrashed();
        }

        // optimized 검색은 branch별 후보를 별도로 제한하므로 기존 필터 쿼리에서 제외합니다.
        $queryFilters = $filters;
        if ($optimizedSearch) {
            unset($queryFilters['search'], $queryFilters['search_field']);
        }
        $this->applyFilters($query, $queryFilters);

        if ($optimizedSearch) {
            $result = $this->fetchOptimizedSearchCandidates(
                $query,
                $search,
                $searchField,
                $this->escapeLikeKeyword($search),
                'id',
                'desc',
                $this->searchCandidateLimit()
            );

            return min($result['candidates']->count(), $this->searchCandidateLimit() - 1);
        }

        return $query->count();
    }

    /**
     * 이전/다음 게시글을 조회합니다.
     * buildSortedPostList 메서드를 사용하여 목록 정렬 방식과 동일하게 처리합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  int  $id  현재 게시글 ID
     * @param  array  $filters  정렬 파라미터 (order_by, order_direction)
     * @param  bool  $withTrashed  삭제된 게시글 포함 여부 (기본: false)
     * @return array{prev: Post|null, next: Post|null} 이전/다음 게시글
     */
    public function getAdjacentPosts(string $slug, int $id, array $filters = [], bool $withTrashed = false, ?int $boardId = null): array
    {
        // boardId가 전달되면 Board 모델 재조회 없이 직접 사용
        if (! $boardId) {
            $board = Board::where('slug', $slug)->first();
            if (! $board) {
                return ['prev' => null, 'next' => null];
            }
            $boardId = $board->id;
        }

        $category = $filters['category'] ?? null;
        $orderBy = $filters['order_by'] ?? 'id';
        $orderDirection = $filters['order_direction'] ?? 'desc';

        // Enum 객체를 문자열로 변환 (buildSortedPostList와 동일 패턴)
        if ($orderBy instanceof \BackedEnum) {
            $orderBy = $orderBy->value;
        }
        if ($orderDirection instanceof \BackedEnum) {
            $orderDirection = $orderDirection->value;
        }

        // Enum 값 → 실제 DB 컬럼 매핑 (author → author_name)
        $columnMapping = [
            'author' => 'author_name',
        ];
        if (isset($columnMapping[$orderBy])) {
            $orderBy = $columnMapping[$orderBy];
        }

        // 허용된 정렬 컬럼 화이트리스트 (SQL 인젝션 방지)
        $allowedColumns = ['id', 'view_count', 'created_at', 'title', 'author_name'];
        if (! in_array($orderBy, $allowedColumns)) {
            $orderBy = 'id';
        }
        $orderDirection = in_array(strtolower($orderDirection), ['asc', 'desc']) ? strtolower($orderDirection) : 'desc';

        $currentPost = Post::find($id, [$orderBy, 'id']);
        if ($currentPost === null) {
            return ['prev' => null, 'next' => null];
        }

        $currentValue = $currentPost->{$orderBy};

        // 기본 조건: 공지 제외, 원글만, 게시 상태
        $baseQuery = fn () => Post::query()
            ->where('board_id', $boardId)
            ->where('is_notice', false)
            ->whereNull('parent_id')
            ->where('status', PostStatus::Published->value)
            ->when(! $withTrashed, fn ($q) => $q->whereNull('deleted_at'))
            ->when($category, fn ($q) => $q->where('category', $category))
            ->select(['id', 'title']);

        // 이전/다음 글 조회 (2단계: strict 비교 → tie-breaking)
        // OR 조건은 MySQL 옵티마이저가 인덱스를 사용하지 못하므로
        // strict 비교(< or >)를 먼저 시도하고, 결과가 없으면 동일 값 tie-breaking 쿼리 실행
        $prev = $this->findAdjacentPost(
            $baseQuery, $orderBy, $orderDirection, $currentValue, $id, 'prev'
        );

        $next = $this->findAdjacentPost(
            $baseQuery, $orderBy, $orderDirection, $currentValue, $id, 'next'
        );

        return ['prev' => $prev, 'next' => $next];
    }

    /**
     * 이전 또는 다음 게시글을 조회합니다. (인덱스 최적화)
     *
     * OR 조건은 MySQL 옵티마이저가 인덱스를 사용하지 못하므로,
     * strict 비교를 먼저 시도하고 결과가 없으면 동일 값 tie-breaking 쿼리를 실행합니다.
     *
     * @param  \Closure  $baseQuery  기본 쿼리 팩토리
     * @param  string  $orderBy  정렬 컬럼
     * @param  string  $orderDirection  정렬 방향 (asc/desc)
     * @param  mixed  $currentValue  현재 게시글의 정렬 값
     * @param  int  $id  현재 게시글 ID
     * @param  string  $direction  조회 방향 (prev/next)
     * @return Post|null 이전/다음 게시글
     */
    private function findAdjacentPost(\Closure $baseQuery, string $orderBy, string $orderDirection, mixed $currentValue, int $id, string $direction): ?Post
    {
        $isPrev = $direction === 'prev';

        // prev: 정렬 기준으로 현재 글보다 앞 → desc면 >, asc면 <
        // next: 정렬 기준으로 현재 글보다 뒤 → desc면 <, asc면 >
        $strictOp = match (true) {
            $isPrev && $orderDirection === 'desc' => '>',
            $isPrev && $orderDirection === 'asc' => '<',
            ! $isPrev && $orderDirection === 'desc' => '<',
            default => '>',
        };
        $sortDir = $isPrev
            ? ($orderDirection === 'desc' ? 'asc' : 'desc')
            : $orderDirection;
        // DESC 정렬: 목록은 ORDER BY col DESC, id DESC
        //   prev(위쪽) = 같은 값 내에서 id > current → idOp='>', idSort='asc'(가장 가까운 것)
        //   next(아래쪽) = 같은 값 내에서 id < current → idOp='<', idSort='desc'(가장 가까운 것)
        // ASC 정렬: 목록은 ORDER BY col ASC, id ASC
        //   prev(위쪽) = 같은 값 내에서 id < current → idOp='<', idSort='desc'
        //   next(아래쪽) = 같은 값 내에서 id > current → idOp='>', idSort='asc'
        $idOp = ($isPrev xor $orderDirection === 'asc') ? '>' : '<';
        $idSort = $idOp === '>' ? 'asc' : 'desc';

        // 1단계: 동일 정렬 값 내 tie-breaking (id 비교)
        // 동일 값 내의 글이 정렬상 더 가까우므로 먼저 확인
        $tieQuery = $baseQuery()
            ->where($orderBy, $currentValue)
            ->where('id', $idOp, $id)
            ->orderBy('id', $idSort);

        $result = $tieQuery->first();

        if ($result) {
            return $result;
        }

        // 2단계: 동일 값 내에 없으면 다른 정렬 값으로 이동
        if ($orderBy === 'created_at') {
            // created_at: 서브쿼리 MAX/MIN으로 정확한 값을 먼저 찾고 등호 조회
            // → 콜드 스타트(버퍼 풀 미적재)에서도 ~2ms (range scan 대비 100배 이상 빠름)
            $aggregateFunc = $strictOp === '<' ? 'MAX' : 'MIN';
            $subQuery = $baseQuery()
                ->select(DB::raw("{$aggregateFunc}(`{$orderBy}`)"))
                ->where($orderBy, $strictOp, $currentValue);

            return $baseQuery()
                ->where($orderBy, DB::raw("({$subQuery->toSql()})"))
                ->mergeBindings($subQuery->getQuery())
                ->orderBy('id', $idSort)
                ->first();
        }

        // 그 외 컬럼: strict 비교 (인덱스 range scan)
        return $baseQuery()
            ->where($orderBy, $strictOp, $currentValue)
            ->orderBy($orderBy, $sortDir)
            ->orderBy('id', $idSort)
            ->first();
    }

    /**
     * 목록 정렬 방식대로 게시글 리스트를 생성합니다.
     * (공지 + 원글 + 답글을 정렬된 순서로 반환)
     *
     * @param  string  $slug  게시판 슬러그
     * @param  array  $columns  조회할 컬럼 목록
     * @param  bool  $withTrashed  삭제된 게시글 포함 여부
     * @param  array  $relations  Eager Load 관계
     * @param  array  $withCount  카운트 관계
     * @param  array  $filters  필터 조건 (검색, 상태, 분류 등)
     * @param  int|null  $perPage  페이지당 원글 수 (null이면 전체 조회)
     * @param  int  $currentPage  현재 페이지 번호
     * @return Collection|LengthAwarePaginator 정렬된 게시글 컬렉션 또는 페이지네이터
     */
    private function buildSortedPostList(
        string $slug,
        array $columns = ['*'],
        bool $withTrashed = false,
        array $relations = [],
        array $withCount = [],
        array $filters = [],
        ?int $perPage = null,
        int $currentPage = 1,
        ?Board $board = null
    ) {
        $optimized = config('benchmark.board_list_variant', 'optimized') === 'optimized';
        $hasSearch = ! empty($filters['search']);
        $optimizedSearch = $optimized && $hasSearch;
        $searchField = (string) ($filters['search_field'] ?? 'all');

        // board가 전달되지 않은 경우에만 DB 조회 (하위 호환 유지)
        if (! $board) {
            $board = Board::where('slug', $slug)->first();
        }
        $boardId = $board?->id;

        // Eager loading(with)의 관계에 board_id 조건을 명시적으로 바인딩
        // (모델 관계 정의에서 $this->board_id를 사용하면 Eager loading 시 null이 되는 문제 해결)
        $relations = $this->bindBoardIdToRelations($relations, $boardId);

        // 권한 스코프 필터링용 permission identifier (Service에서 컨텍스트 기반으로 전달)
        $postPermission = $filters['scope_permission'] ?? "sirsoft-board.{$slug}.admin.posts.read";
        unset($filters['scope_permission']);

        // 1단계: 공지글 조회 (첫 페이지에만 표시, 필터 미적용)
        $notices = collect([]);
        if ($currentPage == 1) {
            $noticeQuery = Post::query()
                ->where('board_id', $boardId)
                ->where('is_notice', true)
                ->whereNull('parent_id')
                ->orderBy('created_at', 'desc');

            // 권한 스코프 필터링
            PermissionHelper::applyPermissionScope($noticeQuery, $postPermission);

            // withTrashed를 사용하지 않으면 삭제되지 않은 것만 조회
            if ($withTrashed) {
                $noticeQuery->withTrashed();
            } else {
                $noticeQuery->whereNull('deleted_at');
            }

            if (! empty($relations)) {
                $noticeQuery->with($relations);
            }

            if ($optimized) {
                $noticeQuery->limit(self::MAX_NOTICE_POSTS);
            }

            $notices = $noticeQuery->get($columns);
        }

        // 2단계: 원글 조회 (공지 제외)
        $parentQuery = Post::query()
            ->where('board_id', $boardId)
            ->where('is_notice', false)
            ->whereNull('parent_id');

        // 권한 스코프 필터링
        PermissionHelper::applyPermissionScope($parentQuery, $postPermission);

        // withTrashed를 사용하지 않으면 삭제되지 않은 것만 조회
        if ($withTrashed) {
            $parentQuery->withTrashed();
        } else {
            $parentQuery->whereNull('deleted_at');
        }

        // optimized 검색은 아래에서 선택된 검색 branch를 각각 제한합니다.
        $queryFilters = $filters;
        if ($optimizedSearch) {
            unset($queryFilters['search'], $queryFilters['search_field']);
        }

        // 필터 적용 (원글만 검색, 답글은 3단계에서 별도 필터링)
        $this->applyFilters($parentQuery, $queryFilters);

        // 정렬 (order_by 파라미터 사용, 기본값: id)
        $orderBy = $filters['order_by'] ?? 'id';
        $orderDirection = $filters['order_direction'] ?? 'desc';

        // Enum 객체를 문자열로 변환
        if ($orderBy instanceof \BackedEnum) {
            $orderBy = $orderBy->value;
        }
        if ($orderDirection instanceof \BackedEnum) {
            $orderDirection = $orderDirection->value;
        }

        // 허용된 정렬 컬럼 목록 (보안을 위한 화이트리스트)
        $allowedOrderColumns = ['id', 'view_count', 'created_at', 'title', 'author_name'];

        // Enum 값 → 실제 DB 컬럼 매핑 (author → author_name)
        $columnMapping = [
            'author' => 'author_name',
        ];
        if (isset($columnMapping[$orderBy])) {
            $orderBy = $columnMapping[$orderBy];
        }

        if (! in_array($orderBy, $allowedOrderColumns)) {
            $orderBy = 'id'; // 기본값으로 폴백
        }

        // 정렬 방향 검증 (asc 또는 desc만 허용)
        $orderDirection = strtolower($orderDirection);
        if (! in_array($orderDirection, ['asc', 'desc'])) {
            $orderDirection = 'desc'; // 기본값으로 폴백
        }

        // 정렬 적용 (id를 2차 정렬로 추가 — 동일 값 내 순서를 결정론적으로 보장)
        // created_at은 초 단위라 실질적 중복이 드물지만, view_count/title/author_name은 중복이 많음
        $parentQuery->orderBy($orderBy, $orderDirection)->orderBy('id', $orderDirection);

        // 페이지네이션 여부에 따라 분기
        $embeddedTotal = null;
        $embeddedTotalIsExact = null;
        $embeddedTotalRelation = null;
        if ($perPage !== null) {
            if ($optimized) {
                // 깊은 페이지에서 LONGTEXT와 관계 컬럼까지 정렬하지 않도록 ID만 먼저 페이지네이션한다.
                // 실제 목록 행은 선택된 ID(최대 perPage건)에 한해 별도 조회한다.
                if ($optimizedSearch) {
                    $searchPage = $this->paginateOptimizedSearch(
                        $parentQuery,
                        (string) $filters['search'],
                        $searchField,
                        $orderBy,
                        $orderDirection,
                        $perPage,
                        $currentPage
                    );
                    $paginator = $searchPage['paginator'];
                    $pageIndex = $paginator->getCollection();
                    $embeddedTotal = $searchPage['total'];
                    $embeddedTotalIsExact = $searchPage['total_is_exact'];
                    $embeddedTotalRelation = $searchPage['total_relation'];
                } else {
                    $paginator = $parentQuery->simplePaginate($perPage, ['id'], 'page', $currentPage);
                    $pageIndex = $paginator->getCollection();

                    if ($hasSearch) {
                        if ($pageIndex->isNotEmpty()) {
                            $embeddedTotal = (($currentPage - 1) * $perPage)
                                + $pageIndex->count()
                                + ($paginator->hasMorePages() ? 1 : 0);
                            $embeddedTotalIsExact = ! $paginator->hasMorePages();
                            $embeddedTotalRelation = $embeddedTotalIsExact ? 'eq' : 'gte';
                        } elseif ($currentPage === 1) {
                            $embeddedTotal = 0;
                            $embeddedTotalIsExact = true;
                            $embeddedTotalRelation = 'eq';
                        }
                    }
                }
                $parents = $this->hydrateListPostsByIds(
                    $pageIndex->pluck('id')->all(),
                    $boardId,
                    $columns,
                    $withTrashed,
                    $relations,
                    $withCount
                );
            } else {
                // G7 7.0.4 원본 경로: OFFSET 전에 목록 컬럼과 관계를 함께 조회한다.
                if (! empty($relations)) {
                    $parentQuery->with($relations);
                }
                $paginator = $parentQuery->simplePaginate($perPage, $columns, 'page', $currentPage);
                $parents = $paginator->getCollection();
            }
        } else {
            // 전체 조회
            if (! empty($relations)) {
                $parentQuery->with($relations);
            }
            if (! empty($withCount)) {
                $parentQuery->withCount($withCount);
            }
            $parents = $parentQuery->get($columns);
            $paginator = null;
        }

        // 3단계: 모든 하위 답글 조회 (모든 depth 처리 — depth-1만이 아닌 depth-2+ 포함)
        $parentIds = $parents->pluck('id')->toArray();
        $allReplies = collect([]);

        if (! empty($parentIds)) {
            $currentLevelIds = $optimized
                ? $parents
                    ->filter(fn (Post $post) => $post->replies_count > 0)
                    ->pluck('id')
                    ->all()
                : $parentIds;

            while (! empty($currentLevelIds)) {
                $levelQuery = Post::query()
                    ->where('board_id', $boardId)
                    ->whereIn('parent_id', $currentLevelIds)
                    ->orderBy('id', 'asc');

                if ($optimized) {
                    $remaining = self::MAX_INLINE_REPLIES - $allReplies->count();
                    if ($remaining <= 0) {
                        break;
                    }
                    $levelQuery->limit($remaining);
                }

                if ($withTrashed) {
                    $levelQuery->withTrashed();
                } else {
                    $levelQuery->whereNull('deleted_at');
                }

                if (! empty($relations)) {
                    $levelQuery->with($relations);
                }
                if ($optimized && ! empty($withCount)) {
                    $levelQuery->withCount($withCount);
                }

                $levelReplies = $levelQuery->get($columns);

                if ($levelReplies->isEmpty()) {
                    break;
                }

                $allReplies = $allReplies->merge($levelReplies);
                $currentLevelIds = $optimized
                    ? $levelReplies
                        ->filter(fn (Post $post) => $post->replies_count > 0)
                        ->pluck('id')
                        ->all()
                    : $levelReplies->pluck('id')->all();
            }
        }

        $replies = $allReplies;

        // 4단계: 병합 (원글 + 모든 하위 답글을 깊이 우선 순으로)
        $mergedItems = collect([]);

        $appendReplies = function (int $postId) use (&$appendReplies, &$mergedItems, $replies): void {
            $directReplies = $replies->where('parent_id', $postId)->sortBy('id');
            foreach ($directReplies as $reply) {
                $mergedItems->push($reply);
                $appendReplies($reply->id);
            }
        };

        foreach ($parents as $parent) {
            $mergedItems->push($parent);
            $appendReplies($parent->id);
        }

        // 5단계: 공지글을 맨 앞에 추가
        $finalItems = $notices->merge($mergedItems);

        // 검색 total 메타는 첫 응답 모델의 숨김 속성으로 Service/Resource에 전달합니다.
        // 페이지 1의 검색 결과가 0건이어도 공지가 있으면 공지 모델에 전달할 수 있습니다.
        if ($embeddedTotal !== null && $finalItems->isNotEmpty()) {
            $finalItems->first()->setAttribute(self::INTERNAL_TOTAL_ATTRIBUTE, $embeddedTotal);
            $finalItems->first()->setAttribute(self::INTERNAL_TOTAL_EXACT_ATTRIBUTE, $embeddedTotalIsExact);
            $finalItems->first()->setAttribute(self::INTERNAL_TOTAL_RELATION_ATTRIBUTE, $embeddedTotalRelation);
        }

        // 페이지네이션 사용 시 paginator에 최종 컬렉션 설정
        if ($paginator !== null) {
            $paginator->setCollection($finalItems);

            return $paginator;
        }

        // 전체 조회 시 컬렉션 반환
        return $finalItems;
    }

    /**
     * 페이지 인덱스에서 선택된 게시글만 목록 표시용 컬럼과 관계로 조회합니다.
     *
     * @param  array<int>  $ids  페이지 순서대로 정렬된 게시글 ID
     * @param  int|null  $boardId  게시판 ID
     * @param  array  $columns  목록 조회 컬럼
     * @param  bool  $withTrashed  삭제된 게시글 포함 여부
     * @param  array  $relations  Eager Load 관계
     * @param  array  $withCount  카운트 관계
     * @return Collection<int, Post>
     */
    private function hydrateListPostsByIds(
        array $ids,
        ?int $boardId,
        array $columns,
        bool $withTrashed,
        array $relations,
        array $withCount
    ): Collection {
        if ($ids === []) {
            return collect();
        }

        $query = Post::query()
            ->where('board_id', $boardId)
            ->whereIn('id', $ids);

        if ($withTrashed) {
            $query->withTrashed();
        } else {
            $query->whereNull('deleted_at');
        }

        if (! empty($relations)) {
            $query->with($relations);
        }
        if (! empty($withCount)) {
            $query->withCount($withCount);
        }

        $postsById = $query->get($columns)->keyBy('id');

        return collect($ids)
            ->map(fn (int $id) => $postsById->get($id))
            ->filter()
            ->values();
    }

    /**
     * 사용자의 게시판 활동 통계를 조회합니다.
     *
     * 작성한 게시글 수, 작성한 댓글 수, 총 조회수를 반환합니다.
     *
     * @param  int  $userId  사용자 ID
     * @return array{total_posts: int, total_comments: int, total_views: int} 활동 통계
     */
    public function getUserActivityStats(int $userId): array
    {
        // 비활성 게시판 제외
        $inactiveBoardIds = $this->getInactiveBoardIds();

        // 쿼리 1: COUNT — idx_board_posts_user_activity 커버링 (Using index)
        $postsQuery = Post::where('user_id', $userId);
        if (! empty($inactiveBoardIds)) {
            $postsQuery->whereNotIn('board_id', $inactiveBoardIds);
        }
        $totalPosts = $postsQuery->count();

        // 쿼리 2: SUM(comments_count) + SUM(view_count) — idx_board_posts_user_board_stats 커버링
        // comments_count 는 PostCountSyncListener 가 정확히 동기화하므로 SUM 으로 대체 (JOIN 제거)
        // 소프트 삭제된 게시글은 통계에서 제외 (이슈 #104 요구사항) — withTrashed 미사용
        $statsQuery = Post::where('user_id', $userId);
        if (! empty($inactiveBoardIds)) {
            $statsQuery->whereNotIn('board_id', $inactiveBoardIds);
        }
        $sums = $statsQuery->selectRaw('COALESCE(SUM(comments_count), 0) as total_comments, COALESCE(SUM(view_count), 0) as total_views')
            ->first();

        return [
            'total_posts' => $totalPosts,
            'total_comments' => (int) $sums->total_comments,
            'total_views' => (int) $sums->total_views,
        ];
    }

    /**
     * 사용자의 공개 게시글/댓글 통계를 조회합니다 (공개 프로필용).
     *
     * 기존 getUserActivityStats()와 다른 점:
     * - status='published' 조건 적용
     * - comments_count = 실제 작성한 댓글 수 (댓글 단 게시글 수가 아님)
     *
     * @param  int  $userId  사용자 ID
     * @return array{posts_count: int, comments_count: int} 공개 게시글/댓글 통계
     */
    public function getUserPublicStats(int $userId): array
    {
        // 단일 테이블 단일 쿼리
        $postsCount = Post::where('user_id', $userId)
            ->where('status', PostStatus::Published->value)
            ->count();

        $commentsCount = Comment::where('user_id', $userId)
            ->where('status', PostStatus::Published->value)
            ->count();

        return [
            'posts_count' => $postsCount,
            'comments_count' => $commentsCount,
        ];
    }

    /**
     * 사용자의 게시글 활동 목록을 조회합니다.
     *
     * 사용자가 작성한 게시글, 댓글을 단 게시글을 통합하여 반환합니다.
     *
     * @param  int  $userId  사용자 ID
     * @param  array  $filters  필터 조건 (board_slug, search, activity_type, sort, is_public)
     * @param  int  $perPage  페이지당 항목 수
     * @return LengthAwarePaginator 게시글 활동 목록
     */
    public function getUserActivities(int $userId, array $filters = [], int $perPage = 20): LengthAwarePaginator
    {
        $boardSlugFilter = $filters['board_slug'] ?? null;
        $search = $filters['search'] ?? null;
        $activityType = $filters['activity_type'] ?? 'authored';
        $sort = $filters['sort'] ?? 'latest'; // latest, oldest, views
        $isPublic = $filters['is_public'] ?? false; // 공개 프로필용 필터 (비밀글 제외, 공개 게시글만)
        $excludeBoardSlugs = $filters['exclude_board_slugs'] ?? [];

        // board_slug 필터용 board_id 조회
        $boardIdFilter = null;
        if ($boardSlugFilter) {
            $boardIdFilter = Board::where('slug', $boardSlugFilter)->value('id');
        }

        // exclude_board_slugs → board_id 목록으로 변환
        $excludeBoardIds = [];
        if (! empty($excludeBoardSlugs)) {
            $excludeBoardIds = Board::whereIn('slug', $excludeBoardSlugs)->pluck('id')->all();
        }

        // DB 레벨 정렬 컬럼 결정
        $orderColumn = match ($sort) {
            'views' => 'board_posts.view_count',
            'oldest' => 'board_posts.created_at',
            default => 'board_posts.created_at',
        };
        $orderDirection = $sort === 'oldest' ? 'asc' : 'desc';

        $cachedTotal = $filters['cached_total'] ?? null;

        if ($activityType === 'commented' && ! $isPublic) {
            return $this->getUserCommentedActivities($userId, $boardIdFilter, $excludeBoardIds, $search, $orderColumn, $orderDirection, $perPage, $cachedTotal);
        }

        // authored (기본값, 공개 프로필 포함)
        return $this->getUserAuthoredActivities($userId, $boardIdFilter, $excludeBoardIds, $search, $isPublic, $orderColumn, $orderDirection, $perPage, $cachedTotal);
    }

    /**
     * 사용자가 작성한 게시글 활동을 DB 레벨 페이지네이션으로 조회합니다.
     *
     * @param  int  $userId  사용자 ID
     * @param  int|null  $boardIdFilter  게시판 ID 필터
     * @param  string|null  $search  검색 키워드
     * @param  bool  $isPublic  공개 프로필 여부 (비밀글 제외)
     * @param  string  $orderColumn  정렬 컬럼
     * @param  string  $orderDirection  정렬 방향
     * @param  int  $perPage  페이지당 항목 수
     */
    private function getUserAuthoredActivities(
        int $userId,
        ?int $boardIdFilter,
        array $excludeBoardIds,
        ?string $search,
        bool $isPublic,
        string $orderColumn,
        string $orderDirection,
        int $perPage,
        ?int $cachedTotal = null
    ): LengthAwarePaginator {
        // JOIN 대신 whereNotIn으로 비활성 게시판 제외 — idx_board_posts_user_created 인덱스 활용
        $inactiveBoardIds = $this->getInactiveBoardIds();
        $allExcludeIds = array_unique(array_merge($excludeBoardIds, $inactiveBoardIds));

        $query = Post::query()
            ->where('board_posts.user_id', $userId)
            ->with('board')
            ->orderBy($orderColumn, $orderDirection);

        if ($boardIdFilter) {
            $query->where('board_posts.board_id', $boardIdFilter);
        }

        if (! empty($allExcludeIds)) {
            $query->whereNotIn('board_posts.board_id', $allExcludeIds);
        }

        if ($isPublic) {
            $query->where('board_posts.status', PostStatus::Published->value)
                ->where('board_posts.is_secret', false);
        }

        if ($search) {
            $keyword = $this->escapeLikeKeyword($search);
            $query->where(function ($q) use ($keyword) {
                $q->where('board_posts.title', 'like', "%{$keyword}%")
                    ->orWhere('board_posts.content', 'like', "%{$keyword}%");
            });
        }

        $paginator = $query->paginate($perPage, ['*'], 'page', null, $cachedTotal);

        // paginate 후 10건에만 PHP 가공 적용 (N+1 아님)
        $paginator->through(function ($post) {
            return [
                'id' => $post->id,
                'board_slug' => $post->board?->slug,
                'board_name' => $post->board?->getLocalizedName() ?? '',
                'activity_type' => 'authored',
                'activity_count' => 0,
                'title' => $post->title,
                'is_secret' => (bool) $post->is_secret,
                'status' => $post->status?->value,
                'view_count' => $post->view_count,
                'comment_count' => (int) ($post->comments_count ?? 0),
                'created_at' => $this->formatCreatedAt($post->created_at),
                'created_at_formatted' => $this->formatCreatedAtFormat($post->created_at, g7_module_settings('sirsoft-board', 'display.date_display_format', 'standard')),
                'content_plain' => ($post->content_mode ?? 'text') === 'html'
                    ? $this->stripHtmlToPlainText($post->content ?? '')
                    : ($post->content ?? ''),
            ];
        });

        return $paginator;
    }

    /**
     * 사용자가 댓글을 단 게시글 활동을 DB 레벨 페이지네이션으로 조회합니다.
     *
     * @param  int  $userId  사용자 ID
     * @param  int|null  $boardIdFilter  게시판 ID 필터
     * @param  array  $excludeBoardIds  제외할 게시판 ID 목록
     * @param  string|null  $search  검색 키워드
     * @param  string  $orderColumn  정렬 컬럼
     * @param  string  $orderDirection  정렬 방향
     * @param  int  $perPage  페이지당 항목 수
     */
    private function getUserCommentedActivities(
        int $userId,
        ?int $boardIdFilter,
        array $excludeBoardIds,
        ?string $search,
        string $orderColumn,
        string $orderDirection,
        int $perPage,
        ?int $cachedTotal = null
    ): LengthAwarePaginator {
        // DB::raw() / whereRaw() 내부 raw SQL은 prefix 자동 적용이 안 되므로 명시적으로 처리
        $prefix = DB::getTablePrefix();
        $commentsTable = $prefix.'board_comments';
        $postsTable = $prefix.'board_posts';

        // 비활성 게시판 제외 — JOIN 없이 인덱스 활용
        $inactiveBoardIds = $this->getInactiveBoardIds();
        $allExcludeIds = array_unique(array_merge($excludeBoardIds, $inactiveBoardIds));

        $latestCommentSub = DB::table(DB::raw("{$commentsTable} as bc_outer"))
            ->selectRaw('bc_outer.post_id, bc_outer.content, bc_outer.created_at')
            ->whereRaw("bc_outer.id = (
                SELECT bc2.id FROM {$commentsTable} bc2
                WHERE bc2.post_id = bc_outer.post_id
                  AND bc2.user_id = ?
                  AND bc2.deleted_at IS NULL
                ORDER BY bc2.created_at DESC
                LIMIT 1
            ) AND bc_outer.user_id = ? AND bc_outer.deleted_at IS NULL", [$userId, $userId]);

        $query = Post::query()
            ->join(DB::raw("{$commentsTable} AS uc"), function ($join) use ($userId, $postsTable) {
                $join->on(DB::raw("{$postsTable}.id"), '=', DB::raw('uc.post_id'))
                    ->whereRaw('uc.user_id = ?', [$userId])
                    ->whereRaw('uc.deleted_at IS NULL');
            })
            ->leftJoinSub($latestCommentSub, 'lc', 'board_posts.id', '=', 'lc.post_id')
            ->select([
                'board_posts.*',
                DB::raw('COUNT(DISTINCT uc.id) as activity_count'),
                // board_posts.* 에 이미 comments_count 가 포함되므로 중복 지정 금지
                // (pagination count 쿼리가 subquery 로 감싸질 때 SQLSTATE[42S21] 유발)
                'lc.content as comment_content',
                'lc.created_at as comment_created_at',
            ])
            ->with('board')
            ->groupBy('board_posts.id', 'board_posts.board_id', 'board_posts.comments_count', 'lc.content', 'lc.created_at')
            ->orderBy($orderColumn, $orderDirection);

        if ($boardIdFilter) {
            $query->where('board_posts.board_id', $boardIdFilter);
        }

        if (! empty($allExcludeIds)) {
            $query->whereNotIn('board_posts.board_id', $allExcludeIds);
        }

        if ($search) {
            $keyword = $this->escapeLikeKeyword($search);
            $query->where('uc.content', 'like', "%{$keyword}%");
        }

        $paginator = $query->paginate($perPage, ['*'], 'page', null, $cachedTotal);

        // paginate 후 10건에만 PHP 가공 적용
        $paginator->through(function ($post) {
            return [
                'id' => $post->id,
                'board_slug' => $post->board?->slug,
                'board_name' => $post->board?->getLocalizedName() ?? '',
                'activity_type' => 'commented',
                'activity_count' => (int) ($post->activity_count ?? 0),
                'title' => $post->title,
                'is_secret' => (bool) $post->is_secret,
                'status' => $post->status?->value,
                'view_count' => $post->view_count,
                'comment_count' => (int) ($post->comments_count ?? 0),
                'created_at' => $this->formatCreatedAt($post->created_at),
                'created_at_formatted' => $this->formatCreatedAtFormat($post->created_at, g7_module_settings('sirsoft-board', 'display.date_display_format', 'standard')),
                'content_plain' => ($post->content_mode ?? 'text') === 'html'
                    ? $this->stripHtmlToPlainText($post->content ?? '')
                    : ($post->content ?? ''),
            ];
        });

        return $paginator;
    }

    /**
     * 게시판에서 키워드로 게시글을 검색합니다.
     *
     * 공개 게시글(published, 비밀글 제외)만 대상으로 제목/본문 LIKE 검색을 수행합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  string  $keyword  검색 키워드
     * @param  string  $orderBy  정렬 컬럼
     * @param  string  $direction  정렬 방향 (asc, desc)
     * @param  int  $limit  조회할 최대 항목 수
     * @return array{total: int, total_is_exact?: bool, total_relation?: string, has_more_pages?: bool, result_cap?: int, search_truncated?: bool, items: \Illuminate\Database\Eloquent\Collection}
     */
    public function searchByKeyword(string $slug, string $keyword, string $orderBy = 'created_at', string $direction = 'desc', int $limit = 10): array
    {
        return $this->withSearchConcurrencyGuard(
            fn () => $this->searchByKeywordWithoutGuard($slug, $keyword, $orderBy, $direction, $limit)
        );
    }

    /** @return array<string, mixed> */
    private function searchByKeywordWithoutGuard(string $slug, string $keyword, string $orderBy, string $direction, int $limit): array
    {
        $baseQuery = $this->buildPublicSearchBaseQuery($slug);
        $query = clone $baseQuery;
        $this->applyKeywordSearch($query, $keyword);

        if (config('benchmark.board_list_variant', 'optimized') === 'optimized') {
            return $this->boundedPublicSearchPage(
                $query,
                $baseQuery,
                ['user'],
                $keyword,
                $orderBy,
                $direction,
                $limit,
                1
            );
        }

        $total = $query->count();
        $orderBy = $orderBy === 'relevance' ? 'created_at' : $orderBy;

        $items = $query->with('user')
            ->orderBy($orderBy, $direction)
            ->limit($limit)
            ->get();

        return [
            'total' => $total,
            'items' => $items,
        ];
    }

    /**
     * 게시판에서 키워드와 일치하는 게시글 수를 조회합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @param  string  $keyword  검색 키워드
     * @return int 일치하는 게시글 수
     */
    public function countByKeyword(string $slug, string $keyword): int
    {
        return $this->withSearchConcurrencyGuard(
            fn () => $this->countByKeywordWithoutGuard($slug, $keyword)
        );
    }

    private function countByKeywordWithoutGuard(string $slug, string $keyword): int
    {
        $baseQuery = $this->buildPublicSearchBaseQuery($slug);
        $query = clone $baseQuery;
        $this->applyKeywordSearch($query, $keyword);

        return config('benchmark.board_list_variant', 'optimized') === 'optimized'
            ? $this->boundedSearchCount($query, $baseQuery, $keyword)['total']
            : $query->count();
    }

    /**
     * 여러 게시판에서 키워드로 게시글을 검색합니다 (단일 쿼리, DB 페이지네이션).
     *
     * @param  array  $boardIds  검색 대상 게시판 ID 목록
     * @param  string  $keyword  검색 키워드
     * @param  string  $orderBy  정렬 컬럼
     * @param  string  $direction  정렬 방향 (asc, desc)
     * @param  int  $perPage  페이지당 항목 수
     * @param  int  $page  페이지 번호
     * @return array{total: int, total_is_exact?: bool, total_relation?: string, has_more_pages?: bool, result_cap?: int, search_truncated?: bool, items: \Illuminate\Database\Eloquent\Collection}
     */
    public function searchAcrossBoards(array $boardIds, string $keyword, string $orderBy = 'created_at', string $direction = 'desc', int $perPage = 10, int $page = 1): array
    {
        return $this->withSearchConcurrencyGuard(
            fn () => $this->searchAcrossBoardsWithoutGuard($boardIds, $keyword, $orderBy, $direction, $perPage, $page)
        );
    }

    /** @return array<string, mixed> */
    private function searchAcrossBoardsWithoutGuard(array $boardIds, string $keyword, string $orderBy, string $direction, int $perPage, int $page): array
    {
        $baseQuery = $this->buildPublicSearchBaseQueryByIds($boardIds);
        $query = clone $baseQuery;
        $this->applyKeywordSearch($query, $keyword);

        if (config('benchmark.board_list_variant', 'optimized') === 'optimized') {
            return $this->boundedPublicSearchPage(
                $query,
                $baseQuery,
                ['user', 'board'],
                $keyword,
                $orderBy,
                $direction,
                $perPage,
                $page
            );
        }

        $total = $query->count();
        $orderBy = $orderBy === 'relevance' ? 'created_at' : $orderBy;

        $items = (clone $query)
            ->with('user', 'board')
            ->orderBy($orderBy, $direction)
            ->forPage($page, $perPage)
            ->get();

        return [
            'total' => $total,
            'items' => $items,
        ];
    }

    /**
     * 여러 게시판에서 키워드와 일치하는 게시글 수를 조회합니다 (단일 쿼리).
     *
     * @param  array  $boardIds  검색 대상 게시판 ID 목록
     * @param  string  $keyword  검색 키워드
     * @return int 키워드와 일치하는 게시글 수
     */
    public function countAcrossBoards(array $boardIds, string $keyword): int
    {
        return $this->withSearchConcurrencyGuard(
            fn () => $this->countAcrossBoardsWithoutGuard($boardIds, $keyword)
        );
    }

    private function countAcrossBoardsWithoutGuard(array $boardIds, string $keyword): int
    {
        $baseQuery = $this->buildPublicSearchBaseQueryByIds($boardIds);
        $query = clone $baseQuery;
        $this->applyKeywordSearch($query, $keyword);

        return config('benchmark.board_list_variant', 'optimized') === 'optimized'
            ? $this->boundedSearchCount($query, $baseQuery, $keyword)['total']
            : $query->count();
    }

    /**
     * 여러 게시판의 검색 건수를 cap + 1까지만 확인하고 total 의미를 함께 반환합니다.
     *
     * @return array{total: int, total_is_exact: bool, total_relation: string, result_cap?: int, search_truncated?: bool}
     */
    public function countAcrossBoardsBounded(array $boardIds, string $keyword): array
    {
        return $this->withSearchConcurrencyGuard(
            fn () => $this->countAcrossBoardsBoundedWithoutGuard($boardIds, $keyword)
        );
    }

    /** @return array{total: int, total_is_exact: bool, total_relation: string, result_cap?: int, search_truncated?: bool} */
    private function countAcrossBoardsBoundedWithoutGuard(array $boardIds, string $keyword): array
    {
        $baseQuery = $this->buildPublicSearchBaseQueryByIds($boardIds);
        $query = clone $baseQuery;
        $this->applyKeywordSearch($query, $keyword);

        if (config('benchmark.board_list_variant', 'optimized') === 'optimized') {
            return $this->boundedSearchCount($query, $baseQuery, $keyword);
        }

        return [
            'total' => $query->count(),
            'total_is_exact' => true,
            'total_relation' => 'eq',
        ];
    }

    /**
     * 공개 게시글 검색용 기본 쿼리를 생성합니다.
     *
     * @param  string  $slug  게시판 슬러그
     */
    private function buildPublicSearchBaseQuery(string $slug): Builder
    {
        $board = Board::where('slug', $slug)->first();

        return Post::query()
            ->where('board_id', $board?->id)
            ->where('status', PostStatus::Published->value)
            ->where('is_secret', false);
    }

    /**
     * 여러 게시판 ID를 대상으로 공개 게시글 검색용 기본 쿼리를 생성합니다.
     *
     * @param  array  $boardIds  게시판 ID 목록
     */
    private function buildPublicSearchBaseQueryByIds(array $boardIds): Builder
    {
        return Post::query()
            ->whereIn('board_id', $boardIds)
            ->where('status', PostStatus::Published->value)
            ->where('is_secret', false);
    }

    /**
     * 키워드 검색 조건을 쿼리에 적용합니다.
     *
     * FULLTEXT 인덱스가 지원되면 MATCH...AGAINST를, 아니면 LIKE fallback을 사용합니다.
     *
     * @param  Builder  $query  쿼리 빌더
     * @param  string  $keyword  검색 키워드
     */
    private function applyKeywordSearch(Builder $query, string $keyword): void
    {
        if (DatabaseFulltextEngine::supportsFulltext()) {
            $fulltextKeyword = config('benchmark.board_list_variant', 'optimized') === 'optimized'
                ? $this->sanitizeOptimizedBooleanKeyword($keyword)
                : $keyword;
            if ($fulltextKeyword === '') {
                $query->whereRaw('1 = 0');

                return;
            }
            $query->whereRaw('MATCH(`title`, `content`) AGAINST(? IN BOOLEAN MODE)', [$fulltextKeyword]);
        } else {
            $escapedKeyword = $this->escapeLikeKeyword($keyword);
            $query->where(function ($q) use ($escapedKeyword) {
                $q->where('title', 'like', "%{$escapedKeyword}%")
                    ->orWhere('content', 'like', "%{$escapedKeyword}%");
            });
        }
    }

    /**
     * LIKE 쿼리용 키워드를 이스케이프합니다.
     * MySQL LIKE 와일드카드 문자(%, _)를 이스케이프하여 특수문자 검색을 가능하게 합니다.
     *
     * @param  string  $keyword  검색 키워드
     * @return string 이스케이프된 키워드
     */
    private function escapeLikeKeyword(string $keyword): string
    {
        // MySQL LIKE 와일드카드 문자 이스케이프
        $keyword = str_replace(['\\', '%', '_'], ['\\\\', '\\%', '\\_'], $keyword);

        return $keyword;
    }

    /**
     * HTML 콘텐츠를 일반 텍스트로 변환합니다.
     * 블록 요소(p, div, br, li 등)는 공백으로 치환하여 자연스러운 줄바꿈을 유지합니다.
     *
     * @param  string  $html  HTML 콘텐츠
     * @return string 일반 텍스트
     */
    private function stripHtmlToPlainText(string $html): string
    {
        // HTML 엔티티 디코딩
        $text = html_entity_decode($html, ENT_QUOTES, 'UTF-8');

        // 블록 요소 태그를 공백으로 치환 (줄바꿈 효과)
        $text = preg_replace('/<\/(p|div|li|tr|h[1-6])>/i', ' ', $text);
        $text = preg_replace('/<br\s*\/?>/i', ' ', $text);

        // 나머지 HTML 태그 제거
        $text = strip_tags($text);

        // 연속된 공백을 하나로 정리
        $text = preg_replace('/\s+/', ' ', $text);

        // 앞뒤 공백 제거
        return trim($text);
    }

    /**
     * 게시판 ID와 게시글 ID로 게시글을 조회합니다 (삭제 포함).
     *
     * @param  int  $boardId  게시판 ID
     * @param  int  $id  게시글 ID
     * @return Post|null 게시글 또는 null
     */
    public function findByBoardId(int $boardId, int $id): ?Post
    {
        return Post::query()
            ->where('board_id', $boardId)
            ->withTrashed()
            ->with(['user'])
            ->find($id);
    }

    /**
     * 게시판 ID 기준으로 게시글을 일괄 소프트 삭제합니다.
     *
     * @param  int  $boardId  게시판 ID
     * @return int 삭제된 게시글 수
     */
    public function softDeleteByBoardId(int $boardId): int
    {
        return Post::where('board_id', $boardId)->delete();
    }

    /**
     * 게시판 ID 기준으로 게시글을 일괄 영구 삭제합니다.
     *
     * 게시판 영구 삭제(deleteBoard) 시 사용합니다. 소프트 삭제와 달리
     * deleted_at 마킹이 아니라 레코드를 물리적으로 제거합니다.
     *
     * @param  int  $boardId  게시판 ID
     * @return int 삭제된 게시글 수
     */
    public function forceDeleteByBoardId(int $boardId): int
    {
        return Post::where('board_id', $boardId)->forceDelete();
    }

    /**
     * Eager loading 관계에 board_id 조건을 명시적으로 바인딩합니다.
     *
     * 모델 관계 정의에서 $this->board_id를 사용하면 Eager loading 시
     * null이 되는 문제를 해결하기 위해, 문자열 관계명을 클로저로 변환합니다.
     *
     * @param  array  $relations  Eager loading 관계 배열
     * @param  int|null  $boardId  게시판 ID
     * @return array board_id 조건이 바인딩된 관계 배열
     */
    private function bindBoardIdToRelations(array $relations, ?int $boardId): array
    {
        $boardIdRelations = ['comments', 'attachments', 'replies'];

        $result = [];
        foreach ($relations as $key => $value) {
            // 클로저가 이미 있는 경우 (예: 'comments' => function() {})는 그대로 유지
            if (is_string($key) && is_callable($value)) {
                $result[$key] = $value;

                continue;
            }

            // 문자열 관계명인 경우 board_id 조건 클로저로 변환
            if (is_string($value) && in_array($value, $boardIdRelations)) {
                $result[$value] = function ($query) use ($boardId) {
                    $query->where('board_id', $boardId);
                };

                continue;
            }

            // 그 외 (예: 'user')는 그대로 유지
            $result[$key] = $value;
        }

        return $result;
    }

    /**
     * ID로 게시글을 조회합니다 (게시판 슬러그 불필요, board 관계 포함).
     *
     * @param  int  $id  게시글 ID
     * @return Post|null 게시글 모델 (board 관계 포함) 또는 null
     */
    public function findWithBoard(int $id): ?Post
    {
        return Post::with('board')->find($id);
    }

    /**
     * ID 배열로 게시글 목록을 조회합니다 (board, user, attachments, replies 관계 포함).
     *
     * @param  array<int>  $ids  게시글 ID 배열
     * @return \Illuminate\Database\Eloquent\Collection<int, Post> 게시글 컬렉션
     */
    public function findByIdsWithRelations(array $ids): \Illuminate\Database\Eloquent\Collection
    {
        return Post::whereIn('id', $ids)
            ->with(['board', 'user', 'attachments', 'replies'])
            ->get();
    }

    /**
     * 부모 게시글 ID로 첫 번째 자식(답변) 게시글을 조회합니다 (board 관계 포함).
     *
     * @param  int  $parentPostId  부모 게시글 ID
     * @return Post|null 첫 번째 자식 게시글 (board 관계 포함) 또는 null
     */
    public function findFirstReplyWithBoard(int $parentPostId): ?Post
    {
        return Post::with('board')
            ->where('parent_id', $parentPostId)
            ->oldest()
            ->first();
    }

    /**
     * 비활성 게시판 ID 목록을 조회합니다.
     *
     * boards 테이블은 소규모(~수십 건)이므로 단순 쿼리로 충분합니다.
     * JOIN 대신 whereNotIn 패턴에 사용하여 board_posts 인덱스 활용을 유도합니다.
     *
     * @return array<int> 비활성 게시판 ID 배열
     */
    private function getInactiveBoardIds(): array
    {
        return Board::where('is_active', false)->pluck('id')->all();
    }

    /**
     * 게시글의 comments_count 컬럼을 활성 댓글 수로 재계산해 갱신합니다.
     *
     * @param  int  $postId  게시글 ID
     * @return int 갱신된 카운트 값
     */
    public function recalculateCommentsCount(int $postId): int
    {
        $count = Comment::where('post_id', $postId)->whereNull('deleted_at')->count();
        Post::where('id', $postId)->update(['comments_count' => $count]);

        return $count;
    }

    /**
     * 게시글의 attachments_count 컬럼을 활성 첨부파일 수로 재계산해 갱신합니다.
     *
     * @param  int  $postId  게시글 ID
     * @return int 갱신된 카운트 값
     */
    public function recalculateAttachmentsCount(int $postId): int
    {
        $count = Attachment::where('post_id', $postId)->whereNull('deleted_at')->count();
        Post::where('id', $postId)->update(['attachments_count' => $count]);

        return $count;
    }

    /**
     * 부모 게시글의 replies_count 컬럼을 활성 답글 수로 재계산해 갱신합니다.
     *
     * @param  int  $parentPostId  부모 게시글 ID
     * @return int 갱신된 카운트 값
     */
    public function recalculateRepliesCount(int $parentPostId): int
    {
        $count = Post::where('parent_id', $parentPostId)->whereNull('deleted_at')->count();
        Post::where('id', $parentPostId)->update(['replies_count' => $count]);

        return $count;
    }

    /**
     * 특정 날짜에 작성된 전체 게시판의 게시글 수를 조회합니다 (대시보드 집계용).
     *
     * @param  string  $date  집계 기준 날짜 (Y-m-d)
     * @return int 해당 날짜 작성 게시글 수
     */
    public function countCreatedOnDate(string $date): int
    {
        $start = CarbonImmutable::parse($date)->startOfDay();
        $end = $start->addDay();

        return Post::query()
            ->whereNull('deleted_at')
            ->where('created_at', '>=', $start)
            ->where('created_at', '<', $end)
            ->count();
    }

    /**
     * 전체 게시판에서 최신 게시글을 조회합니다 (대시보드 최신글 카드용).
     *
     * 답글(parent_id != null)은 본문 게시글이 아니므로 제외한다.
     * 다른 메서드(검색/인기/카테고리 목록 등)와 동일한 "원글만" 컨벤션 유지.
     *
     * @param  int  $limit  조회 건수
     * @return \Illuminate\Database\Eloquent\Collection<int, Post> 최신 게시글 컬렉션
     */
    public function getRecentAcrossBoards(int $limit): \Illuminate\Database\Eloquent\Collection
    {
        return Post::query()
            ->whereNull('deleted_at')
            ->whereNull('parent_id')
            ->with(['board', 'user'])
            ->orderByDesc('created_at')
            ->limit($limit)
            ->get();
    }
}
