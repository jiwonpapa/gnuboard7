<?php

namespace Modules\Sirsoft\Board\Http\Resources;

use App\Enums\PermissionType;
use App\Http\Resources\BaseApiCollection;
use Illuminate\Http\Request;
use Modules\Sirsoft\Board\Traits\ChecksBoardPermission;

/**
 * 게시글 목록 리소스 컬렉션
 *
 * 게시글 목록을 페이지네이션과 함께 반환합니다.
 * 순번, 공지사항, 답글 표시를 지원합니다.
 */
class PostCollection extends BaseApiCollection
{
    use ChecksBoardPermission;

    private const INTERNAL_TOTAL_EXACT_ATTRIBUTE = '__g7_normal_posts_total_is_exact';

    private const INTERNAL_TOTAL_RELATION_ATTRIBUTE = '__g7_normal_posts_total_relation';

    /**
     * 전체 일반 게시글(원글) 수
     */
    private ?int $totalNormalPosts = null;

    /**
     * 정렬 방향
     */
    private string $orderDirection = 'desc';

    /**
     * 제한형 검색 페이지네이션인지 여부
     */
    private bool $searchResult = false;

    /** FULLTEXT 보호 fallback으로 검색 범위가 제한됐는지 여부 */
    private bool $searchTruncated = false;

    /**
     * 전체 일반 게시글 수를 설정합니다.
     *
     * @param  int  $total  전체 일반 게시글 수
     */
    public function setTotalNormalPosts(int $total): void
    {
        $this->totalNormalPosts = $total;
    }

    /**
     * 정렬 방향을 설정합니다.
     *
     * @param  string  $direction  정렬 방향 (asc 또는 desc, 대소문자 무관)
     */
    public function setOrderDirection(string $direction): void
    {
        // 대소문자 무관하게 처리하기 위해 소문자로 정규화
        $this->orderDirection = strtolower($direction);
    }

    public function setSearchResult(bool $searchResult): void
    {
        $this->searchResult = $searchResult;
    }

    /**
     * 리소스 컬렉션을 배열로 변환합니다.
     *
     * @param  Request  $request  HTTP 요청
     * @return array<string, mixed> 변환된 배열 데이터
     */
    public function toArray(Request $request): array
    {
        $normalPostsTotal = $this->totalNormalPosts ?? 0;
        $currentPage = $this->currentPage();
        $perPage = $this->perPage();
        $isDescending = $this->orderDirection === 'desc';
        [$totalIsExact, $totalRelation] = $this->extractTotalMetadata($normalPostsTotal, $currentPage);

        // 현재 페이지의 일반 게시글 시작 순번 계산
        if ($totalIsExact) {
            $currentNumber = $this->calculateStartNumber($normalPostsTotal, $currentPage, $perPage, $isDescending);
        } else {
            $normalCount = $this->collection->filter(
                fn ($post) => ! $post->is_notice && $post->parent_id === null
            )->count();
            $offset = ($currentPage - 1) * $perPage;
            $currentNumber = $isDescending ? $offset + $normalCount : $offset + 1;
        }

        $data = $this->collection->map(function ($post) use ($request, &$currentNumber, $isDescending) {
            $postData = (new PostResource($post))->toListArray($request);
            $postData['row_type'] = $this->getRowType($post);
            $postData['number'] = $this->getRowNumber($post, $currentNumber, $isDescending);

            return $postData;
        });

        $pagination = $this->buildPagination(
            $normalPostsTotal,
            $currentPage,
            $perPage,
            $isDescending,
            $data->count(),
            $totalIsExact,
            $totalRelation
        );

        return [
            'data' => $data,
            'pagination' => $pagination,
        ];
    }

    /** @return array{0: bool, 1: string} */
    private function extractTotalMetadata(int $total, int $currentPage): array
    {
        if (method_exists($this->resource, 'searchMetadata')) {
            $metadata = $this->resource->searchMetadata();
            if (array_key_exists('total_is_exact', $metadata)) {
                $this->searchTruncated = (bool) ($metadata['fallback_used'] ?? false);
                foreach ($this->collection as $post) {
                    $post->offsetUnset(self::INTERNAL_TOTAL_EXACT_ATTRIBUTE);
                    $post->offsetUnset(self::INTERNAL_TOTAL_RELATION_ATTRIBUTE);
                }

                return [
                    (bool) $metadata['total_is_exact'],
                    (string) ($metadata['total_relation'] ?? 'gte'),
                ];
            }
        }

        foreach ($this->collection as $post) {
            $exact = $post->getAttribute(self::INTERNAL_TOTAL_EXACT_ATTRIBUTE);
            $relation = $post->getAttribute(self::INTERNAL_TOTAL_RELATION_ATTRIBUTE);
            $post->offsetUnset(self::INTERNAL_TOTAL_EXACT_ATTRIBUTE);
            $post->offsetUnset(self::INTERNAL_TOTAL_RELATION_ATTRIBUTE);

            if ($exact !== null) {
                return [(bool) $exact, (string) ($relation ?? ((bool) $exact ? 'eq' : 'gte'))];
            }
        }

        if ($total === 0 && $currentPage > 1 && $this->collection->isEmpty()) {
            return [false, 'unknown'];
        }

        return [true, 'eq'];
    }

