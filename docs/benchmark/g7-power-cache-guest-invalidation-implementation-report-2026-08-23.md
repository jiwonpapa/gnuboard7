# G7PowerCache 비회원 우선 캐싱·무효화 구현 설계 보고서

> 감사 기준: Gnuboard7 7.0.8 성능 워크트리 `codex/7.0.8-performance-lab`, 기준 커밋 `7f127797473df1620d26490d4699d52a98951b3e`, 2026-08-23. 정적 소스·라우트·훅 감사 뒤 온라인 테스트 서버 배포와 런타임 A/B까지 갱신했습니다.

> 구현 갱신: 같은 날 `plugins/_bundled/g7-power_cache`에 `0.2.0 Technical Preview`를 구현·배포했습니다. 식별자는 그누7 `vendor-plugin_name` 규약에 맞춘 `g7-power_cache`이며, 독립 저장소 분리는 형님 지시에 따라 보류했습니다. 독립 PHPUnit 결과는 **33 tests / 352 assertions 통과**입니다. 실제 수치는 [온라인 ON/OFF 실측 보고서](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/g7-power-cache-live-ab-report-2026-08-23.md)에 분리했습니다.

## Executive Summary — 결론

온라인 테스트 서버의 동일 플러그인 `bypass` 대비 Redis warm `active` 실측에서 50,002건 게시판 목록 p95는 350→256ms(-26.9%), 처리량은 40.0%, PHP-FPM CPU는 24.1%, MySQL Questions는 54.7% 개선됐습니다. 카테고리 목록 p95는 225→155ms(-31.1%), 카테고리 상세은 232→142ms(-38.8%), 페이지 상세는 141→135ms(-4.3%)였습니다. 즉 게시판·무거운 공개 API에는 ROI가 있고 가벼운 페이지에는 제한적입니다.

실측 중 HIT마다 DB state를 읽던 초기 장벽이 오히려 DB 질의를 늘리는 결함을 발견해, **커밋 전 emergency barrier + 전용 Redis clean runtime snapshot + 세대 검증**으로 교체했습니다. runtime barrier의 DB query는 0이며 페이지·카테고리 HIT도 플러그인 DB query 0으로 고정했습니다. 다만 `after_core` 앞의 코어 비용 약 7 Questions/request가 남고, 게시판은 route permission을 대신하는 guest role 선검증까지 포함해 9.1 Questions/request가 실측됐으므로 전체 요청 0-query를 주장하지 않습니다.

**TTL 중심 캐시는 채택하지 않습니다.** TTL은 데이터 변경을 알지 못하므로 신선도 보장 수단이 될 수 없습니다. G7PowerCache의 주 무효화 방식은 **동기 변경 감지 → 내구성 outbox 기록 → 커밋 후 세대 토큰 갱신 → 캐시 HIT 시 세대 벡터 검증**입니다. 훅이 기존 콘텐츠 트랜잭션 안에서 발행될 때만 outbox도 그 트랜잭션에 원자적으로 결합됩니다.

배포 단위는 **모듈이 아니라 단일 플러그인**이 맞습니다. 캐시는 자체 콘텐츠 도메인이 아니라 코어·게시판·쇼핑몰·페이지를 횡단하는 기능이고, G7 플러그인만으로 미들웨어·훅·설정·마이그레이션·권한·명령·스케줄·관리자 화면을 제공할 수 있습니다. 최고 성능이 필요할 때만 선택적 Nginx/CDN 어댑터를 덧붙입니다.

코어 수정 없이 상용 가치가 있는 비회원 API 캐시는 구현 가능합니다. 그러나 현재 확장 미들웨어 위치와 훅 공백 때문에 ‘모든 공개 GET 자동 캐시’와 ‘모든 쓰기 경로의 절대 정합성’은 과장입니다. v1은 정확한 라우트 허용목록으로 시작하고, 리뷰 공개상태·재고·권한·직접 SQL 공백은 상위 훅 또는 명시적 invalidate 계약으로 닫아야 합니다.

## 출시 결정: 제품 출시와 코어 개선 제안을 병행

**코어 개선이 끝날 때까지 제품을 보류할 이유는 없습니다.** 현재 훅으로도 페이지·카테고리처럼 안전성이 검증된 비회원 공개 응답을 가속할 수 있고, 게시판·상품도 허용목록·게스트 권한 프리플라이트·보수적 상위 세대 회전으로 단계적으로 확장할 수 있습니다. 반대로 훅 공백을 숨긴 채 ‘사이트 전체 자동 캐시’로 출시하면 오래된 가격·재고·권한 응답이나 회원 데이터 노출 위험을 제품이 떠안게 됩니다.

| 선택 | 판정 | 제품·코어에 미치는 영향 |
|---|---|---|
| 코어 개선 완료까지 출시 보류 | 기각 | 실제 플러그인 요구사항과 호환성 증거가 생기지 않고 출시만 지연 |
| 훅 공백을 무시한 전체 캐시 출시 | 기각 | 정합성·권한·개인화 사고를 제품 책임으로 떠안음 |
| 코어를 직접 패치한 캐시 출시 | 기각 | 업데이트 충돌과 설치 장벽으로 독립 제품성이 사라짐 |
| 안전 범위 플러그인 출시 + upstream 개선 제안 | **채택** | 제품은 즉시 검증하고, 공식 훅이 추가될수록 자동 지원 범위를 확장 |

출시는 다음 두 트랙으로 나눕니다.

