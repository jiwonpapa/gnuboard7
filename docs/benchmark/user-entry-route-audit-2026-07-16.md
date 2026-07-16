# 실사용 진입 경로 성능 점검 — 2026-07-16

## 결론

`https://www.g7devops.com`의 실제 사용자 SPA를 홈부터 게시판·쇼핑몰·전역검색까지 직접 이동해 확인했다.

- 홈, 게시판 1~2페이지, 게시글 내용, 쇼핑 홈·목록·내용·검색·검색 페이징은 기능상 정상이다.
- 게시판 깊은 페이징과 게시판 기본검색은 운영 불가 수준이다. 한 요청이 MySQL과 PHP-FPM을 오래 점유해 무관한 쇼핑 화면까지 느려지는 연쇄 장애를 재현했다.
- 쇼핑 화면은 동작하지만 매 페이지·검색 이동마다 고정 데이터까지 다시 요청한다. 운영 중인 사용자 템플릿이 번들 최신 storefront 통합 경로를 아직 반영하지 않았다.
- 전역검색은 결과가 정확히 표시되지만 단건 결과에도 API TTFB가 2.38초였다.
- 실제 사용자 SPA와 SEO/봇 렌더러는 별도 표면이다. SPA에는 콘솔 오류가 없었지만 SEO/봇 렌더러에는 CSS, 게시글 본문, 검색 결과 누락이 있다.

현재 `2 vCPU / 1.9 GiB` 서버의 증설만으로는 30~180초 쿼리를 해결할 수 없다. P0 쿼리와 요청 제한을 먼저 고친 뒤 풀기능 운영 권장선을 `4 vCPU / 8 GiB`로 잡는 것이 맞다.

## 점검 범위와 방법

- 대상: 운영 서버 `www.g7devops.com`
- 사용자 표면: headed Chrome으로 메뉴·버튼·검색 입력·다음 페이지를 실제 조작
- SEO 표면: HeadlessChrome User-Agent로 서버 렌더링 HTML을 별도 점검
- 서버 근거: PHP-FPM slowlog, MySQL processlist, 실제 인덱스, `EXPLAIN`
- 측정값: 단일 브라우저의 관찰값이다. 동시접속 부하 결과가 아니라 각 경로의 기능·병목 탐색용이다.
- 종료 확인: 장기 실행 MySQL 쿼리 없음, Nginx·PHP-FPM·MySQL·Redis·큐·Reverb 정상

공식 요구사항은 PHP·DB·필수 확장·디스크·프로덕션 데몬을 정의하지만 CPU/RAM 권장치는 정의하지 않는다. 공식 기준은 [`docs/requirements.md`](../requirements.md)이며, 이 문서의 CPU/RAM 값은 운영 계측에 따른 별도 권장치다.

## 실제 사용자 경로 판정

| 진입 경로 | 판정 | 관찰 결과 |
|---|---|---|
| 홈 | PASS | 화면·주요 데이터 정상, 브라우저 콘솔 오류 0건 |
| 게시판 목록 1페이지 | PASS | 게시글 API 150ms |
| 게시글 내용 | PASS | 본문 정상 표시, 내용 API 156ms, 이전·다음 탐색 API 163ms |
| 게시판 목록 2페이지 | PASS | URL과 목록 정상, API 157ms |
| 게시판 깊은 페이지 `page=59999` | **FAIL / P0** | 12초 동안 첫 바이트 없음. 서버 쿼리는 클라이언트 종료 후에도 계속 실행됐고 PHP-FPM 180초 제한까지 점유 |
| 게시판 검색 `887161` | **FAIL / P0** | 31초 이상 pending. 이전 목록 위에 로딩 상태가 남았으며 DB 쿼리를 수동 종료 |
| 전역검색 `887161` | PASS / SLOW | 결과 1건과 검색어가 정확히 표시됨. API TTFB 2,375ms |
| 쇼핑 홈·목록 1페이지 | PASS / P1 | 상품 12건 정상. categories 489ms, products 386ms, recent 151ms, popular 954ms, new 547ms |
| 상품 내용 | PASS / P1 | 설명 정상. product 236ms, reviews 156ms, inquiries 196ms, coupons 241ms, popular 674ms |
| 쇼핑 목록 2페이지 | PASS | URL·목록 정상, products API 297ms |
| 쇼핑 검색 `러닝화` | PASS / P1 | 총 1,756건, 검색어 유지, 1페이지 585ms |
| 쇼핑 검색 2페이지 | PASS / P1 | `keyword=러닝화` 유지, 결과 정상, products API 856ms |

`ms`는 해당 경로의 핵심 API resource duration이며 전체 화면의 시각적 완료시간과 동일한 값은 아니다.

## P0-1. 게시판 깊은 페이징

목록은 이미 `simplePaginate()`와 ID 선조회 경로를 사용한다. COUNT와 LONGTEXT 정렬은 줄었지만 페이지 번호 기반 OFFSET은 그대로다.

