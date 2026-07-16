# 그누보드7 통합 성능 ON/OFF 하네스

## 목적

공통 부팅 경로, 게시판, 쇼핑몰의 코드·런타임 분기·DB 인덱스·활성 모듈·활성 템플릿을 한 명령으로 전환합니다.

기존 개별 하네스는 다음 문제가 있었습니다.

- 게시판과 쇼핑몰이 같은 `config/benchmark.php`를 각각 배포하거나 삭제했습니다.
- 서로 다른 lock을 사용해 두 전환이 동시에 실행될 수 있었습니다.
- 게시판 하네스가 공통 부팅 경로까지 함께 바꿔 독립 A/B가 불가능했습니다.
- 전체 전환에서 Laravel 캐시 재생성과 PHP-FPM reload가 영역마다 반복됐습니다.
- 코드·실행 분기·인덱스 중 일부만 전환된 혼합 상태를 성공으로 오인할 수 있었습니다.

통합 실행 파일은 `scripts/benchmark/g7-performance-toggle.sh`입니다.

## 바로 사용하는 명령

```bash
# 공통 + 게시판 + 쇼핑몰 튜닝 적용
scripts/benchmark/g7-performance-toggle.sh on

# 전체 빠른 원본 로직 비교
scripts/benchmark/g7-performance-toggle.sh off

# 실제 상태 확인. mixed/drift이면 종료 코드 2
scripts/benchmark/g7-performance-toggle.sh status --strict

# 공식 7.0.4 코드와 원본 스키마로 전체 복구
scripts/benchmark/g7-performance-toggle.sh restore-original --scope all --yes
```

영역별 전환도 지원합니다.

```bash
scripts/benchmark/g7-performance-toggle.sh on --scope common
scripts/benchmark/g7-performance-toggle.sh off --scope board
scripts/benchmark/g7-performance-toggle.sh on --scope ecommerce
scripts/benchmark/g7-performance-toggle.sh status --scope ecommerce --strict
```

`--scope` 값은 `all`, `common`, `board`, `ecommerce`입니다. 기본값은 `all`입니다.

운영 A/B 하네스는 인덱스 visible/invisible 전환 때문에 MySQL 8.0+를 요구합니다. MariaDB 설치에서는 애플리케이션 최적화 코드는 사용할 수 있지만 이 전환 명령은 사용하지 않습니다.

변경 명령은 통합 하네스만 수행합니다. `board-performance-toggle.sh`와 `ecommerce-performance-toggle.sh`의 `on/off/restore-original`은 내부 orchestration token 없이는 거부되며, 개별 스크립트는 `status` 진단에만 직접 사용합니다.

## 세 개의 독립 축

| scope | 런타임 키 | 소스·스키마 범위 |
|---|---|---|
| `common` | `G7_COMMON_PERFORMANCE_VARIANT` | 훅 등록, 권한, 활성 모듈, 언어팩 공통 경로 |
| `board` | `G7_BOARD_PERFORMANCE_VARIANT` | 게시판 목록·검색 서비스, 복합 인덱스, 작성자 검색 사전 |
| `ecommerce` | `G7_ECOMMERCE_PERFORMANCE_VARIANT` | 상품 조회·직렬화·storefront·쇼핑 템플릿과 상품 복합 인덱스 |

공통 배포 대상은 다음 네 파일입니다.

- `app/Extension/HookListenerRegistrar.php`
- `app/Http/Middleware/PermissionMiddleware.php`
- `app/Providers/ModuleRouteServiceProvider.php`
- `app/Services/LanguagePack/LanguagePackRegistry.php`

`config/benchmark.php`는 세 영역이 공유합니다. 부분 `restore-original`에서는 삭제하지 않고 해당 영역의 공식 소스와 환경값만 복구합니다. `--scope all` 정확 복구가 모두 끝난 뒤에만 통합 하네스가 공유 설정 파일을 한 번 삭제합니다.

## 상태 판정

`status`는 저장된 표식만 믿지 않고 원격 서버의 현재 상태를 다시 읽습니다.

