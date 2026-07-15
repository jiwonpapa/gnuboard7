# G7 게시판 읽기 경로 스케일링 버그 리포트

- 작성일: 2026-04-02
- 대상: 그누보드7 `sirsoft-board`
- 목적: 개발사 전달용 재현 가능한 버그 리포트

## 요약

- 대형 게시판에서 `목록 조회`가 수 초 단위로 느려집니다.
- 대형 게시판에서 `내용 보기`는 특정 규모 이상부터 `500 Internal Server Error`로 실패합니다.
- 원인은 더미 데이터 자체보다 `게시판 읽기 경로의 조회 알고리즘`입니다.

## 테스트 환경

- 서버: `Ubuntu 24.04.4 LTS`
- CPU: `16 vCPU`
- 메모리: `62 GiB`
- PHP: `8.4.19`
- 웹 실행 방식: `Apache + mod_php`
- 기본 Apache PHP 설정:
  - `memory_limit=128M`
  - `max_execution_time=30`
  - `max_input_time=60`
  - `default_socket_timeout=60`

## 재현 조건

### 케이스 1: 목록 조회 지연

- 게시판: `humor`
- 게시글 규모: 약 `20만` 건대
- 관찰 결과:
  - 첫 페이지 목록 API TTFB가 `약 4~5초` 구간까지 올라감
  - 쿼리 로그 기준 메인 목록 SQL 1건이 `약 656~672ms`

### 케이스 2: 내용 보기 500

- 게시판: `gallery`
- 게시글 규모: `100,001` 건
- 재현 경로 예시:
  - 사용자 상세 보기 경로: `/board/{slug}/{postId}`
  - 상세 API 경로: `/api/modules/sirsoft-board/boards/{slug}/posts/{postId}`
- 관찰 결과:
  - 브라우저 콘솔: `500 Internal Server Error`
  - API 응답 단계에서 실패

### 케이스 3: 5만 구간 메모리 병목

- 게시판: `free`
- 게시글 규모: `50,001` 건
- 과거 테스트 결과:
  - 웹 메모리 `128M`, `512M`에서 메모리 관련 오류 발생
  - 웹 메모리 상향 시 통과 가능

## 기대 결과

- 목록 조회는 게시글 수가 커져도 선형적으로 붕괴하지 않아야 합니다.
- 내용 보기는 `게시글 1건 조회` 수준으로 동작해야 하며, 게시판 전체 규모 때문에 `500`이 나면 안 됩니다.

## 실제 결과

- 목록은 대형 게시판에서 메인 조회 1건이 이미 무거워집니다.
- 내용 보기는 본문 데이터가 있어도, 이전글/다음글 계산 단계에서 먼저 실패합니다.

## 기술적 원인

### 1. 내용 보기 경로가 게시글 1건 조회가 아님

- 상세 조회 시 이전글/다음글을 항상 같이 계산합니다.
- 이 과정에서 게시판 전체 정렬 리스트를 먼저 구성합니다.
- 이후 원글 ID 전체를 `whereIn(parent_id, [...])`로 다시 조회합니다.
- 결과:
  - `5만` 구간: 메모리 병목
  - `10만` 구간: `Prepared statement contains too many placeholders`

관련 위치:

- `modules/_bundled/sirsoft-board/src/Http/Controllers/User/PostController.php`
- `modules/_bundled/sirsoft-board/src/Services/PostService.php`
- `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php`

### 2. 목록 조회도 같은 정렬/트리 조립 비용을 공유

- 목록 경로도 동일한 정렬 리스트 생성 흐름을 사용합니다.
- 루트 게시글 조회에 더해:
  - `comments_count`
  - `replies_count`
  - `attachments_count`
  서브쿼리를 같이 계산합니다.
- 결과적으로 메인 SQL 1건이 이미 수백 ms를 사용합니다.

## 로그/오류 근거

- 실제 확인된 오류는 아래 3종입니다.

### 1. 128M 구간 메모리 부족

- `Allowed memory size of 134217728 bytes exhausted (tried to allocate 4194312 bytes)`
- 발생 위치:
  - `vendor/laravel/framework/src/Illuminate/Database/Eloquent/Builder.php:469`

### 2. 512M~256M 구간 메모리 부족

- `Allowed memory size of 536870912 bytes exhausted`
- `Allowed memory size of 268435456 bytes exhausted`
- 대표 발생 위치:
  - `vendor/laravel/framework/src/Illuminate/Database/Eloquent/Concerns/HasAttributes.php:785`
  - `vendor/laravel/framework/src/Illuminate/Database/Eloquent/Model.php:701`

### 3. 10만 원글 구간 placeholder 초과

- `SQLSTATE[HY000]: General error: 1390 Prepared statement contains too many placeholders`
- 의미:
  - 상세 보기에서 이전/다음글 계산을 위해 원글 ID 전체를 `whereIn(parent_id, [...])`로 넘기다가 실패

### 참고 로그 위치

- 앱 로그:
  - `storage/logs/laravel-YYYY-MM-DD.log`
- SQL 로그:
  - `storage/logs/query-YYYY-MM-DD.log`

## 영향도

- 게시판이 일정 규모를 넘으면 목록 체감 속도가 급격히 나빠집니다.
- 게시판이 더 커지면 내용 보기 자체가 실패합니다.
- 즉 현재 구조는 `대형 평면 게시판`에 대해 읽기 경로가 스케일하지 않습니다.

## 한 줄 결론

- 이 버그의 본질은 `통합 테이블` 자체보다 `게시판 읽기 경로가 전체 게시판을 다시 조립하는 설계`에 있습니다.
