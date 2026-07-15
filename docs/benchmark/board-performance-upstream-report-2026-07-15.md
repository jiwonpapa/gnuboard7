# 그누보드7 7.0.4 대용량 게시판 목록 성능 개선 보고

## 이슈 요약

`sirsoft-board` 목록은 기본 total을 캐시하고 `simplePaginate()`를 사용하지만, 페이지 쿼리가 목록용 넓은 컬럼과 본문 미리보기를 직접 조회한다. 깊은 OFFSET에서는 반환하지 않을 수십만~백만 행까지 clustered row lookup이 발생해 120만 건 게시판의 60,000페이지가 35초 안에 응답하지 못했다.

첫 페이지는 OFFSET보다 요청당 26회의 SELECT와 Laravel 리소스 직렬화 고정비가 주된 병목이었다. 특히 guest 역할의 권한을 eager load하고도 권한별 `EXISTS`를 반복했다.

공식 `7.0.4` 기준 검증용 패치를 적용한 결과, 공개 API 계약을 유지하면서 깊은 페이지는 11.5~61.9배 개선됐고 첫 페이지 SELECT는 26회에서 14회로 감소했다.

## 재현 환경

| 항목 | 값 |
|---|---|
| 애플리케이션 | 그누보드7 7.0.4, Laravel 12.62.0 |
| board module | 원본 1.0.2, 검증 패치 1.1.0 |
| 서버 | AWS EC2 t3.small, Intel Xeon Platinum 8259CL 2 vCPU |
| 메모리 | 1.9GiB, Swap 1.9GiB |
| PHP | PHP-FPM 8.5.8, memory limit 256MiB, max children 6 |
| DB | MySQL 8.4.10, InnoDB buffer pool 384MiB |
| 게시글 테이블 | 원글 1,800,002행, InnoDB 추정 data 1,213.0MiB + index 1,125.6MiB |
| 부하 도구 | K6 v1.6.1, Apple M4 Pro 부하 발생기 |

| 게시판 | 원글 | 댓글 | 마지막 페이지 |
|---|---:|---:|---:|
| `gallery` | 200,000 | 250,692 | 10,000 |
| `test40` | 400,000 | 501,041 | 20,000 |
| `freebd` | 1,200,002 | 1,504,419 | 60,001 |

댓글은 별도 테이블에 저장되며 목록은 원글의 `comments_count`를 읽는다. 따라서 댓글 행 수는 목록 OFFSET 실행계획의 스캔 행 수에 직접 포함되지 않는다.

## 검증용 패치에서 수정한 부분

### 게시글 페이지네이션

대상: `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php`

| 변경 위치 | 내용 |
|---|---|
| `:36-39` | 첫 페이지 공지 10건, 인라인 답글 100건 상한 정의 |
| `:769-774` | 공지 쿼리에 `LIMIT 10` 적용 |
| `:830-846` | 넓은 목록 컬럼 대신 현재 페이지 ID만 `simplePaginate()` |
| `:860-905` | `replies_count=0`이면 답글 SQL 생략, depth별 총 100건 제한 |
| `:939-989` | 선택된 ID만 목록 컬럼·관계로 조회하고 원래 순서 복원 |

핵심 변경은 다음 두 단계다.

```text
1. 정렬 인덱스에서 현재 페이지 ID 최대 20건 조회
2. 선택된 ID만 제목, 본문 미리보기, 작성자, 아바타, 썸네일과 결합
```

기존 방식처럼 OFFSET으로 버릴 행의 LONGTEXT와 목록 projection을 읽지 않는다.

### COUNT와 요청 부트스트랩

| 파일 | 변경 위치 | 내용 |
|---|---|---|
| `modules/_bundled/sirsoft-board/src/Services/PostService.php` | `:119-183` | 필터 COUNT를 조건별 60초 캐시, 결정론적 SHA-256 키 적용 |
| `app/Http/Middleware/PermissionMiddleware.php` | `:121-133` | eager load한 guest 권한 컬렉션 재사용 |
| `app/Providers/ModuleRouteServiceProvider.php` | `:75-77` | 활성 모듈 상태 캐시 사용 |
| `app/Services/LanguagePack/LanguagePackRegistry.php` | `:56-67` | 활성 언어팩 요청 중 캐시 재사용 |

### DB 인덱스

Migration:

`modules/_bundled/sirsoft-board/database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php`