```text
common.source=optimized-capable
common.source_integrity=verified
common.runtime=optimized
common.shared_config=present
common.state=optimized
board.source=optimized-capable
board.runtime=optimized
board.schema=optimized
board.active_module_sync=verified
board.module_version_sync=verified
board.active_benchmark_sync=verified
board.benchmark_module_version_sync=verified
board.state=optimized
ecommerce.source=optimized-capable
ecommerce.runtime=optimized
ecommerce.schema=optimized
ecommerce.active_module_sync=verified
ecommerce.active_template_sync=verified
ecommerce.module_version_sync=verified
ecommerce.state=optimized
overall=optimized
```

영역별 최종 상태는 다음과 같습니다.

- `optimized`: 소스·체크섬·실행 분기·인덱스·활성 복제본이 모두 ON
- `baseline`: 원본 실행 분기이며 인덱스는 invisible 또는 제거됨
- `mixed`: 실행 분기와 스키마 또는 영역별 상태가 서로 다름
- `drift`: 배포 체크섬, 공유 설정, 활성 모듈·템플릿, 게시판이 소비하는 벤치마크 동기화 경로, DB 모듈 버전, PHP-FPM 상태가 검증되지 않음

인덱스 상태는 이름만 보지 않습니다. 컬럼 수·순서·ASC 방향·non-unique·BTREE·prefix 미사용·visibility를 모두 검증하며, 같은 이름의 잘못된 인덱스는 `mixed`로 판정하고 `on`에서 정확한 정의로 재생성합니다.

`status --strict`는 `mixed` 또는 `drift`에서 종료 코드 `2`를 반환합니다. 자동 벤치마크는 측정 전에 이 명령을 필수 gate로 사용합니다.

## ON, OFF, 정확 복구의 차이

| 명령 | 소스 | 런타임 | 벤치마크 인덱스 | 목적 |
|---|---|---|---|---|
| `on` | 검토된 optimized ref | optimized | visible·없으면 생성 | 개선 적용 및 측정 |
| `off` | 공통·게시판은 검토 ref, 쇼핑몰은 공식 ref | baseline | invisible | 빠른 읽기 비교 |
| `restore-original` | 공식 `7.0.4` | baseline | 실제 삭제 | 코드·DB 정확 복구 |

`off`의 invisible 인덱스도 쓰기 비용과 디스크는 유지합니다. 쓰기 비용까지 공식 원본과 비교하려면 `restore-original --yes`가 필요합니다.

`restore-original`은 고정된 7.0.4 격리 벤치마크 전용입니다. 이후 기능이 추가된 운영 모듈의 튜닝 해제는 현재 소스 계약을 유지하는 `off`를 사용합니다.

쇼핑몰은 storefront 라우트와 템플릿처럼 환경값만으로 끌 수 없는 변경이 포함돼 `off`에서 공식 소스를 배포합니다. 공통·게시판은 같은 optimized-capable 소스 안에서 baseline 실행 분기를 선택합니다.

## 미커밋 파일 배포 차단

optimized 아카이브는 작업 디렉터리 파일을 직접 복사하지 않습니다. 기본적으로 Git `HEAD`의 committed blob만 가져옵니다.

```bash
scripts/benchmark/g7-performance-toggle.sh on --optimized-ref HEAD
scripts/benchmark/g7-performance-toggle.sh on --optimized-ref <reviewed-commit>
```

따라서 사용자 미커밋 파일이나 다른 작업 중인 변경이 성능 배포에 섞이지 않습니다. 적용할 튜닝은 먼저 검토·커밋한 뒤 해당 commit을 `--optimized-ref`로 지정해야 합니다.

## 전환 안전장치