1. **제품 트랙:** 현재 Gnuboard7 저장소의 번들 플러그인 경계 안에서 G7PowerCache를 개발하고, 제품 계약이 안정된 뒤 독립 저장소로 분리합니다. 초기 설치는 `observe`가 기본이고, doctor를 통과한 페이지·카테고리·비회원 공개 게시판 1~3페이지만 선택적으로 HIT를 허용합니다. 상품 카탈로그는 모든 관련 변경 경로가 훅·observer·명시적 invalidate 계약 중 하나로 닫힌 뒤 활성화합니다.
2. **코어 트랙:** 아래 3개 개선안을 서로 독립된 RFC/이슈와 실패 재현 테스트로 제안합니다. 코어 반영은 제품 출시 조건이 아니라 지원 범위 확대 조건입니다. 수용 전에는 관련 경로를 BYPASS하거나 넓은 세대를 회전합니다.

출시 단계의 명칭과 약속도 분리해야 합니다.

- **Technical Preview:** observe/doctor, 페이지·카테고리, generation/outbox, Redis 장애 fail-open을 검증합니다.
- **Beta:** 현재 게시판 공개 목록의 장시간 혼합부하·동시 쓰기·장애주입을 통과시키고, 상품 카탈로그는 활성 route별 mutation coverage가 완결된 경우에만 추가합니다.
- **GA:** 활성 route에서 회원 데이터 누출 0, 커밋 뒤 구세대 HIT 0, rollback 오무효화 0, 장애 복구 전 HIT 0을 자동 시험으로 증명한 범위만 지원합니다.

마케팅 문구는 ‘그누보드7 전체 자동 캐시’가 아니라 **‘검증된 비회원 공개 API를 변경 즉시 무효화하는 성능 플러그인’**이 정확합니다. 코어 훅이 늘어나면 새 버전에서 지원 route와 정밀 무효화 범위를 넓히면 됩니다.

## 제품·확장 유형 결정

| 선택 | 판정 | 이유 |
|---|---|---|
| 단일 플러그인 | **채택** | 요청을 횡단 처리하며 자체 비즈니스 콘텐츠를 소유하지 않음 |
| 모듈 | 기각 | 독립 데이터 도메인·공개 API가 주력이 아님 |
| 모듈+플러그인 | v1 기각 | 설치·버전·의존·장애 지점만 늘어남 |
| 플러그인+서버 어댑터 | 선택 | Laravel 부팅 전 Nginx/CDN HIT가 필요한 운영판에서만 제공 |

현재 소스는 `plugins/_bundled/g7-power_cache`에 두고 플러그인 디렉터리 밖의 코어는 수정하지 않습니다. 나중에 독립 저장소로 옮길 때 이 디렉터리를 그대로 추출할 수 있는 경계를 유지합니다. `plugin.json`의 코어 요구 버전은 7.0.8 이상이며 게시판 공개 route·권한·mutation hook 계약을 소비하므로 `sirsoft-board >=1.0.5`를 명시합니다. 활성 route가 없거나 middleware 계약이 다르면 doctor/BYPASS로 닫습니다.

## TTL의 역할 재정의

TTL은 세 가지에만 씁니다.

1. 무효화되어 더 이상 접근되지 않는 엔트리의 **고아 데이터 회수와 메모리 상한**
2. `is_new`, 예약 게시·라벨, 30일 인기창처럼 **DB 변경 없이 시간만 지나도 표현이 달라지는 필드의 경계 갱신**
3. 락 소유자 종료와 장애 회복을 위한 **안전 만료**

게시글·상품·설정 변경 신선도에는 TTL을 쓰지 않습니다. 변경 이벤트가 관련 세대를 즉시 바꾸고, 이전 세대 응답은 남아 있어도 HIT 대상에서 제외합니다. 무효 세대는 stale-while-revalidate로도 제공하지 않습니다.

## v1 라우트 그룹 정책 분류

아래 수치는 런타임 성능 측정치가 아니라, 정적 소스 감사에서 검토한 16개 설계 그룹의 안전성 분류입니다.

| 정책 | 그룹 수 | 의미 |
|---|---:|---|
| 즉시 허용 후보 | 2 | doctor 통과 후 선택 활성화 |
| 게스트 프리플라이트 | 6 | 권한·변형 계약을 코드로 검증해야 활성화 |
| 후속 검토 | 2 | 훅/응답 계약 보완 후 재판정 |
| v1 제외 | 6 | 상태·부수효과·고카디널리티·바이너리 |

## 초기 적용 범위 해석

‘즉시 허용 후보’는 설치 직후 자동 활성화라는 뜻이 아닙니다. 설치는 `observe` 모드로 시작하고 doctor·변형 검사·무효화 시뮬레이션을 통과한 뒤 관리자가 켭니다. 게시판과 상품은 현재 플러그인 캐시 게이트 뒤에 `optional.sanctum`과 `permission`이 남기 때문에 명시적 게스트 권한 프리플라이트 없이는 HIT를 반환하면 안 됩니다.

0.2.0에서는 아래 7번 게시글 목록만 추가 검증을 마쳐 활성화했습니다. 원본과 같은 guest read 권한 선검증, page 1~3, `per_page` 최대 50, 검색·분류·임의 정렬 BYPASS, PC/모바일 키 분리, 60초 시계 버킷, 게시판·글·댓글·첨부·권한·작성자 변경의 `board:all` 세대 회전을 함께 적용했습니다. 게시글 상세와 나머지 게시판 API는 계속 제외합니다.

## 라우트 그룹별 v1 정책