| 인덱스 | 컬럼 | 상태 | 용도 |
|---|---|---|---|
| `idx_board_posts_list_count` | `board_id, is_notice, parent_id, deleted_at, created_at` | 기존 | 기본 최신글 정렬 ID-only covering scan |
| `idx_board_posts_list_id` | `board_id, is_notice, parent_id, deleted_at, id` | 신규 | ID 정렬 |
| `idx_board_posts_list_views` | `board_id, is_notice, parent_id, deleted_at, view_count, id` | 신규 | 조회수 정렬 |

기본 최신글 목록의 큰 개선은 신규 인덱스보다 ID-only deferred join에서 발생했다. InnoDB secondary index는 PK `id`를 포함하므로 기존 `idx_board_posts_list_count`가 `SELECT id ... ORDER BY created_at, id`를 covering한다.

## 깊은 페이지 개선 결과

동일 API의 동일 페이지를 패치 전후 단일 요청으로 측정했다.

| 게시판 | 페이지 | 패치 전 | 패치 후 | 개선 |
|---|---:|---:|---:|---:|
| `gallery` | 1,000 | 2.678초 | 0.199초 | 13.5배 |
| `gallery` | 10,000 | 2.858초 | 0.248초 | 11.5배 |
| `test40` | 1,000 | 6.531초 | 0.221초 | 29.6배 |
| `test40` | 20,000 | 13.210초 | 0.923초 | 14.3배 |
| `freebd` | 1,000 | 11.667초 | 0.189초 | 61.9배 |
| `freebd` | 60,000 | 35초 초과 | 0.718초 | 48.7배 이상 |

완료된 전후 요청의 응답 크기는 동일했고 K6의 HTTP 상태·페이지 번호·게시글 배열 유효성 검증도 통과했다.

### 마지막 구간 실행계획

| 게시판 | OFFSET | 읽은 인덱스 행 | ID 쿼리 | 인덱스 |
|---|---:|---:|---:|---|
| `gallery` | 199,980 | 199,999 | 113ms | `idx_board_posts_list_count` |
| `test40` | 399,980 | 399,999 | 224ms | `idx_board_posts_list_count` |
| `freebd` | 1,199,980 | 약 120만 | 671ms | `idx_board_posts_list_count` |

넓은 행 조회는 제거됐지만 OFFSET만큼 인덱스 엔트리를 읽는 O(offset) 한계는 남는다.

## 첫 페이지 SQL 감소

| 구분 | 패치 전 | 패치 후 |
|---|---:|---:|
| 코어 부트스트랩 | 4 | 2 |
| guest 역할·권한 | 12 | 2 |
| 게시판 조회 | 1 | 1 |
| 공지 + 관계 | 4 | 4 |
| 일반글 + 관계 | 4 | 5 |
| 답글 확인 | 1 | 0 |
| 합계 | **26** | **14** |

일반글 쿼리가 1회 증가한 것은 ID-only 페이지 SQL이 추가됐기 때문이다. 이 SQL은 covering index만 읽고 실제 넓은 행은 선택된 20건만 조회한다. 기본 목록에는 전체 `COUNT(*)`가 실행되지 않았다.

## 동일 K6 결과

각 게시판을 독립 실행했다. 5 VU와 10 VU에서 30초 동안 첫 페이지를 호출하고 각 VU는 응답 후 1초 대기했다. HTTP 200, 첫 페이지, 게시글 배열을 검증했다.

| 시점 | 게시판 | VU | 평균 | p95 | p99 | 최대 | 처리량 | 오류율 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 전 | `gallery` | 5 | 171ms | 279ms | 751ms | 859ms | 4.18 req/s | 0% |
| 후 | `gallery` | 5 | 142ms | 240ms | 308ms | 327ms | 4.35 req/s | 0% |
| 전 | `test40` | 5 | 179ms | 286ms | 1,255ms | 1,258ms | 4.18 req/s | 0% |
| 후 | `test40` | 5 | 173ms | 292ms | 316ms | 335ms | 4.18 req/s | 0% |
| 전 | `freebd` | 5 | 268ms | 314ms | 3,225ms | 3,228ms | 3.89 req/s | 0% |
| 후 | `freebd` | 5 | 150ms | 289ms | 370ms | 393ms | 4.31 req/s | 0% |
| 전 | `gallery` | 10 | 172ms | 286ms | 607ms | 638ms | 8.35 req/s | 0% |
| 후 | `gallery` | 10 | 145ms | 265ms | 545ms | 640ms | 8.60 req/s | 0% |
| 전 | `test40` | 10 | 159ms | 263ms | 535ms | 629ms | 8.48 req/s | 0% |
| 후 | `test40` | 10 | 163ms | 397ms | 563ms | 623ms | 8.45 req/s | 0% |
| 전 | `freebd` | 10 | 172ms | 313ms | 559ms | 653ms | 8.39 req/s | 0% |
| 후 | `freebd` | 10 | 165ms | 304ms | 691ms | 745ms | 8.44 req/s | 0% |

