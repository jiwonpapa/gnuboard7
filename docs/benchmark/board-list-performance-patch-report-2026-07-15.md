# 그누보드7 대용량 게시판 목록 성능 개선 결과

측정 일자: 2026-07-15
대상: 그누보드7 7.0.4, `sirsoft-board` 1.1.0
환경: 스테이징 서버, 실데이터 180만 원글

## 기술 요약

- 깊은 페이지는 API 규격을 바꾸지 않고 ID만 먼저 페이지네이션하는 deferred join으로 변경했다. 20만~120만 건 게시판의 측정 구간이 **11.5~61.9배 빨라졌고**, 120만 건 마지막 60,000페이지는 35초 초과에서 0.718초로 줄었다.
- 첫 페이지 SELECT는 **26회에서 14회로 46.2% 감소**했다. 비회원 권한 N회 조회, 활성 모듈 중복 조회, 언어팩 중복 조회, 답글이 없는 페이지의 답글 조회를 제거했다.
- 동일 K6 테스트 6회 모두 HTTP 오류율 0%였다. 평균 응답은 6개 조건 중 5개가 개선됐지만, `test40` 10 VU p95와 `freebd` 10 VU p99는 악화돼 첫 페이지 지연 분산까지 해결됐다고 보기는 어렵다.
- OFFSET 자체는 유지했으므로 깊은 페이지가 O(offset)인 한계는 남는다. 실제 마지막 페이지 SQL은 120만 인덱스 행을 읽고 0.671초가 걸렸다. 페이지 번호 호환성을 유지한 이번 패치의 잔여 한계이며, 완전한 해결은 별도 커서 API가 필요하다.
- 목록 API 필드와 페이지 번호 계약은 변경하지 않았다. 완료된 동일 페이지 요청의 응답 크기도 전후 동일했다.

## 측정 환경과 데이터

### 대상 서버

| 항목 | 값 |
|---|---|
| 인스턴스 | AWS EC2 t3.small, burstable |
| CPU | Intel Xeon Platinum 8259CL, 2 vCPU |
| 메모리 / Swap | 1.9GiB / 1.9GiB |
| OS | Ubuntu 24.04.4 LTS, Linux 6.17 AWS |
| 웹 서버 | Nginx 1.24.0 |
| PHP | PHP-FPM 8.5.8, `memory_limit=256M`, `max_execution_time=120` |
| PHP-FPM pool | dynamic, `max_children=6`, `max_requests=500`, request timeout 180초 |
| 애플리케이션 | 그누보드7 7.0.4, Laravel 12.62.0, production |
| DB | MySQL 8.4.10, `max_connections=20` |
| InnoDB buffer pool | 384MiB |
| 게시글 테이블 | 정확히 1,800,002행, InnoDB 추정 data 1,213.0MiB + index 1,125.6MiB |

부하 발생기는 Mac mini Apple M4 Pro, 48GB, macOS 26.5.2이며 K6 v1.6.1을 사용했다.

### 게시판 데이터

| 게시판 | 원글 | 댓글 | 마지막 페이지 |
|---|---:|---:|---:|
| `gallery` | 200,000 | 250,692 | 10,000 |
| `test40` | 400,000 | 501,041 | 20,000 |
| `freebd` | 1,200,002 | 1,504,419 | 60,001 |

댓글은 별도 테이블에 있고 목록은 원글의 `comments_count`를 읽으므로, 위 목록 OFFSET 실행계획의 스캔 행 수에는 댓글 행이 포함되지 않는다.

## 코드 변경 내역

