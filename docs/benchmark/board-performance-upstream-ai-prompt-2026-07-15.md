# 그누보드7 대용량 게시판 성능 개선 AI 실행 프롬프트

아래 내용을 그대로 AI 코딩 에이전트에게 전달한다.

---

당신은 그누보드7과 Laravel 대용량 조회 최적화를 담당하는 시니어 개발자다.

## 목표

그누보드7 공식 레포지터리의 `7.0.4` 태그를 기준으로 `sirsoft-board` 게시판 목록 성능을 개선하라.

현재 구조는 기본 목록에서 전체 COUNT를 매번 실행하지 않지만, 다음 병목이 확인됐다.

1. 깊은 OFFSET에서 제목·본문 미리보기·작성자·통계 등 넓은 행을 OFFSET만큼 읽고 버린다.
2. 비회원 권한은 역할 권한을 eager load한 뒤에도 권한별 `EXISTS`를 반복한다.
3. 활성 모듈과 언어팩을 같은 요청에서 중복 조회한다.
4. 답글이 없는 페이지에서도 답글 확인 SQL이 실행된다.
5. 공지와 인라인 답글 수에 상한이 없어 목록 응답이 비정상적으로 커질 수 있다.
6. 검색·분류·상태·작성자·기간 필터 목록은 동일 조건에서도 전체 COUNT를 반복한다.
7. ID순·조회수순 목록에 필터와 정렬을 함께 만족하는 복합 인덱스가 없다.

목표는 API 응답 필드와 기존 페이지 번호 계약을 유지하면서 깊은 페이지의 넓은 row lookup을 제거하고, 첫 페이지의 반복 SQL을 줄이는 것이다.

## 작업 원칙

- 최신 대상 브랜치의 실제 코드를 먼저 읽고 메서드·모델·인덱스 구조를 확인한다.
- 아래 라인 번호를 맹목적으로 맞추지 말고 클래스와 메서드 이름을 기준으로 수정한다.
- 게시판 목록 API의 기존 URL, 응답 필드, 정렬 순서, 공지·답글 표시 의미를 깨지 않는다.
- 인증·권한·비밀글·삭제글·관리자 scope 조건을 우회하지 않는다.
- 웹 요청에서 shell 명령이나 장시간 백그라운드 작업을 실행하지 않는다.
- 성능 개선을 이유로 본문·권한·삭제 조건을 누락하지 않는다.
- 인덱스 migration은 `down()`을 구현하고 이번 작업에서 추가한 인덱스만 제거한다.
- 단순 추정으로 완료 처리하지 말고 SQL 로그, `EXPLAIN ANALYZE`, 회귀 테스트, K6로 검증한다.

## 필수 구현

### 1. 목록을 ID-only deferred join으로 변경

대상:

- `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php`
- `PostRepository::buildSortedPostList()`

구현 요구사항:

1. 페이지네이션 쿼리에서는 `simplePaginate($perPage, ['id'], 'page', $currentPage)`처럼 현재 페이지의 ID만 먼저 조회한다.
2. ID 쿼리에는 기존 board, notice, parent, deleted, permission scope, 검색 필터, 정렬 조건이 모두 유지돼야 한다.
3. 선택된 ID만 별도 쿼리로 조회해 기존 목록 컬럼, 관계, `withCount`를 로딩한다.
4. `WHERE IN` 조회 결과는 DB 반환 순서를 신뢰하지 말고 최초 ID 배열 순서로 복원한다.
5. `withTrashed`, 삭제글 제외, 빈 ID 배열, board scope를 모두 처리한다.
6. 페이지네이터의 `hasMorePages`, 현재 페이지, 페이지당 개수와 기존 `PostCollection` 응답을 유지한다.
7. 페이지네이션이 없는 내부 전체 조회 경로에는 기존 relations와 `withCount`가 유지돼야 한다.

참고 구현 위치:

- ID 선조회: 현재 검증 패치의 `PostRepository.php:830-846`
- 선택 행 hydration: 현재 검증 패치의 `PostRepository.php:939-989`

