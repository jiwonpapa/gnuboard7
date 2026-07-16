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
- `drift`: 배포 체크섬, 공유 설정, 활성 모듈·템플릿, DB 모듈 버전, PHP-FPM 상태가 검증되지 않음

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

1. 통합 하네스가 `/var/lock/g7-performance-toggle.lock.d`를 전체 전환 동안 소유합니다.
2. 기존 게시판·쇼핑몰 하네스도 같은 전역 lock을 사용합니다.
3. 하위 하네스는 통합 token을 검증하므로 다른 전환이 중간에 끼어들 수 없습니다.
4. 게시판·쇼핑몰 DDL 전에 5초 이상 실행 중인 DB 작업 또는 열린 트랜잭션이 있으면 중단하고, metadata lock 대기는 15초로 제한합니다.
5. `restore-original`은 먼저 선택 영역을 baseline으로 캐시해 optimized 코드가 신규 인덱스를 사용하는 상태에서 인덱스를 삭제하지 않습니다.
6. 모든 영역 변경 후 production 캐시를 한 번 재생성하고 queue·Reverb에 graceful restart 신호를 보낸 뒤 PHP-FPM을 한 번 reload합니다.
7. 중간 실패 시 현재 결과가 혼합 상태일 수 있으므로 캐시를 긴급 재생성하고 명령을 실패 처리합니다. 이후 `status --strict`로 상태를 확인합니다.
8. 정확 복구는 `--yes` 없이는 실행되지 않습니다.

비정상 종료로 lock 디렉터리가 남았다면 실행 중인 전환이 없는지 먼저 확인한 뒤에만 서버 관리자가 제거해야 합니다. lock을 임의로 삭제하면서 다른 전환을 실행하면 안 됩니다.

## 전환 후 smoke

선택 영역에 맞춰 다음 요청을 확인합니다.

- 공통: `/`
- 게시판: `/api/modules/sirsoft-board/boards/gallery/posts?page=1&per_page=20`
- 쇼핑몰: `/api/modules/sirsoft-ecommerce/products?page=1&per_page=12`

각 요청은 HTTP 200이어야 합니다. `--no-smoke`로 생략할 수 있지만 실제 배포 전환에서는 권장하지 않습니다.

깊은 OFFSET 페이지와 게시판 검색은 운영 서버를 장시간 점유할 수 있으므로 전환 smoke에는 넣지 않습니다. 별도 부하 하네스에서 쿼리 시간 제한을 적용한 뒤 측정합니다.

## 캐시 재생성 횟수

- `on`, `off`: 모든 선택 영역을 바꾼 뒤 1회
- `restore-original`: DDL 전 baseline 안전 전환 1회 + 복구 완료 후 1회
- 영역별 기존 하네스를 직접 실행: 해당 영역 단독으로 1회

개별 하네스의 `--defer-runtime`, `--lock-token`은 통합 하네스 내부 옵션입니다. 운영자는 직접 지정하지 않습니다.

## 환경 오버라이드

```bash
G7_PERF_HOST=g7devops \
G7_PERF_ROOT=/home/g7devops/public_html \
G7_PERF_DB_NAME=g7devops \
G7_PERF_DB_PREFIX=g7_ \
G7_PERF_OPTIMIZED_REF=HEAD \
scripts/benchmark/g7-performance-toggle.sh status --strict
```

동일 값은 `--host`, `--root`, `--app-user`, `--php-bin`, `--db`, `--db-prefix`, `--baseline`, `--optimized-ref`, `--base-url` 옵션으로 지정할 수 있습니다.

## 로컬 검증

```bash
bash -n scripts/benchmark/g7-performance-toggle.sh
shellcheck scripts/benchmark/g7-performance-toggle.sh \
  scripts/benchmark/board-performance-toggle.sh \
  scripts/benchmark/ecommerce-performance-toggle.sh
scripts/benchmark/tests/g7-performance-toggle-test.sh
```

셸 테스트는 정상 ON 상태, mixed strict 실패, checksum drift strict 실패, scope 전달, 정확 복구 확인 옵션을 검증합니다.