해석:

- 평균은 6개 조건 중 5개가 개선됐다.
- 5 VU p99는 세 게시판 모두 59.0~88.5% 감소했다.
- `test40` 10 VU p95는 50.9%, `freebd` 10 VU p99는 23.6% 악화됐다.
- 단일 30초 실행이므로 첫 페이지 tail latency 개선을 확정하려면 조건별 3회 이상 반복이 필요하다.
- 6개 실행의 HTTP 오류율은 모두 0%였다.

## 검증 결과

- 변경 직접 회귀 테스트: 70개 통과, 131 assertions.
- Pint 및 변경 PHP 파일 syntax check 통과.
- 신규 인덱스 2개 적용과 신규 인덱스만 제거하는 migration `down()` 구현 확인.
- 첫 페이지 SELECT 14회 확인.
- 깊은 페이지와 첫 페이지 모두 HTTP 200 확인.
- 전체 board module suite는 1,096 pass / 83 fail이었다. 실패는 로컬 전체-suite 환경에서 기본 board settings가 `null`이 되어 `BoardPermissionService.php:96`에서 연쇄된 군집이다. 패치 전 전체-suite 기준선이 없으므로 기존 실패라고 단정할 수는 없다.

## 위험과 잔여 과제

1. OFFSET 자체는 남아 있어 120만 건 마지막 구간도 인덱스 행 약 120만 개를 읽는다. 100페이지 이후 cursor/keyset pagination을 도입해야 최종적으로 해결된다.
2. 신규 secondary index 두 개는 게시글 INSERT/UPDATE 비용과 디스크 사용량을 늘린다. 대량 bulk insert 전후 처리량 비교가 필요하다.
3. 필터 COUNT는 최대 60초 stale할 수 있다.
4. 공지 10건과 인라인 답글 100건 상한은 제품 정책 합의가 필요하다.
5. `title`, `author_name` 정렬은 별도 대용량 실행계획과 인덱스 비용 검토가 필요하다.
6. 첫 페이지는 Laravel 부트스트랩·관계 로딩·JSON 직렬화 고정비가 남아 있어 200ms 이하를 안정적으로 보장하지 못한다.

## 반복 검증 하네스

검증 패치 1.1.1에는 원본과 개선 경로를 한 명령으로 전환하는 하네스를 추가했다.

```bash
scripts/benchmark/board-performance-toggle.sh on
scripts/benchmark/board-performance-toggle.sh off
scripts/benchmark/board-performance-toggle.sh status
scripts/benchmark/board-performance-toggle.sh restore-original --yes
```

`off`는 공식 7.0.4 실행 분기를 선택하고 신규 인덱스를 invisible로 바꾸는 빠른 읽기 A/B 모드다. `restore-original`은 공식 파일을 복원하고 신규 인덱스와 migration 기록까지 삭제한다.

실제 스테이징에서 `off → on → restore-original → on` 왕복을 검증했다. 동일 120만 건 게시판 1,000페이지는 `off` 11.594초, `on` 0.579초였고 최종 상태는 optimized, 신규 인덱스 visible, module 1.1.1 active다.

## 개발사에 요청할 사항

1. 목록 ID-only deferred join을 공식 구현으로 검토한다.
2. guest 권한과 활성 모듈·언어팩의 중복 SQL을 query-count 회귀 테스트로 고정한다.
3. ID순·조회수순 복합 인덱스의 쓰기·용량 비용을 공식 데이터셋으로 재검증한다.
4. 20만·40만·120만 건 게시판을 성능 회귀 fixture로 운영한다.
5. 첫 페이지 5/10 VU와 깊은 페이지 `EXPLAIN ANALYZE`를 릴리스 게이트에 포함한다.
6. 기존 페이지 번호와 호환되는 cursor 전환 정책을 별도 API 설계로 확정한다.