### 2. 공지와 답글 폭증 방지

같은 Repository에서 다음 정책을 적용한다.

- 첫 페이지 공지는 최대 10건만 목록 앞에 포함한다.
- 현재 페이지 원글의 `replies_count`가 모두 0이면 답글 SQL을 실행하지 않는다.
- 한 페이지에 인라인으로 펼치는 전체 답글은 최대 100건으로 제한한다.
- 다음 depth 탐색도 `replies_count > 0`인 답글만 이어간다.
- 답글 조회에도 relations와 `withCount`를 누락하지 않는다.

참고 구현 위치:

- 상한 상수: `PostRepository.php:36-39`
- 공지 제한: `PostRepository.php:769-774`
- 답글 생략·제한: `PostRepository.php:860-905`

상한 정책이 기존 제품 요구와 충돌한다면 임의 삭제하지 말고 설정값 또는 별도 답글 API로 전환하는 설계를 제시하라.

### 3. 필터 COUNT 단기 캐시

대상:

- `modules/_bundled/sirsoft-board/src/Services/PostService.php`
- `PostService::getCachedNormalPostCount()`

구현 요구사항:

- 무필터 기본 목록의 기존 total 정책은 유지한다.
- 검색, 검색 필드, 분류, 게시판 분류, 상태, 사용자, 시작일, 종료일, 삭제글 포함 여부, user/admin context를 캐시 키에 포함한다.
- 배열 key를 정렬하고 BackedEnum은 scalar value로 바꿔 결정론적 키를 만든다.
- 정규화 결과를 JSON 직렬화하고 SHA-256으로 해시한다.
- 동일 필터 COUNT를 60초 동안 `board-stats` tag로 재사용한다.
- 서로 다른 필터나 context가 같은 키를 공유하지 않도록 테스트한다.

참고 구현 위치: `PostService.php:119-183`

### 4. 비회원 권한 N+1 제거

대상:

- `app/Http/Middleware/PermissionMiddleware.php`
- `PermissionMiddleware::checkGuestPermission()`

`getGuestRole()`이 이미 `permissions`를 eager load하므로, `permissions()` 관계 쿼리의 `exists()`를 반복하지 말고 로드된 `$guestRole->permissions` 컬렉션에서 identifier와 permission type을 함께 비교하라.

합격 조건:

- 첫 guest 권한 확인 후 같은 요청에서 다른 권한을 확인할 때 추가 SQL이 0회여야 한다.
- permission type이 다른 동명 권한을 잘못 허용하면 안 된다.

참고 구현 위치: `PermissionMiddleware.php:121-133`

### 5. 부트스트랩 중복 SELECT 제거

대상:

- `app/Providers/ModuleRouteServiceProvider.php`
- `app/Services/LanguagePack/LanguagePackRegistry.php`

구현 요구사항:

- 활성 모듈 목록은 `Module` 모델을 매 요청 직접 조회하지 말고 `ModuleManager::getActiveModuleIdentifiers()`의 상태 캐시를 사용한다.
- 코어 locale 목록은 repository를 다시 조회하지 말고 같은 Registry의 `getActivePacks()` 요청 중 캐시 결과에서 추출한다.
- 활성화·비활성화 직후 기존 invalidate 동작은 유지한다.

### 6. 정렬용 복합 인덱스 추가

새 board module migration을 작성한다.

필수 인덱스:

```text
idx_board_posts_list_id
(board_id, is_notice, parent_id, deleted_at, id)

idx_board_posts_list_views
(board_id, is_notice, parent_id, deleted_at, view_count, id)
```

추가 판단:

- 기본 `created_at` 정렬은 기존 `idx_board_posts_list_count`가 ID-only 쿼리를 covering하는지 `EXPLAIN ANALYZE`로 확인한다.
- `title`, `author_name` 정렬도 공식 지원 대상이다. 대규모 데이터에서 filesort가 발생하는지 측정하고, 인덱스를 추가할 경우 컬럼 타입·키 길이·디스크·쓰기 비용을 수치로 보고한다.
- 검증 없이 대형 문자열 인덱스를 자동 추가하지 않는다.

