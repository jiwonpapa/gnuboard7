# G7PowerCache

G7PowerCache는 **검증된 비회원 공개 JSON API**를 세대 기반 무효화로 가속하는 Gnuboard7 플러그인입니다. 데이터 신선도를 TTL에 맡기지 않고, 변경 훅이 실행되면 내구성 있는 outbox를 기록한 뒤 캐시 세대를 회전합니다.

현재 버전은 `0.2.0 Technical Preview`입니다. 독립 저장소 분리는 보류하고 Gnuboard7 저장소의 `plugins/_bundled/g7-power_cache`에서 개발합니다. 플러그인 디렉터리 밖의 코어 수정 없이 동작하므로 나중에 이 디렉터리를 그대로 분리할 수 있습니다.

## 현재 지원 범위

| 구분 | 지원 |
|---|---|
| 공개 페이지 상세 | `api.modules.sirsoft-page.pages.show` |
| 쇼핑몰 공개 카테고리 | `categories.index`, `categories.show` |
| 공개 게시판 목록 | 비회원 read 권한 게시판의 1~3페이지, `per_page` 최대 50 |
| 인증 요청 | 항상 BYPASS |
| 쿠키·미등록 query·미등록 route middleware | 항상 BYPASS |
| 게시글 상세·상품·검색·장바구니·주문 | 현재 캐시하지 않음 |
| 응답 형식 | 200 JSON, 크기 상한 이내 |
| 저장 금지 | Set-Cookie, no-store, redirect, 인증/다운로드 헤더, 미지원 Vary |

카테고리 트리에 공개 상품 수가 포함되므로 카테고리뿐 아니라 상품 생성·수정·삭제·일괄 변경도 `category:tree` 세대를 회전합니다.

게시판 목록은 원본 `permission:user,sirsoft-board.{slug}.posts.read`와 같은 `GuestRoleResolver`로 비회원 권한을 먼저 확인합니다. 글·댓글·첨부·게시판 설정·권한·작성자 표시가 바뀌면 `board:all` 세대를 즉시 회전합니다. `created_at_formatted`, `is_new`, 조회수처럼 DB 쓰기 없이도 표시가 변하는 값만 60초 시계 버킷으로 제한하며, 콘텐츠 신선도는 계속 변경 훅 무효화가 담당합니다. PC/모바일 `per_page` 차이는 별도 키로 격리합니다.

## 정합성 모델

1. 변경 훅 리스너는 모두 `sync: true`로 실행됩니다.
2. 훅 실행 시 DB 트랜잭션이 열려 있으면 같은 트랜잭션에 outbox와 `dirty_event_id`를 기록합니다. 트랜잭션 밖이면 전용 짧은 트랜잭션으로 먼저 기록합니다.
3. 커밋 뒤 outbox ID를 세대 값으로 적용합니다.
4. 정상 HIT는 전용 저장소의 clean runtime snapshot, 비상 장벽, 현재 세대 벡터를 모두 통과해야 합니다. DB state는 snapshot 최초 생성·dirty 복구·운영 진단 때만 읽습니다.
5. Redis/file 오류가 나면 원본 컨트롤러로 fail-open하고 캐시 때문에 5xx를 만들지 않습니다.
6. 미적용 outbox가 하나라도 있으면 복구 전까지 모든 HIT를 금지합니다.

변경 감지 시 DB 커밋 전에 전용 저장소의 비상 장벽을 먼저 세우고, 커밋 후 세대 적용·outbox 완료·clean snapshot 반영이 모두 끝난 뒤 장벽을 내립니다. 이 때문에 평상시 HIT는 파워캐시 자체 DB 질의를 만들지 않으면서도, 커밋 직후 프로세스 종료나 저장소 적용 실패 때는 이전 응답을 제공하지 않습니다. 트랜잭션 rollback 뒤 남은 fail-closed 장벽은 운영자가 `power-cache:purge --scope=site`로 확인·회복합니다.