1. **즉시 허용 후보 — 발행 페이지 상세:** 게스트·200 JSON·발행본만, Authorization와 세션 쿠키는 BYPASS. 예시: sirsoft-page.pages.show. 세대 의존성: site, locale, page, page-attachment.
2. **즉시 허용 후보 — 상품 카테고리 트리·상세:** 라우트 권한 미들웨어 없음; 언어·카테고리 세대 필요. 예시: ecommerce.categories.index/show. 세대 의존성: site, locale, category-tree, category.
3. **게스트 프리플라이트 — 게시판 메타·목록성 요약:** 게시판 공개 여부와 게스트 권한 계약 확인 필요. 예시: boards index/show/menu/stats/recent/popular. 세대 의존성: guest-policy, board-index, board.
4. **게스트 프리플라이트 — 상품 일반 목록:** optional.sanctum·permission이 캐시 뒤; country/currency/device 변형. 예시: products.index. 세대 의존성: guest-policy, catalog, price, stock, reviews, shipping.
5. **게스트 프리플라이트 — 인기·신상품 목록:** 판매량·30일 창·예약 라벨 등 시간/주문 변이 포함. 예시: products.popular/new. 세대 의존성: guest-policy, catalog, popular/new, sales, time-bound.
6. **게스트 프리플라이트 — 상품 상세:** Auth wishlist/abilities와 배송국가에 따라 응답 변경. 예시: products.show. 세대 의존성: guest-policy, product, price, stock, reviews, shipping.
7. **게스트 프리플라이트 — 게시글 목록:** permission 미들웨어와 비밀글·모바일 per_page 정책 검증 필요. 예시: boards.posts.index. 세대 의존성: guest-policy, board, post-collection, comments.
8. **게스트 프리플라이트 — 게시글 네비게이션·댓글 목록:** permission 및 삭제·블라인드·비밀글 가시성 검증 필요. 예시: navigation/comments.index. 세대 의존성: guest-policy, board, post, comments.
9. **후속 검토 — 상품 리뷰·문의 공개 목록:** 리뷰 상태 변경 훅 공백과 문의 공개 범위 정합성 보완 후. 예시: products.reviews/inquiries. 세대 의존성: guest-policy, product, reviews/inquiries.
10. **후속 검토 — 코어 공개 레이아웃 API:** 사용자별 컴포넌트 필터 후 public max-age 응답 구조를 먼저 정리. 예시: public layout. 세대 의존성: guest-policy, template, layout, menu.
11. **v1 제외 — 게시글 상세:** GET이 조회수 증가 부수효과를 가지며 비밀글·작성자·관리자별 응답. 예시: boards.posts.show. 세대 의존성: -.
12. **v1 제외 — 최근 본 상품:** 임의 ids 조합의 고카디널리티·사용자 행동 기반. 예시: products.recent?ids=.... 세대 의존성: -.
13. **v1 제외 — 다운로드 가능 쿠폰:** 사용자 발급 가능 여부·시간·재고성 조건. 예시: downloadable-coupons. 세대 의존성: -.
14. **v1 제외 — 통합·게시판·쇼핑 검색:** 검색엔진 병목 해결책이 아니며 쿼리 카디널리티가 큼. 예시: search routes. 세대 의존성: -.
15. **v1 제외 — 장바구니·찜·주문·결제·인증·관리자:** 사용자·토큰·상태·부수효과가 핵심인 요청. 예시: stateful/private routes. 세대 의존성: -.
16. **v1 제외 — 파일·스트림·SSR web catch-all:** 바이너리는 웹서버/CDN 영역이고 web 후속 미들웨어를 우회할 수 있음. 예시: download/preview/image/web shell. 세대 의존성: -.

## 요청 파이프라인과 게스트 안전 경계

v1 캐시 위치는 `api, after_core`입니다. 이 지점은 모델 바인딩·최종 locale·timezone·IDV를 통과한 뒤여서 key variant를 정할 수 있고, 글로벌 Gzip 바깥쪽에 있어 비압축 정본을 저장할 수 있습니다. `before_core`는 이 절차들을 건너뛰므로 금지합니다.

하지만 `after_core` 뒤에도 라우트별 `OptionalSanctum`, `Permission`, `Throttle`이 남습니다. 따라서 HIT 전에 다음을 모두 만족해야 합니다.

- `Authorization`·`Proxy-Authorization`가 아예 없음. 만료·오류 Bearer도 BYPASS
- 설정된 세션/XSRF 쿠키·헤더, cart key, guest order token, preview/password/signature/verification 값 없음
- route name이 정확한 정책 허용목록에 있음
- `gatherRouteMiddleware()` 결과가 정책에 등록된 조합과 일치함
- 같은 route에 매칭되는 before_core/after_core 확장 미들웨어가 PowerCache 단독 계약과 일치함. 알 수 없는 광역 플러그인 미들웨어가 겹치면 BYPASS
- 해당 공개 origin 응답을 변형하는 filter hook이 등록되지 않음. 현재 카테고리 list/show 결과 필터가 하나라도 등록되면 BYPASS
- 알려진 `permission:user,...`는 동일 권한 로직으로 guest 프리플라이트를 통과함
- 알 수 없는 인증·개인화·서명·세션·확장 미들웨어가 있으면 BYPASS

unknown cookie는 기본 BYPASS입니다. 동의 배너처럼 응답을 바꾸지 않는 쿠키만 코드로 검토해 저카디널리티 allowlist에 추가합니다.

## 캐시 키·의존성 벡터

정규 키에는 설치 UUID, 포맷·정책 버전, 정규 host/site, route name과 route params, route별 검증된 query, 최종 locale·timezone, 필요한 경우 mobile/desktop·shipping country·currency가 들어갑니다. raw User-Agent·Accept-Language·Cookie를 그대로 키에 넣지 않습니다.

권장 엔트리는 `base request hash → response + dependency snapshot` 구조입니다. HIT 시 엔트리에 기록된 의존성 이름을 Redis `MGET`으로 읽어 현재 세대와 비교합니다. 하나라도 다르면 MISS입니다. 목록 응답은 collection 세대와 실제 노출 entity 세대를 함께 기록해 구성 변화와 개별 수정 모두를 잡습니다. 404 음수 캐시는 v1에서 끄며, 나중에 넣더라도 상위 collection 세대를 반드시 의존해야 합니다.

