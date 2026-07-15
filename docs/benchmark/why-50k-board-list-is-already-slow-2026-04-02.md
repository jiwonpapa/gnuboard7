# 5만 게시글에서도 목록이 느린 이유

## 결론

현재 G7 게시판 목록은 `단순 페이지 조회`가 아닙니다.
`목록 조회 + 전체 개수 count + 댓글/답글/첨부 카운트 + 답글 트리 조립`을 한 요청에서 같이 처리해서 5만 건 수준에서도 체감 지연이 발생할 수 있습니다.

## 원인

### 1. 목록 요청마다 전체 원글 수를 다시 셉니다

- 목록 API: `modules/_bundled/sirsoft-board/src/Http/Controllers/User/PostController.php`
- 목록 조회 후 전체 일반글 수를 다시 구함
- 실제 `count()` 실행: `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php`

즉 첫 페이지 20개만 보여줘도, 뒤에서는 전체 원글 수를 다시 세고 있습니다.

### 2. 목록 조회 경로 자체가 무겁습니다

- 목록 진입: `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php`
- `paginate()`가 바로 `buildSortedPostList()`를 호출함

이 함수는 한 번에 아래를 같이 처리합니다.

- 공지글 조회
- 원글 조회
- `user`, `attachments` eager loading
- `comments`, `attachments`, `replies` `withCount()`
- 페이지 원글 기준 답글 재조회
- 메모리에서 원글/답글 병합

즉 구조상 목록 한 번이 가볍지 않습니다.

### 3. 답글 트리 조립 비용을 목록에서도 같이 냅니다

- 답글 조회/반복 병합: `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php`

현재 목록은 루트 글만 페이지네이션한 뒤, 그 글들에 달린 답글을 다시 읽고 메모리에서 트리로 붙입니다.
답글이 거의 없어도 이 경로 자체는 유지됩니다.

### 4. 기본 인덱스가 실제 목록 조건에 정확히 맞지 않습니다

- 테이블/기본 인덱스: `modules/_bundled/sirsoft-board/database/migrations/2026_04_01_000004_create_board_posts_table.php`
- 추가 인덱스: `modules/_bundled/sirsoft-board/database/migrations/2026_04_01_000012_add_indexes_to_board_posts_table.php`

현재 목록 핵심 조건은 대략 이렇습니다.

- `board_id`
- `is_notice = false`
- `parent_id is null`
- `deleted_at is null`
- `status = published`
- `order by created_at` 또는 `id`

그런데 기본 인덱스는 이 조건을 한 번에 받쳐주는 형태가 아닙니다.

### 5. 게시판 총계를 저장하지 않고 매번 계산합니다

- 게시판 스키마: `modules/_bundled/sirsoft-board/database/migrations/2026_04_01_000002_create_boards_table.php`
- 게시판별 게시글 수 집계: `modules/_bundled/sirsoft-board/src/Repositories/BoardRepository.php`
- 서비스에서 임시로 `posts_count`를 붙임: `modules/_bundled/sirsoft-board/src/Services/BoardService.php`

즉 G5처럼 `board` 테이블에 저장 카운트를 들고 가지 않고, 조회 시점에 집계하는 구조입니다.

## 왜 5만에서도 체감이 나쁜가

핵심은 `5만 행 전체를 한 번에 다 읽어서`가 아닙니다.
문제는 5만 규모에서도 이미 아래 조합이 비싸다는 점입니다.

- 목록 조회
- 전체 개수 count
- 행별 `withCount`
- 답글 트리 조립
- 리소스 변환

그래서 5만 건은 현재 읽기 경로 한계를 드러내기에 충분한 크기입니다.

## 해결방안

### 1. 기본 총계는 저장형 카운터로 분리

- `boards.posts_count` 같은 저장 컬럼
- 또는 `board_stats` 같은 집계 테이블

기본 목록/메인 화면에서 매번 `count()`하지 않도록 분리하는 것이 맞습니다.

### 2. 목록과 트리 조립을 분리

- 목록은 `루트 글 페이징`만 먼저 수행
- 답글은 별도 lazy load 또는 현재 페이지 원글에 한정해 최소 비용으로 조회

목록 요청이 트리 전체 조립까지 떠안지 않게 분리해야 합니다.

### 3. `withCount` 남용 줄이기

- `comments_count`, `replies_count`, `attachments_count`를 매 요청 계산하지 말고
- 저장형 집계 또는 더 가벼운 조합으로 분리

지금은 목록 1회마다 행별 카운트 비용이 같이 붙습니다.

### 4. 목록 전용 복합 인덱스 재설계

예를 들면 정렬 축에 따라 아래 계열 인덱스가 필요합니다.

- `(board_id, is_notice, parent_id, deleted_at, status, created_at)`
- 또는 `(board_id, is_notice, parent_id, deleted_at, status, id)`

현재 인덱스는 대형 게시판의 루트 목록 조회에 최적화돼 있지 않습니다.

## 요약

- 5만 건에서도 느린 이유는 `데이터량 자체`보다 `목록 읽기 경로가 무겁기 때문`입니다.
- 현재 구조는 `조회`, `집계`, `트리 조립`, `카운트`를 한 번에 처리합니다.
- 해결하려면 `저장형 카운터`, `목록/트리 분리`, `withCount 축소`, `목록 전용 인덱스`가 필요합니다.