현재 코어의 일부 after 훅은 콘텐츠 트랜잭션이 이미 커밋된 뒤 발행됩니다. 그 경로는 콘텐츠 커밋과 outbox 기록 사이의 프로세스 강제 종료 구간을 플러그인만으로 원자화할 수 없습니다. 따라서 `0.2.0`은 Technical Preview이며, 절대 정합성이 필요한 운영 활성화는 동일 트랜잭션 mutation seam 또는 해당 쓰기 경로 어댑터가 추가된 뒤 판정해야 합니다.

`retention_seconds`는 오래된 물리 엔트리를 회수하기 위한 백엔드 보존시간입니다. 데이터 신선도 TTL이 아닙니다. 세대가 바뀐 엔트리는 보존시간이 남아도 즉시 MISS입니다.

## 설치

```bash
php artisan plugin:install g7-power_cache --vendor-mode=bundled
php artisan plugin:activate g7-power_cache
php artisan power-cache:doctor
```

설치 기본 모드는 `observe`입니다. 이 모드는 적합성만 검사하고 응답을 저장하거나 HIT로 제공하지 않습니다. doctor를 통과한 뒤 관리자 플러그인 설정에서 `active`로 바꿉니다.

### 단일 노드 file 저장소

file 드라이버로 실제 HIT를 허용하려면 단일 PHP 노드라는 운영 확인이 필요합니다.

```dotenv
G7_POWER_CACHE_FILE_SINGLE_NODE=true
```

확인이 없으면 `active`여도 복구 장벽이 `file_single_node_unacknowledged`로 HIT를 차단합니다.
file 경로를 기본 `storage/app/g7-power-cache/cache` 밖으로 옮길 경우 만료 파일 GC가 다른 디렉터리를 건드리지 않도록 `G7_POWER_CACHE_FILE_GC_SAFE_ROOT`를 전용 상위 디렉터리로 명시해야 합니다. 안전 루트 밖이면 GC는 삭제하지 않습니다.

### Redis 저장소

운영·다중 노드는 세션·큐·기본 캐시와 분리된 Redis DB를 사용하십시오.

```dotenv
G7_POWER_CACHE_REDIS_HOST=127.0.0.1
G7_POWER_CACHE_REDIS_PORT=6379
G7_POWER_CACHE_REDIS_PASSWORD=
G7_POWER_CACHE_REDIS_DB=7
G7_POWER_CACHE_REDIS_PREFIX=gnuboard7:g7pc:
```

플러그인은 `FLUSHDB`, 태그 인덱스, 전체 key scan으로 무효화하지 않습니다. 세대만 회전하고 물리 엔트리는 retention으로 회수합니다.

## 운영 명령

```bash
php artisan power-cache:doctor
php artisan power-cache:status
php artisan power-cache:mode bypass
php artisan power-cache:mode observe
php artisan power-cache:mode active
php artisan power-cache:purge --scope=site --reason=deploy
php artisan power-cache:purge --scope=page --reason=page-import
php artisan power-cache:purge --scope=category --reason=product-import
php artisan power-cache:purge --scope=board --reason=board-import
php artisan power-cache:reconcile --limit=100
php artisan power-cache:gc --days=7
```

- `doctor`: 저장소 read/write, DB state/outbox, route·middleware 계약, Redis DB 격리를 검사합니다.
- `status`: 현재 모드와 dirty/outbox 상태를 조회합니다.
- `mode`: `bypass`(OFF), `observe`(저장 없이 판정), `active`(ON)를 전환합니다. `active`는 doctor가 실패하면 전환 자체를 차단합니다.
- `purge`: key 삭제 없이 `site`, `page:all`, `category:tree`, `board:all` 세대를 회전합니다.
- `reconcile`: 중복·역순 실행에도 안전하게 미적용 outbox를 재생합니다.
- `gc`: 적용 완료된 오래된 outbox 감사 이력과 file 저장소의 만료 물리 파일을 정리합니다. 미적용 행과 캐시 신선도에는 영향을 주지 않습니다. Redis 물리 만료는 Redis 자체 TTL이 담당합니다.