MISS 렌더 전후로 세대 벡터를 두 번 읽습니다. 중간에 변경됐으면 응답은 사용자에게 전달할 수 있어도 캐시에는 저장하지 않습니다. 이 fence가 커밋과 fill의 역전 경쟁을 막습니다.

## 저장 가능한 응답

GET만 원본을 생성하고, HEAD는 이미 존재하는 GET HIT에서 body만 제거해 반환합니다. 저장 조건은 `200 + application/json + 크기 상한`입니다. stream/file/SSE/redirect, `Set-Cookie`, `Location`, `WWW-Authenticate`, `no-store`, 지원하지 않는 `Vary`, 4xx/5xx는 저장하지 않습니다. Laravel JSON 응답의 기본 `private, no-cache`는 브라우저·공유 프록시 정책이므로 외부 응답에 그대로 보존하되, 서버 내부 origin cache 저장 자체를 막지는 않습니다.

저장 헤더는 Content-Type, Content-Language, ETag, Last-Modified 등 allowlist만 보존합니다. Date/Age와 hop-by-hop 헤더는 제거합니다. origin 캐시는 브라우저·공유 프록시 캐시와 분리하고 기본 응답은 재검증형 private/no-cache로 덮습니다. 현재 일부 코어 API의 `public,max-age`는 인증·timezone·country 변형을 충분히 Vary하지 않으므로 그대로 신뢰하면 안 됩니다. Edge 캐시는 purge 어댑터와 동일한 key contract가 검증된 뒤에만 별도 opt-in 합니다.

## 세대 토큰 계층

공통 계층은 `deploy`, `site`, `guest-policy`, `locale`, `template/layout`, `menu`입니다. 콘텐츠 계층은 `page:index/page:{id}`, `board:index/board:{id}/post:{id}/comments:{post}`, `shop:catalog`, `category-tree`, `category:{id}`, `product:{id}`, `price`, `stock`, `reviews`, `sales`, `popular`, `new`, `shipping`으로 나눕니다.

변경 필드를 확실히 아는 경우 최소 세대만 올립니다. 가격·재고·노출상태·카테고리·정렬 필드처럼 목록 구성에 영향이 있으면 entity와 collection 세대를 함께 올립니다. payload가 부족하거나 새 필드라 영향 판단이 안 되면 상위 collection 세대를 올립니다. 정밀성보다 오래된 응답 차단이 우선입니다.

세대 값은 Redis 단순 `time()`이 아니라 트랜잭션 아웃박스의 단조 증가 event id를 원자적으로 적용하는 편이 좋습니다. 중복·역순 replay가 가능하도록 `max(current,event_id)`를 Lua/transaction으로 적용하고, 설치·배포 epoch는 랜덤 UUID로 둬 ABA와 복원된 오래된 키의 재활성화를 막습니다.

## 도메인별 무효화 매트릭스

1. **전역·배포:** 코어/모듈/플러그인/템플릿 설치·활성·비활성·업데이트·삭제. 올릴 세대: deploy, site, guest-policy. 범위: 보수적 전체. 주의: 훅 없이 파일만 교체한 배포는 CLI purge 필수.
2. **설정:** core.settings after_save/after_set 및 module/plugin settings save/reset/delete. 올릴 세대: site 또는 board/page/shop 범위. 범위: 설정 키 매핑. 주의: 알 수 없는 공개 영향 키는 site.
3. **언어:** language pack install/update/activate/deactivate/uninstall. 올릴 세대: locale:{locale}, presentation. 범위: 로케일 단위. 주의: 키에는 원본 헤더가 아니라 최종 locale.
4. **권한·역할:** role create/update/delete/sync/toggle, board permission/role changes. 올릴 세대: guest-policy, menu, board. 범위: 정책 단위. 주의: PermissionService 직접 쓰기 훅 공백.
5. **메뉴·레이아웃:** menu CRUD/order/status/role sync, layout update/restore/cache clear. 올릴 세대: menu, template, layout. 범위: 템플릿·레이아웃 단위. 주의: URL 역참조가 없으면 템플릿 전체.
6. **페이지:** page create/update/delete/publish/restore. 올릴 세대: page:index, page:{id}, old/new slug. 범위: 페이지 단위. 주의: 일부 훅은 트랜잭션 내부.
7. **페이지 첨부:** attachment upload/delete/reorder. 올릴 세대: page:{id}. 범위: 연결 페이지. 주의: 임시 업로드는 제외.
8. **게시판:** board create/update/delete, bulk settings, menu add/remove. 올릴 세대: board:index, board:{id}, menu. 범위: 게시판 단위. 주의: bulk payload 불충분 시 board 전체.
9. **게시글:** post create/update/delete/blind/restore. 올릴 세대: post:{id}, board collection, recent/home. 범위: 글+목록. 주의: rename/visibility/category 변경은 넓게.
10. **댓글:** comment create/update/delete/blind/restore. 올릴 세대: comments:{post}, post:{id}, board list if count exposed. 범위: 글 단위. 주의: 기존 SEO 리스너는 댓글 누락.
11. **게시판 첨부:** attachment upload/link/delete/reorder. 올릴 세대: post:{id}, board list if thumbnail exposed. 범위: 글 단위. 주의: post_id 없는 임시는 제외.
12. **상품:** product CRUD/bulk/price/stock/options sync. 올릴 세대: product:{id}, catalog, price, stock, category. 범위: 필드 판정. 주의: bulk 훅 인자 형식 혼재.
13. **상품 이미지:** product-image upload/delete/reorder. 올릴 세대: product:{id}, catalog. 범위: 상품+썸네일 목록. 주의: 현재 SEO 리스너 누락.
14. **카테고리:** category CRUD/status/reorder 및 category-image. 올릴 세대: category-tree, category:{id}, catalog. 범위: 카테고리 단위. 주의: 조상/자손 또는 전체 tree.
15. **브랜드·라벨·고시:** brand/label/common-info/notice 변경. 올릴 세대: 관련 product, catalog/filter. 범위: 역조회 가능 시 정밀. 주의: 역조회 불가 시 catalog 전체.
16. **재고·주문:** stock deduct/restore, order payment/status/cancel. 올릴 세대: product, stock, sales, popular, catalog. 범위: 주문 상품 단위. 주의: 일부 직접 옵션 재고 변경 훅 공백.
17. **리뷰:** review create/delete/bulk delete/image. 올릴 세대: reviews:{product}, product, catalog. 범위: 상품 단위. 주의: 단건/일괄 공개상태 변경 훅 없음.
18. **문의:** inquiry create/reply. 올릴 세대: inquiries:{product}, product if count exposed. 범위: 상품 단위. 주의: 공개 범위 검증 전 캐시 비활성.
19. **배송:** shipping policy/settings create/update/status/default/delete. 올릴 세대: shipping, product/catalog. 범위: 정책 역조회. 주의: country는 캐시 키 변형.
20. **직접 SQL:** 더미 생성·리셋, 시더, importer, DB 관리도구. 올릴 세대: 명시적 domain 또는 site purge. 범위: 운영 계약. 주의: 코어 무수정 자동 포착 불가.