### 7. 버전과 변경 이력 동기화

board module 버전을 1.0.2에서 1.1.0으로 올린다.

동기화 대상:

- `modules/_bundled/sirsoft-board/module.json`
- `modules/_bundled/sirsoft-board/composer.json`
- `modules/_bundled/sirsoft-board/package.json`
- `modules/_bundled/sirsoft-board/package-lock.json`
- `modules/_bundled/sirsoft-board/CHANGELOG.md`
- 루트 `CHANGELOG.md`

### 8. 반복 비교용 ON/OFF 하네스

동일 서버에서 원본과 개선 경로를 반복 비교할 수 있게 다음 명령을 제공하라.

```text
on                optimized 코드 경로 + 신규 인덱스 visible
off               G7 7.0.4 원본 코드 경로 + 신규 인덱스 invisible
status            소스 체크섬, 실제 코드 경로, 인덱스, 활성 모듈 상태
restore-original  공식 7.0.4 파일 복원 + 신규 인덱스와 migration 기록 제거
```

요구사항:

- runtime variant는 config를 통해 선택하고 기본값은 optimized로 한다.
- `off`는 읽기 성능을 빠르게 비교하기 위한 모드다. invisible index도 쓰기 시 유지된다는 한계를 표시한다.
- exact restore는 명시적 확인 옵션 없이는 실행하지 않는다.
- 전환 전 5초 이상 실행 중인 DB 쿼리가 있으면 DDL을 시작하지 않는다.
- 자동으로 장기 쿼리를 죽이지 않는다.
- 번들 모듈과 활성 모듈을 함께 동기화한다.
- 소스 체크섬, 최근 백업, 동시 실행 lock, cache clear, PHP-FPM reload, HTTP smoke를 포함한다.
- exact restore 후 `on`으로 인덱스와 optimized 소스를 다시 생성할 수 있어야 한다.

검증 구현 예시: `scripts/benchmark/board-performance-toggle.sh`

## 필수 테스트

다음 회귀 테스트를 추가하거나 기존 테스트에 포함한다.

1. 페이지 2 이상에서 ID-only SQL이 먼저 실행된다.
2. 넓은 컬럼과 `SUBSTRING(content, ...)` 쿼리는 선택된 ID에만 실행된다.
3. ID 선조회 후 결과 순서가 원래 정렬과 같다.
4. 답글이 없으면 `parent_id IN (...)` SQL이 실행되지 않는다.
5. 공지가 12건이어도 목록에는 10건만 포함된다.
6. 동일 필터 COUNT를 두 번 호출해도 COUNT SQL은 1회다.
7. guest 권한 두 번째 확인은 SQL 0회다.
8. 활성 언어팩 조회 후 core locale 조회에서 언어팩 SQL은 총 1회다.
9. 삭제글 포함, 필터, 모든 허용 정렬, 공지, 답글, 빈 페이지 회귀를 검증한다.

테스트 파일 예시:

- `modules/_bundled/sirsoft-board/tests/Unit/PostRepositoryPaginationPerformanceTest.php`
- `modules/_bundled/sirsoft-board/tests/Unit/PostServiceSortTest.php`
- `tests/Feature/Middleware/PermissionMiddlewareTest.php`
- `tests/Unit/Services/LanguagePack/LanguagePackRegistryTest.php`

Pint와 PHP syntax check를 수행한다. 전체 board module suite도 실행하고 실패가 있으면 패치 회귀와 테스트 환경 실패를 근거로 분리한다. 패치 전 기준선 없이 기존 실패라고 단정하지 않는다.

## 성능 검증 방법

### 데이터셋

최소 다음 세 구간을 서로 다른 게시판으로 준비한다.

- 원글 20만 건
- 원글 40만 건
- 원글 120만 건 이상

댓글 수는 별도로 기록한다. 댓글은 목록 OFFSET 스캔 행 수와 직접 합산하지 않는다는 점을 구분한다.