더미 생성기, importer, seed, 외부 SQL처럼 공식 Service 훅을 우회하는 변경 뒤에는 반드시 해당 scope purge를 실행해야 합니다. 변경 범위를 모르면 `--scope=site`를 사용하십시오.

## 보안 불변식

다음 항목은 관리자 설정으로 완화할 수 없습니다.

- GET/HEAD 및 정확한 route allowlist만 허용
- Authorization/Proxy-Authorization와 민감 토큰 헤더가 있으면 BYPASS
- 사용자 객체나 쿠키가 하나라도 있으면 BYPASS
- route 정책에 없는 query/middleware가 있으면 BYPASS
- 게시판 목록은 원본과 같은 guest read 권한 선검증 실패 시 BYPASS
- 게시판 목록은 1~3페이지·`per_page` 최대 50만 허용하고 PC/모바일 키를 분리
- 같은 route에 다른 before_core/after_core 확장 미들웨어가 겹치면 BYPASS
- 공개 응답을 변형하는 origin filter hook이 등록되어 있으면 BYPASS
- 저장 전후 세대가 다르면 미저장
- HEAD MISS는 원본만 호출하고 캐시를 생성하지 않음
- Set-Cookie/no-store/인증·다운로드·redirect 응답은 미저장
- 세대 확인이나 복구 장벽 확인이 실패하면 stale 응답 제공 금지

기본 Laravel JSON 응답의 `private, no-cache`는 브라우저 캐시 정책으로 보존하되, 서버 내부 origin cache 저장 자체를 막지는 않습니다. `no-store`만 절대 저장 금지입니다.

## 알려진 제한

- 현재 실제 HIT 지원은 페이지 상세, 카테고리 API, 공개 비회원 게시판 hot-list입니다.
- 캐시 HIT는 extension `api, after_core` 지점에서 반환되므로 해당 route의 `optional.sanctum`·throttle을 실행하지 않습니다. 이를 허용한 세 route만 정확한 middleware 계약으로 고정합니다.
- `after_core` 앞에서 실행되는 코어 API 미들웨어 비용은 남습니다. runtime barrier와 페이지·카테고리 HIT는 플러그인 DB를 읽지 않지만, 게시판은 뒤쪽 route permission을 안전하게 대체하기 위해 guest role/permission을 요청당 한 번 읽습니다. 전체 HTTP 요청을 0-query로 만들려면 인증·권한·IDV 뒤/컨트롤러 앞의 공식 코어 seam 또는 PHP 부팅 전 서버 어댑터가 필요합니다.
- 직접 SQL 변경을 자동 감지할 수 없습니다.
- 코어가 콘텐츠 커밋 뒤 after 훅을 발행하는 경로에는 커밋과 outbox 사이의 프로세스 종료 공백이 남습니다.
- 다중 노드 file 저장소는 지원하지 않습니다.
- 전체 페이지 HTML, 바이너리, 검색 결과, 사용자별 응답은 지원하지 않습니다.
- PHP/Laravel 부팅 전 캐시는 별도 서버 어댑터 범위입니다.

## 검증

저장소 루트에서 독립 테스트를 실행할 수 있습니다.

```bash
vendor/bin/phpunit --no-configuration \
  --bootstrap plugins/_bundled/g7-power_cache/tests/bootstrap.php \
  plugins/_bundled/g7-power_cache/tests
```

현재 독립 테스트는 **33 tests / 352 assertions**이며 guest 격리, 게시판 read 권한·페이지 범위·PC/모바일 변형, 변경 훅 커버리지, 응답 저장 금지, 변조·구형 저장물 거부, 운영설정 비노출, 관리자 레이아웃 규칙, 세대 단조성, 페이지/카테고리 정상 HIT의 플러그인 DB query 0, MISS→HIT, 변경 후 MISS, commit/rollback, 저장소 장애 뒤 outbox 재생을 검증합니다.

실서버 ON/OFF 결과는 [온라인 ON/OFF 실측 보고서](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/g7-power-cache-live-ab-report-2026-08-23.md)에 기록합니다.