## 트랜잭션 아웃박스와 복구 장벽

Action 훅은 기본 큐이므로 G7PowerCache 무효화 리스너는 전부 `sync: true`로 등록합니다. coordinator는 훅 호출마다 scope를 정규화한 뒤 다음 순서로 처리합니다.

1. 트랜잭션 안이면 같은 DB 트랜잭션에 invalidation outbox와 dirty ID를 기록하고 전용 저장소 emergency barrier를 설정
2. `DB::afterCommit()`에서 Redis 세대를 적용하고 outbox를 완료 처리
3. 트랜잭션 밖이면 먼저 내구성 있는 outbox를 기록한 뒤 즉시 적용
4. rollback이면 outbox도 사라지고 세대는 바뀌지 않으며, 남은 emergency barrier는 fail-closed 상태로 운영 확인 후 site purge로 회복
5. Redis/file 적용 실패면 미처리 outbox와 DB `dirty_event_id`를 남김
6. 적용·DB clean 확인·전용 저장소 runtime snapshot 반영이 모두 끝난 뒤 emergency barrier 해제
7. 정상 HIT는 전용 저장소 snapshot·emergency·세대만 읽고, dirty/snapshot 소실 때만 DB outbox 복구 경로 실행

단순 `afterCommit()` 콜백만 쓰면 DB 커밋 직후 프로세스가 죽는 작은 유실 구간이 남으므로 현재 구현은 DB outbox와 dirty 장벽을 함께 둡니다. 다만 일부 서비스가 콘텐츠 커밋 뒤에야 after 훅을 발행하므로 콘텐츠 commit과 outbox 기록 사이의 극소 구간은 코어 무수정으로 완전히 제거할 수 없습니다. 현재 `0.2.0`에는 모델 observer가 없으며, 후속 단계에서 observer·쓰기 경로 어댑터를 보조로 검토하고 최종적으로는 공식 mutation/outbox seam을 상위에 보완해야 합니다.

## 확인된 무효화 공백

- 상품 리뷰 공개상태 단건·일괄 변경은 DB를 바꾸지만 after 훅이 없습니다. 공개 리뷰 수·평점이 상품 목록에 들어가므로 영구 stale 위험입니다.
- 일부 옵션 재고 직접 변경 메서드는 정규 재고 변경 훅이 없습니다.
- RoleService 훅은 있으나 일반 Permission 직접 쓰기 훅을 찾지 못했습니다.
- 이커머스 훅 이름에 `product_option/option`, `order_option/order-option` 혼용이 있어 양쪽을 구독해야 합니다.
- 더미 생성·리셋, 샘플 시더, importer, 외부 SQL은 서비스 훅과 Eloquent event를 우회합니다.

현재 구현된 임시 대책은 `power-cache:purge --scope=...` 명령과 공식 훅의 보수적 상위 세대 회전입니다. 관리자 성공 응답 어댑터, 모델 observer, 서명 webhook, importer SDK는 후속 후보이지 구현 완료 기능이 아닙니다. 직접 SQL까지 자동으로 정확한 URL 의존성으로 변환하는 것은 코어 무수정으로 불가능하므로 더미 생성·초기화 완료 시 도메인 또는 site purge를 공식 완료 단계로 넣어야 합니다.

## 스탬피드·SWR·장애 정책

Redis는 최종 request key별 분산락을 사용합니다. winner만 origin을 렌더하고, follower는 50~150ms jitter로 총 약 500ms 안에서 재조회한 뒤 데이터가 없으면 origin passthrough하되 저장 경쟁에는 참여하지 않습니다. lock lease는 관측된 origin p99를 기준으로 잡고 owner token으로 안전 해제합니다.

후속 버전에서 SWR을 추가하더라도 soft-expire 뒤 hard retention 전의 **같은 세대** stale만 제공할 수 있습니다. 세대가 바뀌면 stale 금지입니다. 0.2.0은 SWR을 구현하지 않고 MISS로 처리합니다. File 드라이버는 Laravel FileStore lock을 쓰는 단일 노드 전용이며, `G7_POWER_CACHE_FILE_SINGLE_NODE=true` 확인이 없으면 active HIT를 차단합니다.

Redis 오류는 origin fail-open으로 처리해 캐시 때문에 5xx가 생기지 않게 합니다. 세대를 확인할 수 없으면 L1 stale도 금지합니다. 복구 때는 DB outbox replay와 dirty 해제가 완료된 뒤에만 HIT를 다시 허용합니다. Redis는 세션·큐·기본 캐시와 별도 connection/DB를 써야 하며 FLUSHDB를 금지합니다.

