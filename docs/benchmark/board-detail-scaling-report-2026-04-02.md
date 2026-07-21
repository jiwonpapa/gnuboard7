# 게시판 상세/목록 장애 요약 리포트

- 작성일: 2026-04-02
- 환경: `https://gnuboard7.cc`
- 목적: 대용량 게시판에서 목록/상세가 왜 느리거나 터지는지 핵심만 정리

## 결론

- `게시글 본문 누락` 문제는 아닙니다.
- `상세`는 이전/다음글 계산 때문에 게시판 전체 정렬 리스트를 만들면서 터집니다.
- `목록`도 같은 정렬/트리 조립 로직을 공유하고, 메인 목록 SQL 1개가 이미 `약 650~700ms`를 먹습니다.
- 즉 원인은 `데이터량 자체`보다 `조회 알고리즘`입니다.

## 현재 재현 결과

### `free` 게시판

- 총 게시글: `50,001`
- 현재 웹 메모리 `256M`에서 상세 조회 `200 OK`
- 예시 글: `1050002`

### `gallery` 게시판

- 총 게시글: `100,001`
- 현재 웹 메모리 `256M`에서 상세 조회 `500`
- 예시 글: `1145200`

## 로그에서 확인된 사실

로그 파일 위치:

- 앱 로그: `/home/gnuboard7/public_html/storage/logs/laravel-2026-04-02.log`
- 큐 로그: `/home/gnuboard7/public_html/storage/logs/queue-worker.log`
- 벤치 로그: `/home/gnuboard7/public_html/storage/logs/benchmark-queue.log`
- SQL 로그: `/home/gnuboard7/public_html/storage/logs/query-2026-04-02.log`

실제로 남아 있는 치명 로그:

- `128M` 구간:
  - `Allowed memory size of 134217728 bytes exhausted`
  - 위치: `Illuminate/Database/Eloquent/Builder.php:469`
- `512M` 구간:
  - `Allowed memory size of 536870912 bytes exhausted`
  - 위치: `Illuminate/Database/Eloquent/Concerns/HasAttributes.php:785`

추가 관찰:

- `100,001`건 `gallery` 상세는 `4G`에서도 실패했습니다.
- 따라서 `10만` 구간 실패는 메모리보다 쿼리 구조 문제입니다.
- 일부 `500`은 로그 파일보다 HTTP 응답에서 더 잘 드러납니다.
- 이유는 컨트롤러가 예외를 잡아 `500` 응답으로 반환하고, 별도 `Log::error()`를 남기지 않기 때문입니다.

## 목록 병목 요약

- `humor` 목록에서 가장 큰 병목은 `g7_board_posts` 메인 조회 1건입니다.
- SQL 로그 기준 실측:
  - 메인 목록 쿼리: `약 656~672ms`
  - 게시판별 게시글 집계 쿼리: `약 95ms`
- 메인 쿼리는 다음 조건을 한 번에 처리합니다.
  - `board_id`
  - `is_notice = ''`
  - `parent_id is null`
  - `deleted_at is null`
  - `order by created_at desc`
  - `comments_count`, `replies_count`, `attachments_count` 서브쿼리
- 즉 목록 지연의 중심은 `통합 테이블 자체`보다 `루트 글 목록 조회 + 서브쿼리 + 트리 조립` 조합입니다.

## 왜 터지는가

상세 조회는 글 1건만 읽지 않습니다.

1. 상세 컨트롤러가 항상 이전/다음글을 같이 구합니다.
2. 저장소가 현재 글 주변 2건만 찾는 게 아니라 게시판 전체 정렬 리스트를 만듭니다.
3. 그 과정에서 원글 전체를 메모리에 올립니다.
4. 다시 원글 ID 전체를 `whereIn(parent_id, [...])`로 넘깁니다.

핵심 코드:

- 상세에서 이전/다음글 강제 호출:
  - [PostController.php](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/modules/_bundled/sirsoft-board/src/Http/Controllers/User/PostController.php#L159)
- 상세가 전체 리스트를 만드는 시작점:
  - [PostRepository.php](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php#L558)
- 원글 전체 조회:
  - [PostRepository.php](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php#L739)
- 전체 원글 ID를 `whereIn(parent_id, ...)`로 연결:
  - [PostRepository.php](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php#L745)

## 목록이 느린 이유

- 목록도 같은 `buildSortedPostList()`를 사용합니다.
  - [PostRepository.php](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php#L36)
- 즉 목록도 원글/답글 트리를 조립하는 비용을 같이 집니다.
- 인덱스는 `board_id + created_at`, `board_id + status`, `board_id + is_notice` 수준이라,
  실제 목록 조건인 `board_id + is_notice + parent_id is null + deleted_at is null + 정렬키`를 한 번에 받쳐주지 못합니다.
- `EXPLAIN` 기준으로도 메인 목록 조회는 여전히 `created_at` 축 기존 인덱스를 선호했고, 단일 메인 쿼리 비용이 큽니다.

관련 인덱스 정의:

- [create_board_posts_table.php](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/modules/_bundled/sirsoft-board/database/migrations/2026_04_01_000004_create_board_posts_table.php#L50)
- [add_indexes_to_board_posts_table.php](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.5-performance-lab/modules/_bundled/sirsoft-board/database/migrations/2026_04_01_000012_add_indexes_to_board_posts_table.php#L20)

## 핵심 포인트

- `5만`은 메모리 병목 구간입니다.
- `10만`은 메모리를 올려도 계속 실패하므로 쿼리/알고리즘 병목입니다.
- 상세 붕괴의 직접 원인은 `이전/다음글 계산을 위한 전체 게시판 스캔`입니다.
- 목록 지연의 핵심은 `루트 목록 메인 SQL 1건 자체가 무겁다`는 점입니다.
- 결론적으로 현재 G7 보드 모듈은 `대형 평면 게시판` 상세/목록 조회에 스케일링하지 않습니다.