| 파일과 라인 | 변경 내용 | 목적 |
|---|---|---|
| `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php:36-39` | 공지 10건, 인라인 답글 100건 상한 정의 | 비정상적으로 큰 공지·답글 트리가 목록 응답을 점유하는 상황 차단 |
| `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php:769-774` | 첫 페이지 공지 쿼리에 `LIMIT 10` 적용 | 공지 수에 비례한 관계 조회·직렬화 증가 제한 |
| `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php:830-846` | `simplePaginate()`는 `id`만 조회하고 선택된 ID만 다시 hydrate | 깊은 OFFSET에서 버릴 행의 LONGTEXT·넓은 컬럼 row lookup 제거 |
| `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php:860-905` | `replies_count=0`이면 답글 SQL 생략, 답글 수 100건 제한, 다음 depth도 카운터로 선별 | 첫 페이지 불필요 SELECT 제거와 답글 폭증 방지 |
| `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php:939-989` | `hydrateListPostsByIds()` 추가, 관계·카운트 로딩 후 원래 페이지 순서 복원 | API 결과 순서와 기존 projection 유지 |
| `modules/_bundled/sirsoft-board/src/Services/PostService.php:119-157` | 검색·분류·상태·작성자·기간별 COUNT 결과를 60초 캐시 | 같은 필터의 반복 전체 COUNT 방지 |
| `modules/_bundled/sirsoft-board/src/Services/PostService.php:162-183` | 필터·Enum을 결정론적으로 정규화해 SHA-256 캐시 키 생성 | 필터 순서 차이·타입 차이에 의한 캐시 오염 방지 |
| `app/Http/Middleware/PermissionMiddleware.php:121-133` | eager load한 guest 권한 컬렉션에서 판정 | 권한마다 실행되던 `EXISTS` SQL 제거 |
| `app/Providers/ModuleRouteServiceProvider.php:75-77` | 활성 모듈 DB 직접 조회 대신 `ModuleManager` 상태 캐시 사용 | 매 요청 활성 모듈 SELECT 제거 |
| `app/Services/LanguagePack/LanguagePackRegistry.php:56-67` | 이미 조회한 활성 언어팩 컬렉션에서 코어 locale 추출 | 언어팩 중복 SELECT 제거 |
| `modules/_bundled/sirsoft-board/database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php:12-30` | ID순·조회수순 목록 인덱스 추가 | 정렬별 ID 선조회에서 filesort와 넓은 행 조회 방지 |
| `modules/_bundled/sirsoft-board/database/migrations/2026_07_15_000001_add_high_volume_list_indexes.php:36-46` | 추가 인덱스만 제거하는 `down()` 구현 | 롤백 범위 제한 |
| `modules/_bundled/sirsoft-board/tests/Unit/PostRepositoryPaginationPerformanceTest.php:29-74` | ID 선조회, 넓은 행 후조회, 답글 SQL 생략, 공지 상한 검증 | 페이지네이션 성능 구조 회귀 방지 |
| `modules/_bundled/sirsoft-board/tests/Unit/PostServiceSortTest.php:255-291` | 동일 필터 COUNT가 한 번만 실행되는지 검증 | 필터 캐시 회귀 방지 |
| `tests/Feature/Middleware/PermissionMiddlewareTest.php:423-454` | 두 번째 guest 권한 판정 SQL 0회 검증 | 권한 N+1 회귀 방지 |
| `tests/Unit/Services/LanguagePack/LanguagePackRegistryTest.php:140-156` | 활성 언어팩 SQL 1회 검증 | 부트스트랩 중복 조회 회귀 방지 |
| `modules/_bundled/sirsoft-board/module.json:8` 외 4개 버전 파일 | 모듈 버전 1.0.2에서 1.1.0으로 상향 | 배포 시 확장 업데이트·마이그레이션 적용 |
| `modules/_bundled/sirsoft-board/CHANGELOG.md:7-13`, `CHANGELOG.md:7-11` | 모듈·코어 변경 이력 추가 | 공개 변경 추적 |

## DB 인덱스와 실행계획

### 적용 인덱스

| 인덱스 | 컬럼 순서 | 상태 | 사용처 |
|---|---|---|---|
| `idx_board_posts_list_count` | `board_id, is_notice, parent_id, deleted_at, created_at` | 기존 | 기본 `created_at` 정렬의 ID-only 페이지 쿼리. InnoDB secondary index에 PK `id`가 포함돼 covering scan이 된다. |
| `idx_board_posts_list_id` | `board_id, is_notice, parent_id, deleted_at, id` | 신규 | ID 정렬 목록 |
| `idx_board_posts_list_views` | `board_id, is_notice, parent_id, deleted_at, view_count, id` | 신규 | 조회수 정렬 목록 |

신규 인덱스는 모두 visible이며 마이그레이션 batch 7로 적용됐다. 기본 최신글 정렬은 기존 `idx_board_posts_list_count`를 사용하므로, 이번 기본 목록의 큰 개선은 인덱스 추가 자체보다 ID-only deferred join에서 발생했다. 신규 인덱스 두 개는 ID순·조회수순 정렬의 동일한 구조를 보장한다.

### 마지막 페이지 `EXPLAIN ANALYZE`