## 설정과 코드 불변식

0.2.0 구현값은 다음과 같습니다.

1. **mode:** 기본 `observe`; `observe | active | bypass`.
2. **store_driver:** 기본 `file`; `file | redis`. array는 독립 테스트에서만 허용.
3. **cache_public_pages/cache_public_categories/cache_public_board_lists:** 기본 true지만 observe이므로 설치 직후 HIT는 없음. 게시판은 1~3페이지·`per_page` 최대 50만 허용.
4. **automatic_recovery:** 기본 true. dirty outbox를 요청 장벽에서 제한된 batch로 재생.
5. **metrics_enabled/debug_headers:** 각각 기본 true/false. 디버그 헤더는 운영자가 명시적으로 켬.
6. **max_response_kb:** 기본 512, 범위 16~4096.
7. **retention_seconds:** 기본 604800(7일), 범위 1시간~30일. 신선도 수단이 아니라 고아 body 회수 한도.
8. **lock_wait_ms/lock_lease_seconds:** 기본 500ms/15초. 동시 MISS follower 대기와 fill lock 안전 만료.
9. **recovery_batch:** 기본 100, 범위 1~1000.
10. **G7_POWER_CACHE_REDIS_*:** Redis 주소·인증·전용 DB·prefix. 비밀은 관리자 설정에 저장하지 않음.
11. **G7_POWER_CACHE_FILE_SINGLE_NODE / FILE_GC_SAFE_ROOT:** file active의 필수 단일 노드 확인과 만료 파일 삭제 허용 전용 상위 경로. 확인이 없으면 HIT를, 안전 루트 밖이면 GC 삭제를 차단.
12. **site_id/runtime_epoch:** 설치 마이그레이션이 DB에 UUID를 만들며, 활성·비활성·자체 설정 변경 때 epoch 회전.
13. **코드 불변식:** guest-only, GET/HEAD-only, exact route allowlist, unknown cookie/query/middleware BYPASS.
14. **응답 불변식:** Set-Cookie/no-store/stream/redirect/error 미저장. `private, no-cache`는 외부 헤더를 보존하며 내부 origin cache에는 저장 가능.

아직 구현하지 않은 설정은 `policy_preset`, 상품 route 토글, SWR, warming입니다. 안전 범위가 검증되기 전 UI에 노출하지 않습니다.

## 관리자 화면·명령

관리자 화면은 TTL 슬라이더가 중심이 아니라 안전 상태와 ROI가 중심이어야 합니다. 표시할 항목은 현재 mode, store health, dirty/recovery barrier, route별 HIT/MISS/BYPASS·사유, origin 시간과 DB query 절감, lock wait, outbox 지연·실패, 엔트리 용량·eviction, warming 상태입니다.

0.2.0은 `power-cache:doctor`, `status`, `mode`, `purge`, `reconcile`, `gc`를 구현했습니다. `mode`는 `bypass | observe | active`를 전환하며 doctor 실패 시 active 진입을 차단합니다. purge scope는 현재 실제 캐시 범위와 일치하는 `site | page | category | board`만 받습니다. GC는 매일 적용 완료된 오래된 outbox 이력과 file 저장소의 만료 물리 파일만 정리하며 미적용 이벤트와 신선도에는 관여하지 않습니다. Redis 물리 만료는 Redis TTL이 담당합니다. `invalidate` 세분화와 `warm`은 상품 정책과 운영 메트릭이 추가되는 후속 단계입니다. 비활성화·업데이트는 수백만 키 SCAN/DELETE 대신 runtime epoch를 회전하고, 기존 body는 retention으로 회수합니다.

## 권장 코드 구조

```text
plugins/_bundled/g7-power_cache/
├─ plugin.json, plugin.php, composer.json, CHANGELOG.md, LICENSE
├─ config/{power_cache.php,settings/defaults.json}
├─ database/migrations/        # state, outbox
├─ resources/layouts/admin/
├─ src/Providers/PowerCacheServiceProvider.php
├─ src/Http/Middleware/GuestResponseCache.php
├─ src/Eligibility/GuestEligibility.php
├─ src/Policy/{RoutePolicyRegistry,RoutePolicy,ResponsePolicy}.php
├─ src/Keys/CanonicalRequestKey.php
├─ src/Invalidation/{InvalidationCoordinator,InvalidationApplier,OutboxReconciler}.php
├─ src/Infrastructure/DatabaseInvalidationRepository.php
├─ src/Listeners/{ContentInvalidationListener,CoreInvalidationListener}.php
├─ src/Store/LaravelPowerCacheStore.php
├─ src/Console/Commands/
└─ tests/{Unit,Feature,Support}/
```

응답 body·세대·락은 플러그인 전용 store interface로 관리합니다. 코어 `CacheInterface`를 글로벌 재바인딩하지 않습니다. 현재 확장 캐시 드라이버의 tag 삭제는 단일 key-tag 인덱스를 읽고 다시 쓰는 구조여서 고카디널리티 응답 캐시에 부적합합니다. 세대 무효화는 키 목록을 유지하거나 SCAN할 필요가 없습니다.

## 단계별 구현 계획과 종료 기준