- 코드 경로: `PostRepository::buildSortedPostList()`의 `orderBy(...)->simplePaginate()`
- 조건: `board_id=1`, `is_notice=0`, `parent_id IS NULL`, `deleted_at IS NULL`
- 정렬: `ORDER BY id DESC`
- 깊은 페이지 OFFSET: 약 899,970

운영 DB `EXPLAIN` 결과:

```text
key=idx_board_posts_list_count
rows=869713
Extra=Using where; Using index; Using filesort
```

현재 목록 복합 인덱스는 마지막 컬럼이 `created_at`이고 기본 정렬 컬럼 `id`까지 이어지지 않는다. 약 87만 후보를 정렬한 뒤 OFFSET만큼 버리는 실행계획이다.

조치 순서:

1. 기본 `id DESC` 목록용 `(board_id, is_notice, parent_id, deleted_at, id)` 복합 인덱스를 검증한다.
2. 다음·이전 이동은 `id < last_id` 방식의 cursor/keyset 페이지네이션으로 전환한다.
3. 임의의 수만 페이지 점프가 필수라면 페이지 앵커 테이블·캐시를 별도로 둔다. 무제한 OFFSET을 유지하지 않는다.
4. 공개 조회 요청에 짧은 MySQL statement timeout을 적용해 180초 쿼리가 워커 전체를 잠그지 못하게 한다.
5. 브라우저 연결 종료·PHP 요청 종료 시 진행 중 DB 쿼리가 실제 취소되는지 통합 테스트를 추가한다.

코드 기준점: `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php:723`, `:780`, `:832`, `:841`.

## P0-2. 게시판 기본검색

FULLTEXT 인덱스 `ft_board_posts_title_content(title, content)`는 운영 DB에 실제 존재한다. 문제는 기본 검색 필드가 `all`이라 아래 조건을 하나의 OR로 합친다는 점이다.

```text
MATCH(title, content)
OR author_name LIKE '%keyword%'
OR EXISTS(users.name LIKE '%keyword%' OR users.email LIKE '%keyword%')
```

운영 DB `EXPLAIN`은 FULLTEXT 인덱스를 선택하지 않았다.

```text
table=board_posts, key=deleted_at index, rows=869713
Extra=Using index condition; Using where; Backward index scan
users=DEPENDENT SUBQUERY
```

즉 FULLTEXT 자체가 없는 문제가 아니라, FULLTEXT와 선행 와일드카드 LIKE·의존 서브쿼리를 OR로 합쳐 인덱스 사용을 무너뜨린 문제다.

조치 순서:

1. 기본 검색을 `title_content` FULLTEXT로 제한하고 작성자 검색은 명시적 필드로 분리한다.
2. `all` 검색이 필요하면 FULLTEXT·작성자·사용자 검색을 각각 인덱스 가능한 쿼리로 실행한 뒤 ID를 `UNION`/중복 제거한다.
3. 작성자·이메일의 `%keyword%`를 제거하거나 별도 검색 인덱스를 사용한다.
4. 결과 목록과 total 계산이 동일 검색 결과 ID 집합을 재사용하게 한다.
5. 조회 전용 statement timeout과 검색 동시실행 제한을 둔다.

코드 기준점: `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php:90-116`.

## P1-1. 전역검색

실제 사용자 화면은 정상이다. `887161` 검색 결과로 게시글 1건, 상품 0건, 페이지 0건을 정확히 표시했다. 다만 API TTFB는 2,375ms였고 PHP-FPM slowlog의 당시 스택은 상품 검색에 걸렸다.

상품 검색은 먼저 `Product::search($keyword)->keys()->all()`로 FULLTEXT 매칭 ID 전체를 꺼내고, 다시 `whereIn()->paginate()`한다. `DatabaseFulltextEngine::mapIds()`도 제한 없이 `pluck(id)`한다.

조치:

1. 통합검색에 필요한 페이지 크기만 FULLTEXT 엔진에서 제한·페이지네이션한다.
2. total과 상위 N건을 한 번의 검색 계획에서 얻고 전체 ID 배열을 PHP로 옮기지 않는다.
3. 게시글·상품·페이지 검색 시간을 분리 계측해 느린 공급자만 시간 제한·부분 실패 처리한다.

코드 기준점: `modules/_bundled/sirsoft-ecommerce/src/Repositories/ProductRepository.php:591-607`, `:621-627`, `app/Search/Engines/DatabaseFulltextEngine.php:81-88`.

## P1-2. 쇼핑몰 요청 팬아웃과 템플릿 드리프트

운영 중인 `templates/sirsoft-basic/layouts/shop/index.json`은 아래 5개 API를 모두 `auto_fetch`한다.

1. categories
2. products
3. recentProducts
4. popularProducts
5. newProducts

검색·정렬·페이징으로 URL만 바뀌어도 5개가 다시 요청됐다. 특히 popular가 674~954ms로 반복 비용이 컸다.