1. 통합 하네스가 `/var/lock/g7-performance-toggle.lock.d`를 전체 전환 동안 소유하고, 하위 하네스는 같은 token 없이는 변경을 거부합니다.
2. 실행 중인 benchmark 생성·초기화 작업이 있으면 소스 변경 전에 중단합니다. 전환은 maintenance OFF·PHP-FPM active인 정상 서비스에서만 시작합니다.
3. 실제 적용할 공통·게시판·쇼핑몰 아카이브를 한 번만 만들고 원격 업로드·checksum 검증까지 마친 뒤 maintenance에 들어갑니다. 검증본과 적용본은 같은 파일입니다.
4. 앱 unit에는 전환 중 재시작 금지와 하네스 drain timeout을 임시 적용합니다. queue·Horizon·Reverb·scheduler·Octane 종료 신호를 먼저 보낸 뒤 unit·`cron.service`·PHP-FPM을 non-blocking stop하고 함께 drain합니다.
5. PHP-FPM은 reload가 아니라 완전히 중지합니다. 기본 930초 동안 모든 앱 Artisan 프로세스와 unit 종료, FPM inactive를 확인한 뒤에만 소스·DB 변경을 시작합니다. `--drain-timeout`으로 30~3600초 범위에서 조정할 수 있습니다.
6. 게시판·쇼핑몰 DDL 직전에 같은 DB 서버의 5초 이상 Query/Execute 또는 열린 InnoDB 트랜잭션이 있으면 중단하고, metadata·InnoDB lock 대기는 15초로 제한합니다.
7. 소스·환경값·스키마 적용 후 production 캐시를 재생성하고 PHP-FPM만 시작합니다. maintenance 상태에서 `status --strict`가 통과해야 중지했던 unit과 cron을 다시 시작합니다.
8. maintenance 해제 뒤 선택 영역 HTTP smoke와 마지막 `status --strict`가 모두 통과해야 완료 처리하고 runtime snapshot을 삭제합니다. 중간 실패 시 unit·cron을 다시 중지하고 maintenance로 되돌립니다.
9. 소스·DB 변경 전 실패는 기록한 기존 maintenance/FPM/unit 상태만 복구합니다. drain 자체가 끝나지 않았거나 소스 변경 뒤 실패하면 availability를 임의로 열지 않고 fail-closed로 남깁니다.
10. 정확 복구는 `--yes` 없이는 실행되지 않습니다.

비정상 종료로 lock 디렉터리가 남았다면 실행 중인 전환이 없는지 먼저 확인한 뒤에만 서버 관리자가 제거해야 합니다. lock을 임의로 삭제하면서 다른 전환을 실행하면 안 됩니다.

소스 변경 뒤 실패해 maintenance와 runtime snapshot이 남은 경우 일반 전환은 이를 지우지 않고 거부합니다. 원인을 수정한 뒤 전체 영역을 다음 명령으로 재개합니다.

```bash
scripts/benchmark/g7-performance-toggle.sh on --scope all \
  --recover-fail-closed --optimized-ref <reviewed-commit>
```

이 옵션은 기존 snapshot이 있고 maintenance가 유지된 경우에만 동작하며, 동일 소스·스키마를 다시 적용한 뒤 FPM·기존 worker·cron·HTTP smoke와 최종 optimized 상태를 재검증합니다.

## 전환 후 smoke

선택 영역에 맞춰 다음 요청을 확인합니다.

- 공통: `/`
- 게시판: `/api/modules/sirsoft-board/boards/freebd/posts?page=1&per_page=20`
- 쇼핑몰: `/api/modules/sirsoft-ecommerce/products?page=1&per_page=12`

각 요청은 HTTP 200이어야 합니다. 게시판은 `--board-slug`로 바꿀 수 있습니다. `--no-smoke`로 생략할 수 있지만 실제 배포 전환에서는 권장하지 않습니다.

깊은 OFFSET 페이지와 게시판 검색은 운영 서버를 장시간 점유할 수 있으므로 전환 smoke에는 넣지 않습니다. 별도 부하 하네스에서 쿼리 시간 제한을 적용한 뒤 측정합니다.

## 튜닝 전·후 A/B + CPU 비교

튜닝 커밋을 고정한 뒤 아래 한 명령으로 OFF와 ON을 같은 데이터·경로·부하로 비교합니다.

```bash
scripts/benchmark/g7-ab-benchmark.sh --optimized-ref <reviewed-commit>
```

기본 실행은 상태별 3회 반복하며 홈, 홈 데이터 API, 게시판 목록·내용·페이징·검색, 통합검색, 쇼핑 홈·목록·내용·검색의 24개 공통 경로를 측정합니다. 구버전에도 없는 통합 storefront API는 비교하지 않고, 실제 쇼핑 홈을 구성하는 분류·상품·최근·인기·신상품 API를 각각 측정합니다.