1. **P0 계약·관측 — 1차 완료:** 번들 플러그인 골격, observe 모드, route policy registry, doctor/status/mode, 요청·훅 계약 테스트 구현. 관리자 상세 대시보드는 후속.
2. **P1 안전 코어 — 코드·독립 테스트·온라인 smoke 완료:** guest eligibility, canonical key, file/Redis store, 페이지·카테고리, generation/outbox/recovery barrier 구현. SQLite+array 회귀와 실제 Redis·MySQL·HTTP의 MISS→HIT·scope purge·doctor·ON/OFF A/B 통과. 장시간 혼합 부하와 장애 주입은 Beta gate로 남음.
3. **P2 게시판·상품:** guest permission preflight, shipping/device/currency 변형, 게시판·상품 훅 어댑터. 종료 기준: 권한/비밀/회원 데이터 누출 0; 상세 부수효과 라우트 제외.
4. **P3 운영 완성 — 일부 완료:** 분산락, doctor/status/mode/purge/reconcile/gc, 기본 관리자 설정은 완료. 같은 세대 SWR, warming, metrics rollup·상세 대시보드는 후속. 종료 기준: 100 동시 cold miss origin 1~2회; 무효 세대 stale 0.
5. **P4 상위 보완:** 리뷰 상태·재고·Permission 정규 훅 제안, importer contract, 선택 edge adapter. 종료 기준: 공식 쓰기 경로 훅 공백 해소; core-free 범위 문서화.

## 필수 인수·회귀·장애 테스트

1. **격리:** guest ↔ valid/expired/invalid bearer ↔ session cookie. 합격 기준: 서로 캐시 공유 0, 비게스트는 항상 BYPASS.
2. **변형:** locale/timezone/device/country/currency/host. 합격 기준: 각 응답 정확, 불필요한 raw header 카디널리티 없음.
3. **키 안전:** query 순서·기본값·중첩·unknown·초장문 fuzz. 합격 기준: 동등 요청만 같은 키; unknown은 BYPASS.
4. **응답 안전:** Set-Cookie/no-store/미지원 Vary/stream/redirect/4xx/5xx/대용량. 합격 기준: 저장 0. `private, no-cache`는 내부 origin cache 저장 후 외부 헤더가 보존됨.
5. **권한:** 게시판/상품 게스트 권한 허용→차단 전환. 합격 기준: 다음 요청은 새 세대 또는 401/403; 이전 200 없음.
6. **트랜잭션:** commit/rollback/동시 fill 중 mutation. 합격 기준: commit만 bump; 세대 변경 중 생성 응답 미저장.
7. **아웃박스:** commit 직후 프로세스 종료, 중복·역순 replay. 합격 기준: 유실 0, idempotent, replay 전 HIT 금지.
8. **스탬피드:** 동일 키 100개 동시 cold request. 합격 기준: origin render 1~2회, follower 제한 대기 후 안전 통과.
9. **SWR(후속 구현 시):** soft-expire와 mutation generation change 동시. 합격 기준: 같은 세대 stale만 허용; 무효 세대 stale 0.
10. **장애:** Redis down/timeout/recovery. 합격 기준: 캐시 원인 5xx 0; origin 제공; reconcile 전 HIT 금지.
11. **저장소 격리:** purge/GC/Redis flush guard. 합격 기준: 세션·큐·타 확장 sentinel 보존.
12. **직접 SQL:** 더미 생성·리셋·시더·importer. 합격 기준: 완료 후 명시적 domain/site invalidation 실행.
13. **시간 의존:** is_new, 인기 30일 창, 예약 라벨 경계. 합격 기준: 시간 경계 refresh가 데이터 변경 TTL과 분리.
14. **성능:** cold/warm p50/p95/p99, DB query, CPU/RSS, Redis ops. 합격 기준: 각 route ROI와 비용을 튜닝 off/on으로 기록.
15. **생명주기:** install→activate→deactivate→update→rollback→uninstall. 합격 기준: 코어·번들 모듈·템플릿 수정 0, stale 재활성화 0.

## 코어 수정 없는 범위와 상위 보완 제안

코어 무수정으로 가능한 것은 검증된 비회원 공개 API, 이벤트 세대 무효화, file/Redis 저장소, 진단·purge·warming·장애 fail-open입니다. 불가능한 것은 모든 GET의 안전한 자동 캐시, 직접 SQL의 완전 자동 포착, 라우트별 권한 미들웨어보다 뒤라는 절대 보장, PHP/Laravel 부팅 제거, 다중 노드 file 일관성입니다.

제품 v1을 막는 코어 수정은 없습니다. 다만 범위를 안전하게 넓히려면 상위에 세 가지 작은 공개 seam을 제안하는 것이 ROI가 높습니다.

1. 라우트 인증·권한 검사 뒤, 컨트롤러 전후에 실행되는 `after_route_guards` 응답 캐시 지점
2. 리뷰 상태·상품/옵션 재고·Permission 변경의 정규 after hook
3. bulk/importer가 같은 트랜잭션에 무효화 outbox scope를 기록하는 공개 계약

이것들은 플러그인이 코어를 패치하라는 뜻이 아니라 상위 호환 API 제안입니다. 제안이 수용되기 전에는 해당 라우트·변경 경로를 BYPASS하거나 보수적 전체 세대 회전으로 처리합니다.

### upstream 제출 형식

‘캐시에 훅이 부족하다’는 포괄 이슈 하나로 제출하지 않습니다. 코어팀이 캐시 제품을 알아야만 이해할 수 있는 전용 API도 요구하지 않습니다. 아래처럼 확장 전체가 재사용할 수 있는 공개 계약 3건으로 분리합니다.