번들 최신 템플릿 `templates/_bundled/sirsoft-basic/layouts/shop/index.json`은 products와 storefront 두 소스로 이미 통합돼 있다. 코어 수정 전에 활성 사용자 템플릿을 정상 업데이트·동기화하고, 이동 시 고정 storefront 데이터의 불필요한 refetch가 사라졌는지 재검증해야 한다.

코드 기준점: 활성 템플릿 `templates/sirsoft-basic/layouts/shop/index.json:63-143`, 번들 최신본 `templates/_bundled/sirsoft-basic/layouts/shop/index.json:69-116`.

기존 CPU 프로파일에서도 비유휴 CPU의 PHP-FPM 비중이 72.8%, MySQL이 19.2%였고, 상품 목록의 약 76.7%, storefront 컨트롤러의 약 95.7%가 응답 변환·직렬화 경로였다. 상세 근거는 [`ecommerce-product-bottleneck-analysis-2026-07-15.md`](ecommerce-product-bottleneck-analysis-2026-07-15.md#11-2026-07-16-cpu-프로파일링-후속)에 있다.

## 데이터 품질 문제

쇼핑 UI의 카테고리와 일부 상품이 두 번 보이는 것은 렌더러 중복이 아니라 운영 벤치마크 데이터 중복이다.

- 동일 카테고리명에 서로 다른 ID·slug가 존재: 예) ID `41`의 `bmj-9-category-001`, ID `141`의 `bmj-10-category-001`
- 동일 상품명이 두 데이터 세트에 존재: 예) ID `20482`/`10482`, 상품코드의 세트 표식 `BMJ000A...`/`BMJ0009...`

삭제 전 백업과 소유 세트 판별이 필요하므로 이번 점검에서는 데이터를 변경하지 않았다. 벤치마크 적재 작업은 run ID를 기록하고 동일 run의 재실행을 멱등하게 만들어야 한다.

## SEO/봇 렌더러 별도 결함

일반 Chrome SPA에는 콘솔 오류가 없었지만 HeadlessChrome이 받은 서버 렌더링 HTML에는 다음 문제가 있었다.

- `/build/assets/app.css`가 CSS가 아닌 HTML로 응답해 MIME 오류 발생
- 게시글 상세의 제목·메타는 있으나 본문 누락
- `/search?q=887161`에서 입력값과 결과가 누락돼 0건으로 렌더링되지만 같은 API와 사용자 SPA는 1건 반환
- `Seo/DataSourceResolver.php`가 동일 애플리케이션 API를 HTTP로 다시 호출하며, FPM 포화 시 이 내부 호출도 함께 대기

이 결함은 사용자 SPA의 검색·버튼 기능과 혼동하지 않고 SEO 회귀 테스트로 별도 수정해야 한다.

## 튜닝 실행 순서

1. **P0 안전장치**: 웹 조회용 MySQL statement timeout, 장기 쿼리 관측·취소, 동시 검색 제한
2. **P0 게시판 검색**: FULLTEXT와 작성자 검색 OR 분리
3. **P0 깊은 페이징**: 기본 정렬 복합 인덱스 검증 후 cursor/keyset 전환
4. **P0 공통 CPU**: 훅 등록 `Log::info()` 348회를 요약 1건으로 축소
5. **P1 쇼핑 배포 드리프트**: 활성 템플릿을 storefront 통합본으로 업데이트하고 refetch 재검증
6. **P1 전역검색**: 전체 ID `pluck` 제거, 공급자별 제한·계측
7. **P1 직렬화**: storefront 최종 payload 캐시와 목록 경량 DTO
8. **P2 데이터 정리**: `bmj-9`/`bmj-10` 중복 세트 백업 후 정리, 적재 멱등성 추가
9. **P2 SEO**: CSS 경로·게시글 본문·검색 hydration·내부 HTTP 호출 구조 수정
10. 같은 진입 경로를 다시 밟고 1 VU·10 VU에서 p95·CPU·DB 장기 쿼리 0건을 확인

## 서버 권장선

- 공식 문서: CPU/RAM 수치 없음. PHP 8.2+, MySQL 8.0+/MariaDB 10.3+, Redis 권장, 큐·스케줄러·Reverb 데몬 필요
- 현재 테스트 서버: `2 vCPU / 1.9 GiB` — 기능 확인과 소규모 테스트용
- 코드 튜닝 후 풀기능 운영 권장: `4 vCPU / 8 GiB`
- 검색·쇼핑·SEO 렌더링·Reverb·큐를 동시에 적극 사용하거나 트래픽 여유가 필요하면: `8 vCPU / 16 GiB`부터 부하시험

PHP-FPM worker 수는 RAM만 보고 임의로 늘리지 않는다. 실제 worker RSS와 CPU 포화도를 다시 측정해 산정한다. 현재 2 vCPU에서 worker 증가는 CPU 경합을 키울 수 있다.

## 변경 범위

- 운영 데이터와 원본 코어·번들 확장은 수정하지 않았다.
- Xdebug는 트리거 프로파일에만 사용했고 CLI·FPM 모두 비활성 상태다.
- 이번 작업의 추가 산출물은 이 점검 문서뿐이다.