    /**
     * 게시판 정보 및 권한이 포함된 형태의 배열을 반환합니다.
     *
     * @param  array  $boardInfo  게시판 정보 배열
     * @return array<string, mixed> 게시판 정보 및 권한이 포함된 게시글 컬렉션
     */
    public function withBoardInfo(array $boardInfo): array
    {
        $baseData = $this->toArray(request());
        $showCategory = $boardInfo['show_category'] ?? false;
        $slug = $boardInfo['slug'] ?? null;

        $postsData = collect($baseData['data'])->map(function ($post) use ($showCategory, $slug) {
            $post['show_category'] = $showCategory;
            $post['slug'] = $slug;

            return $post;
        })->toArray();

        return [
            'data' => $postsData,
            'pagination' => $baseData['pagination'],
            'board' => $boardInfo,
            'abilities' => $this->getBoardPermissions($slug),
        ];
    }

    // =========================================================================
    // 헬퍼 메서드 - 순번 계산
    // =========================================================================

    /**
     * 시작 순번을 계산합니다.
     *
     * @param  int  $total  전체 게시글 수
     * @param  int  $currentPage  현재 페이지
     * @param  int  $perPage  페이지당 항목 수
     * @param  bool  $isDescending  내림차순 여부
     * @return int 시작 순번
     */
    private function calculateStartNumber(int $total, int $currentPage, int $perPage, bool $isDescending): int
    {
        if ($isDescending) {
            // 내림차순: 큰 숫자부터 (28, 27, 26, ...)
            return $total - (($currentPage - 1) * $perPage);
        }

        // 오름차순: 작은 숫자부터 (1, 2, 3, ...)
        return (($currentPage - 1) * $perPage) + 1;
    }

    /**
     * 게시글의 행 유형을 반환합니다.
     *
     * @param  mixed  $post  게시글 모델
     * @return string 행 유형 (notice, reply, normal)
     */
    private function getRowType($post): string
    {
        if ($post->is_notice) {
            return 'notice';
        }

        if ($post->parent_id !== null) {
            return 'reply';
        }

        return 'normal';
    }

    /**
     * 게시글의 순번을 반환합니다.
     *
     * @param  mixed  $post  게시글 모델
     * @param  int  &$currentNumber  현재 순번 (참조)
     * @param  bool  $isDescending  내림차순 여부
     * @return string|int 순번 또는 라벨
     */
    private function getRowNumber($post, int &$currentNumber, bool $isDescending): string|int
    {
        if ($post->is_notice) {
            return __('sirsoft-board::messages.post.notice');
        }

        if ($post->parent_id !== null) {
            return __('sirsoft-board::messages.post.reply');
        }

        $number = $currentNumber;
        $currentNumber = $isDescending ? $currentNumber - 1 : $currentNumber + 1;

        return $number;
    }

    // =========================================================================
    // 헬퍼 메서드 - 페이지네이션
    // =========================================================================

    /**
     * 페이지네이션 정보를 구성합니다.
     *
     * @param  int  $total  전체 게시글 수
     * @param  int  $currentPage  현재 페이지
     * @param  int  $perPage  페이지당 항목 수
     * @param  bool  $isDescending  내림차순 여부
     * @param  int  $currentPageItemCount  현재 페이지 항목 수
     * @return array<string, mixed> 페이지네이션 정보
     */
    private function buildPagination(
        int $total,
        int $currentPage,
        int $perPage,
        bool $isDescending,
        int $currentPageItemCount,
        bool $totalIsExact,
        string $totalRelation
    ): array {
        $lastPage = $total > 0 ? (int) ceil($total / $perPage) : 1;
        if (! $totalIsExact) {
            $lastPage = $this->hasMorePages()
                ? max($lastPage, $currentPage + 1)
                : max($lastPage, $currentPage);
        }

        if ($totalIsExact) {
            [$from, $to] = $this->calculateFromTo($total, $currentPage, $perPage, $isDescending);
        } else {
            $normalItemCount = $this->collection->filter(
                fn ($post) => ! $post->is_notice && $post->parent_id === null
            )->count();
            $offset = ($currentPage - 1) * $perPage;
            if ($normalItemCount === 0) {
                [$from, $to] = [0, 0];
            } elseif ($isDescending) {
                [$from, $to] = [$offset + $normalItemCount, $offset + 1];
            } else {
                [$from, $to] = [$offset + 1, $offset + $normalItemCount];
            }
        }

        $pagination = [
            'total' => $total,
            'all_total' => $total,
            'total_is_exact' => $totalIsExact,
            'total_relation' => $totalRelation,
            'count' => $currentPageItemCount,
            'per_page' => $perPage,
            'current_page' => $currentPage,
            'last_page' => $lastPage,
            'from' => $from,
            'to' => $to,
            'has_more_pages' => $this->hasMorePages(),
        ];

        if ($this->searchResult) {
            $pagination['result_cap'] = (int) config('benchmark.board_search_sync_cap', 1000);
            $pagination['search_truncated'] = $this->searchTruncated;
        }

        return $pagination;
    }