| RFC | 코어에 요청할 계약 | 실패 재현·합격 기준 | 제품의 대기 전략 |
|---|---|---|---|
| 확장 응답 지점 | 라우트 인증·권한·IDV 적용 뒤, 컨트롤러 호출 전후의 명명된 확장 seam | 인증/권한 실패 요청에서는 cache handler 미실행, 허용 요청에서는 route name·user state·response를 안정적으로 전달 | 현재 `after_core` 위치에서는 정확한 allowlist와 게스트 권한 프리플라이트 사용 |
| 정규 mutation 훅 | 리뷰 상태·답변, 상품/옵션 가격·재고, Permission 변경에 old/new snapshot과 entity ID를 가진 sync 가능한 after hook | 단건·일괄·복원·삭제 각 경로에서 성공 시 1회, rollback 시 외부 효과 0, 훅 이름·payload 일관 | observer와 기존 훅을 병행하고 공백 route는 BYPASS 또는 catalog/guest-policy 상위 세대 회전 |
| bulk/import scope | 대량 변경·importer가 같은 DB 트랜잭션에 domain/entity invalidation scope 또는 outbox record를 남기는 공개 계약 | commit이면 scope 1회 병합, rollback이면 0, worker 종료 후 replay 가능, 중복 replay 멱등 | 플러그인 CLI·서명 webhook·importer SDK를 제공하고 미연동 직접 SQL 뒤에는 site invalidate 요구 |

각 RFC에는 현재 커밋에서 실패하는 계약 테스트, 기대 실행 순서, payload 스키마, 버전 호환 규칙을 붙입니다. 코어가 수용하면 플러그인은 어댑터를 공식 훅으로 교체할 뿐 현재 플러그인 디렉터리 경계와 캐시 알고리즘은 바뀌지 않아야 합니다.

## 최종 판단

**만들 수 있습니다. 그리고 플러그인이 맞습니다.** 단, 이름은 ‘자동 전체 페이지 캐시’가 아니라 **‘그누보드7 비회원 공개 API를 검증된 허용목록과 트랜잭션 안전 세대 무효화로 가속하는 플러그인’**이어야 정확합니다.

현재 구현은 `observe/doctor`, guest eligibility, route policy registry, generation/outbox, 페이지·카테고리, 게시판 권한 프리플라이트와 hot-list 무효화까지 닫았습니다. 다음 우선순위는 장시간 혼합부하·동시 쓰기/장애주입과 상품 카탈로그의 mutation coverage입니다.

## 근거 소스

- [검토 커밋](https://github.com/jiwonpapa/gnuboard7/tree/7f127797473df1620d26490d4699d52a98951b3e)
- [확장 미들웨어 등록](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/bootstrap/app.php#L99-L131)
- [확장 미들웨어 게이트](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/app/Http/Middleware/ExtensionMiddlewareGate.php#L47-L64)
- [액션 훅 동기·비동기 정책](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/app/Extension/HookListenerRegistrar.php#L14-L18)
- [확장 캐시 바인딩 규약](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/docs/extension/cache-driver.md#L135-L159)
- [기본 캐시 태그 인덱스 구현](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/app/Extension/Cache/AbstractCacheDriver.php#L163-L175)
- [플러그인 확장 표면](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/docs/extension/plugin-development.md#L196-L245)
- [쇼핑 공개 라우트](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-ecommerce/src/routes/api.php#L62-L126)
- [게시판 공개 라우트](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-board/src/routes/api.php#L411-L496)
- [페이지 공개 라우트](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-page/src/routes/api.php#L114-L138)
- [게시글 상세 조회수 부수효과](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-board/src/Http/Controllers/User/PostController.php#L135-L168)
- [상품 응답 사용자·배송국가 변형](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-ecommerce/src/Http/Resources/PublicProductResource.php#L163-L176)
- [리뷰 상태 변경 훅 공백](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-ecommerce/src/Services/ProductReviewService.php#L177-L184)
- [리뷰 일괄 상태 변경 훅 공백](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-ecommerce/src/Services/ProductReviewService.php#L266-L272)
- [옵션 재고 훅 이름과 payload 경로](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/modules/_bundled/sirsoft-ecommerce/src/Services/ProductOptionService.php#L138-L147)
- [PermissionService 공개 훅 표면](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/app/Services/PermissionService.php#L1-L78)
- [기존 공개 캐시 헤더](https://github.com/jiwonpapa/gnuboard7/blob/7f127797473df1620d26490d4699d52a98951b3e/app/Http/Controllers/Api/Base/BaseApiController.php#L278-L298)

## 증거 경계

- 확인됨: 위 커밋의 소스 구조, 라우트 선언, 훅 발행 위치, 미들웨어 등록 순서, 플러그인 확장 표면.
- 구현·독립 테스트 확인: `g7-power_cache` 골격과 전용 DI 바인딩, guest default-deny, 게시판 read 권한·페이지 범위·PC/모바일 변형, route/확장 middleware 및 origin filter 계약, 공개 운영설정 비노출, 관리자 레이아웃 구조·endpoint 규칙, canonical key, 응답 필터와 저장물 재검증, 세대 단조성, 페이지·카테고리 정상 HIT의 플러그인 DB query 0, outbox commit/rollback, MISS→HIT→무효화, 장애 후 replay, 적용 완료 outbox 및 안전 루트 제한 만료 file 캐시 GC. 33 tests / 352 assertions.
- 온라인 smoke 확인: MySQL·Redis 설치/활성화, route middleware doctor PASS, mode OFF→ON, 네 라우트 MISS→HIT, page/category/board scope purge 격리, 게시판 active/bypass 응답 SHA-256 동일, 80건·동시 4 ON/OFF p50/p95/p99·FPM CPU·MySQL Questions, Redis key/메모리 표본. 상세 수치는 별도 실측 보고서에 기록.
- 정적 추론: 상용 범위 확대에 필요한 upstream seam과 아직 활성화하지 않은 상품 정책.
- 아직 미측정: 장시간 혼합 트래픽, exact 세션별 SQL profile, 동시 쓰기·cold stampede 100개, Redis 장애 주입·복구, 반복 실험의 신뢰구간, 장기 RSS/swap와 Redis ops/network 비용. Technical Preview를 Beta로 올리기 전에 같은 하네스로 별도 검증해야 합니다.