| 게시판 | OFFSET | 인덱스가 읽은 행 | ID 쿼리 실행시간 | 사용 인덱스 |
|---|---:|---:|---:|---|
| `gallery` | 199,980 | 199,999 | 113ms | `idx_board_posts_list_count` |
| `test40` | 399,980 | 399,999 | 224ms | `idx_board_posts_list_count` |
| `freebd` | 1,199,980 | 약 120만 | 671ms | `idx_board_posts_list_count` |

현재 쿼리는 covering index라 넓은 본문 행을 읽지 않지만 OFFSET만큼 인덱스 엔트리는 계속 읽는다. 따라서 데이터가 더 커지면 다시 선형으로 느려지며, 이 구간은 cursor/keyset pagination 대상이다.

## 동일 K6 전후 비교

각 게시판은 서로 분리해 30초간 실행했다. 순서는 `gallery`, `test40`, `freebd`이며 5 VU 세트 후 10 VU 세트를 실행했다. 각 VU는 응답 후 1초 대기했고 `/api/modules/sirsoft-board/boards/{slug}/posts?page=1&per_page=20`에서 HTTP 200, 첫 페이지, 게시글 배열을 검증했다.

| 시점 | 게시판 | VU | 평균 | 중앙값 | p95 | p99 | 최대 | 처리량 | 오류율 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 전 | `gallery` | 5 | 171ms | 134ms | 279ms | 751ms | 859ms | 4.18 req/s | 0% |
| 후 | `gallery` | 5 | 142ms | 136ms | 240ms | 308ms | 327ms | 4.35 req/s | 0% |
| 전 | `test40` | 5 | 179ms | 118ms | 286ms | 1,255ms | 1,258ms | 4.18 req/s | 0% |
| 후 | `test40` | 5 | 173ms | 141ms | 292ms | 316ms | 335ms | 4.18 req/s | 0% |
| 전 | `freebd` | 5 | 268ms | 102ms | 314ms | 3,225ms | 3,228ms | 3.89 req/s | 0% |
| 후 | `freebd` | 5 | 150ms | 137ms | 289ms | 370ms | 393ms | 4.31 req/s | 0% |
| 전 | `gallery` | 10 | 172ms | 155ms | 286ms | 607ms | 638ms | 8.35 req/s | 0% |
| 후 | `gallery` | 10 | 145ms | 133ms | 265ms | 545ms | 640ms | 8.60 req/s | 0% |
| 전 | `test40` | 10 | 159ms | 134ms | 263ms | 535ms | 629ms | 8.48 req/s | 0% |
| 후 | `test40` | 10 | 163ms | 135ms | 397ms | 563ms | 623ms | 8.45 req/s | 0% |
| 전 | `freebd` | 10 | 172ms | 148ms | 313ms | 559ms | 653ms | 8.39 req/s | 0% |
| 후 | `freebd` | 10 | 165ms | 140ms | 304ms | 691ms | 745ms | 8.44 req/s | 0% |

주요 변화는 다음과 같다.

- 5 VU 평균: `gallery` -17.3%, `test40` -3.4%, `freebd` -43.7%.
- 10 VU 평균: `gallery` -15.8%, `test40` +2.7%, `freebd` -4.2%.
- 5 VU p99는 세 게시판 모두 59.0~88.5% 감소했다.
- 10 VU에서는 `test40` p95가 50.9%, `freebd` p99가 23.6% 증가했다. 단일 30초 실행이라 분산 판단에는 반복 측정이 필요하다.

첫 페이지는 이미 OFFSET이 작아 deferred join의 이득보다 PHP/Laravel 고정비와 소형 burstable 서버 변동이 더 크게 보인다. 구조적 개선 근거는 평균값 하나보다 SELECT 수 감소와 깊은 페이지 결과가 더 강하다.

## 깊은 페이지 전후 비교

| 게시판 | 페이지 | 패치 전 | 패치 후 | 개선 배수 | 응답 크기 |
|---|---:|---:|---:|---:|---:|
| `gallery` | 1,000 | 2.678초 | 0.199초 | 13.5배 | 23,275B 동일 |
| `gallery` | 10,000 | 2.858초 | 0.248초 | 11.5배 | 22,790B 동일 |
| `test40` | 1,000 | 6.531초 | 0.221초 | 29.6배 | 23,897B 동일 |
| `test40` | 20,000 | 13.210초 | 0.923초 | 14.3배 | 22,624B 동일 |
| `freebd` | 1,000 | 11.667초 | 0.189초 | 61.9배 | 23,588B 동일 |
| `freebd` | 60,000 | 35초 초과 | 0.718초 | 48.7배 이상 | 패치 후 20,305B |