### 첫 페이지 K6

- 게시판별 독립 실행. 세 게시판을 동시에 테스트하지 않는다.
- 5 VU와 10 VU를 각각 30초 이상 실행한다.
- 각 VU는 요청 후 1초 think time을 둔다.
- `Cache-Control: no-cache`를 사용한다.
- HTTP 200, `current_page=1`, 게시글 배열을 검증한다.
- 평균, 중앙값, p95, p99, 최대, req/s, 오류율을 기록한다.
- 각 조건을 최소 3회 반복해 중앙 p95와 변동폭을 보고한다.
- 패치 전후 실행 순서와 서버 조건을 동일하게 유지한다.

대상 API:

```text
/api/modules/sirsoft-board/boards/{slug}/posts?page=1&per_page=20
```

### 깊은 페이지

- 각 게시판의 1,000페이지와 마지막 구간을 측정한다.
- 클라이언트 timeout 후에도 DB 쿼리가 남는지 processlist로 확인한다.
- 전후 응답 status, 크기, JSON schema, 게시글 ID 순서를 비교한다.
- ID 페이지 쿼리에 `EXPLAIN ANALYZE`를 실행해 사용 인덱스, 읽은 행, 실행시간을 기록한다.

### SQL 수

단일 첫 페이지 요청만 짧게 general log 또는 query listener로 추적한다.

- 추적 직후 general log를 반드시 끈다.
- queue worker SQL과 웹 요청 thread를 분리한다.
- 전체 SELECT 수와 분류별 수를 보고한다.
- 목표는 검증 데이터 기준 26회에서 14회 이하이다.

## 합격 기준

- 공개 목록 API 계약과 게시글 순서가 유지된다.
- 모든 K6 실행에서 유효 응답 99% 이상, HTTP 오류율 1% 미만이다.
- 120만 건 마지막 구간이 기준 서버에서 1.5초 이내다.
- 첫 페이지 요청당 SELECT가 14회 이하이다.
- 기본 최신글 정렬의 ID 쿼리가 covering index를 사용한다.
- ID순·조회수순이 신규 인덱스를 사용한다.
- 패치 전후 응답 schema가 같다.
- migration rollback으로 신규 인덱스만 제거할 수 있다.
- 타깃 회귀 테스트가 모두 통과한다.
- 첫 페이지 p95가 3회 중앙값 기준으로 10% 넘게 악화되면 원인을 해결하거나 패치를 재검토한다.

## 잔여 구조 문제를 별도 보고할 것

이번 deferred join은 넓은 행 조회를 제거하지만 OFFSET 자체는 유지한다. 120만 번째 행을 찾을 때 covering index 엔트리 약 120만 개를 읽는 O(offset) 문제는 남는다.

따라서 다음을 별도 설계안으로 제출하라.

- 100페이지까지 기존 page 방식 유지
- 이후 cursor/keyset pagination 사용
- 직접 60,000페이지 이동 같은 기존 URL의 처리 정책
- `created_at + id` 복합 cursor 형식
- 뒤로 가기, 정렬 변경, 검색 필터와 cursor 무효화 규칙
- 기존 JSON UI 페이지네이터와 API 하위 호환 전략

cursor 전환은 공개 API와 UI 계약 변경이므로 이번 최적화와 섞어 무검증 배포하지 않는다.

## 최종 출력 형식

1. 원인과 변경 전 SQL 구조
2. 수정 파일 목록
3. 파일별 실제 변경 내용과 라인
4. migration과 최종 인덱스 목록
5. 테스트 결과
6. K6 전후 표
7. 깊은 페이지와 `EXPLAIN ANALYZE` 전후 표
8. API 호환성 검증
9. 쓰기 성능·캐시 stale·인덱스 용량 위험
10. 롤백 절차
11. cursor 전환 후속 설계
12. ON/OFF/원본 복구 하네스 사용법과 실제 왕복 검증

성공 수치만 강조하지 말고 악화된 p95/p99, 단일 실행의 한계, 전체 suite 실패도 함께 보고하라.

---