    /**
     * from/to 값을 계산합니다.
     *
     * @param  int  $total  전체 게시글 수
     * @param  int  $currentPage  현재 페이지
     * @param  int  $perPage  페이지당 항목 수
     * @param  bool  $isDescending  내림차순 여부
     * @return array{int, int} [from, to]
     */
    private function calculateFromTo(int $total, int $currentPage, int $perPage, bool $isDescending): array
    {
        if ($total === 0) {
            return [0, 0];
        }

        if ($isDescending) {
            // 내림차순: 큰 숫자 → 작은 숫자
            $from = $total - (($currentPage - 1) * $perPage);
            $to = max($from - $perPage + 1, 1);
        } else {
            // 오름차순: 작은 숫자 → 큰 숫자
            $from = (($currentPage - 1) * $perPage) + 1;
            $to = min($currentPage * $perPage, $total);
        }

        return [$from, $to];
    }

    // =========================================================================
    // 권한 관련 메서드
    // =========================================================================

    /**
     * 게시판 권한 정보를 반환합니다.
     *
     * @param  string|null  $slug  게시판 슬러그
     * @return array<string, bool> 권한 정보
     */
    private function getBoardPermissions(?string $slug): array
    {
        if (! $slug) {
            return [];
        }

        $isAdmin = $this->isAdminRequest(request());

        if ($isAdmin) {
            return $this->getAdminPermissions($slug);
        }

        return $this->getUserPermissions($slug);
    }

    /**
     * Admin 권한 정보를 반환합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @return array<string, bool> Admin 권한 정보
     */
    private function getAdminPermissions(string $slug): array
    {
        return [
            'can_read' => $this->checkBoardPermission($slug, 'admin.posts.read'),
            'can_write' => $this->checkBoardPermission($slug, 'admin.posts.write'),
            'can_read_secret' => $this->checkBoardPermission($slug, 'admin.posts.read-secret'),
            'can_read_comments' => $this->checkBoardPermission($slug, 'admin.comments.read'),
            'can_write_comments' => $this->checkBoardPermission($slug, 'admin.comments.write'),
            'can_upload' => $this->checkBoardPermission($slug, 'admin.attachments.upload'),
            'can_download' => $this->checkBoardPermission($slug, 'admin.attachments.download'),
            'can_manage' => $this->checkBoardPermission($slug, 'admin.manage'),
        ];
    }

    /**
     * User 권한 정보를 반환합니다.
     *
     * @param  string  $slug  게시판 슬러그
     * @return array<string, bool> User 권한 정보
     */
    private function getUserPermissions(string $slug): array
    {
        $canManage = $this->checkBoardPermission($slug, 'manager', PermissionType::User);

        return [
            'can_read' => $this->checkBoardPermission($slug, 'posts.read', PermissionType::User),
            'can_write' => $this->checkBoardPermission($slug, 'posts.write', PermissionType::User),
            'can_read_secret' => $this->checkBoardPermission($slug, 'posts.read-secret', PermissionType::User),
            'can_read_comments' => $this->checkBoardPermission($slug, 'comments.read', PermissionType::User),
            'can_write_comments' => $this->checkBoardPermission($slug, 'comments.write', PermissionType::User),
            'can_upload' => $this->checkBoardPermission($slug, 'attachments.upload', PermissionType::User),
            'can_download' => $this->checkBoardPermission($slug, 'attachments.download', PermissionType::User),
            'can_manage' => $canManage,
            'can_view_deleted' => $canManage,
            // 유저 화면에서 관리자 게시판 화면으로 진입 가능한지 여부 (Admin 타입 admin.manage 권한 보유자만 true).
            // 유저용 can_manage(게시판 매니저)와 다른, 관리자 화면 접근 게이트 전용 플래그.
            'can_access_admin' => $this->checkBoardPermission($slug, 'admin.manage'),
        ];
    }

    /**
     * Admin 요청 여부를 확인합니다.
     *
     * Controller 네임스페이스로 판단합니다.
     *
     * @param  Request  $request  HTTP 요청
     * @return bool Admin 요청 여부
     */
    private function isAdminRequest(Request $request): bool
    {
        $controller = $request->route()?->getController();

        if (! $controller) {
            return false;
        }

        return str_contains(get_class($controller), '\\Admin\\');
    }
}