일반 경로는 30초 동안 초당 1개 route matrix를 고정 도착률로 예약하고 최대 10 VU는 이 일정을 유지하는 용도로만 사용합니다. 게시판 공용 600회/분 제한을 넘지 않도록 계산하며, dropped iteration이 있으면 해당 run을 무효 처리합니다. 깊은 페이지·게시판 검색·통합검색은 1 VU 단건입니다. 위험 경로 실행 중에는 신규 MySQL SELECT에 15초 제한을 임시 적용하고 매 실행 뒤 SELECT·InnoDB transaction이 0이 될 때까지 기다립니다. 임의 쿼리 kill은 하지 않습니다.

동시에 양쪽 모두 같은 105초 고정 창에서 `/proc`을 표본 수집해 호스트 busy와 전체 호스트 용량 대비 PHP-FPM·MySQL CPU 평균·최대를 기록합니다. Xdebug가 CLI 또는 FPM에 로드돼 있으면 절대시간 왜곡을 막기 위해 실행을 거부합니다. 결과는 `comparison.md`, `comparison.json`, 경로·CPU CSV와 원시 k6/CPU 파일로 저장합니다.

각 API는 페이지 번호·상세 대상 ID·검색 결과 등 응답 계약까지 확인합니다. 오류·404·잘못된 응답 시간과 dropped iteration은 개선 수치에서 제외하고 invalid로 표시하며 명령은 실패로 끝납니다. OFF·ON 어느 한쪽이라도 지정한 반복 횟수의 run 파일 자체를 만들지 못하면 비교 보고서는 만들지 않고 원시 로그만 보존합니다.

A/B 전체 수명 동안 일반 전환과 같은 원격 lock을 보유하므로 다른 ON/OFF 명령과 교차하지 않습니다. 정상·실패 종료 모두 마지막에 `on --scope all`, `status --strict`, 공개 HTTP 상태를 확인합니다. fail-closed snapshot이 있으면 복구 모드로 재개하며, MySQL 제한 때문에 실패했을 가능성에 대비해 제한 원복 뒤 한 번 더 검증합니다. OFF를 시도하기 전 연결 점검이 실패했다면 서버 상태를 변경하지 않습니다.

## 런타임 재생성

선택 영역을 모두 바꾸는 동안 FPM과 앱 worker는 정지 상태를 유지합니다. 모든 소스·DB 변경이 끝난 뒤 production 캐시를 한 번 재생성하고 새 FPM 세대로 strict 검증합니다. 개별 하네스의 `--defer-runtime`, `--lock-token`은 통합 하네스 내부 옵션이며 운영자는 직접 지정하지 않습니다.

## 환경 오버라이드

```bash
G7_PERF_HOST=g7devops \
G7_PERF_ROOT=/home/g7devops/public_html \
G7_PERF_DB_NAME=g7devops \
G7_PERF_DB_PREFIX=g7_ \
G7_PERF_OPTIMIZED_REF=HEAD \
G7_PERF_BOARD_SLUG=freebd \
scripts/benchmark/g7-performance-toggle.sh status --strict
```

동일 값은 `--host`, `--root`, `--app-user`, `--php-bin`, `--db`, `--db-prefix`, `--baseline`, `--optimized-ref`, `--base-url`, `--board-slug`, `--drain-timeout` 옵션으로 지정할 수 있습니다.

## 로컬 검증

```bash
bash -n scripts/benchmark/g7-performance-toggle.sh
shellcheck scripts/benchmark/g7-performance-toggle.sh \
  scripts/benchmark/board-performance-toggle.sh \
  scripts/benchmark/ecommerce-performance-toggle.sh
scripts/benchmark/tests/g7-performance-toggle-test.sh
scripts/benchmark/tests/g7-ab-benchmark-test.sh
```

셸 테스트는 정상 ON 상태, mixed·checksum drift strict 실패, scope 전달, exact archive 재사용, drain·fail-closed 순서, direct 변경 거부, 실제 optimized/baseline 아카이브 내용을 검증합니다.