단일 cURL 실측이며 네트워크와 애플리케이션 시간을 포함한다. 패치 직후 첫 요청은 인덱스 생성으로 캐시가 차가워 비교에서 제외했고, 첫 페이지는 동일 K6 결과를 기준으로 판단했다.

## 요청당 SQL 변화

| 구분 | 패치 전 | 패치 후 |
|---|---:|---:|
| 코어 부트스트랩 | 4 | 2 |
| guest 역할·권한 | 12 | 2 |
| 게시판 조회 | 1 | 1 |
| 공지 + 관계 | 4 | 4 |
| 일반글 + 관계 | 4 | 5 |
| 답글 존재 확인 | 1 | 0 |
| 합계 | **26** | **14** |

일반글이 4회에서 5회로 늘어난 것은 ID-only 페이지 SQL이 한 번 추가됐기 때문이다. 대신 이 SQL은 covering index만 읽고, 실제 넓은 행과 관계는 선택된 20건에만 수행한다. 기본 목록에서는 전체 `COUNT(*)`가 실행되지 않았다.

## 검증과 잔여 위험

- 변경 직접 회귀 테스트: **70개 통과, 131 assertions**.
- PHP 포맷: Pint 통과.
- 스테이징: `sirsoft-board` 1.1.0 active, 신규 인덱스 2개와 migration batch 7 확인.
- K6: 6개 실행 모두 HTTP 오류율 0%, 응답 유효성 100%.
- 전체 board 모듈 suite 시도 결과는 1,096 pass / 83 fail이었다. 실패는 로컬 전체-suite 환경에서 기본 board settings가 `null`이 되어 `BoardPermissionService.php:96`의 반복문으로 연쇄된 군집이다. 이번 변경 대상 테스트는 모두 통과했지만, 패치 전 전체-suite 기준선이 없으므로 83건을 이번 패치와 무관하다고 단정하지는 않는다.
- 신규 secondary index 2개는 조회를 빠르게 하는 대신 게시글 INSERT/UPDATE 비용과 디스크 사용량을 늘린다. 더미 생성 bulk insert 속도는 별도 재측정 대상이다.
- 필터 COUNT 캐시는 최대 60초 동안 최신 생성·삭제가 반영되지 않을 수 있다. 기본 무필터 total 캐시 정책은 변경하지 않았다.
- 공지 10건·인라인 답글 100건 상한은 응답 폭증 방지 정책이다. 더 많은 답글은 별도 답글/상세 API로 조회해야 한다.

## 배포와 롤백

- 배포 백업: 비공개 운영 경로에 보관(공개 저장소 미포함)
- 배포 중 클라이언트가 35초에 포기한 기존 deep OFFSET SQL은 DB에서 계속 실행돼 ALTER TABLE metadata lock을 막았다. 해당 벤치마크 SELECT 연결만 종료한 뒤 마이그레이션을 완료했다.
- 이 metadata lock 구간에 루트 요청 503 세 건이 Nginx access log에 남았다. 대형 테이블 인덱스 배포는 maintenance window에서 stale SELECT 확인 후 실행해야 한다.
- 코드 롤백은 위 백업 복원 후 확장 캐시를 비우고 PHP-FPM을 reload한다.
- DB 롤백은 migration `down()` 또는 `g7_board_posts`의 `idx_board_posts_list_views`, `idx_board_posts_list_id` 두 인덱스만 제거한다. 기존 인덱스는 건드리지 않는다.

## 다음 단계

1. 100페이지 이후 cursor/keyset 방식의 별도 API를 도입해 깊은 페이지의 O(offset) 스캔을 제거한다.
2. 5/10 VU 테스트를 조건별 3회 이상 반복해 중앙 p95와 변동폭으로 첫 페이지 회귀 기준을 고정한다.
3. 목록 projection을 기본형·카드형으로 분리해 본문 미리보기, 아바타, 썸네일을 실제 화면 요구에 맞춰 선택적으로 로딩한다.
4. 신규 인덱스 적용 전후의 bulk insert 처리량과 디스크 증가량을 별도로 비교한다.
