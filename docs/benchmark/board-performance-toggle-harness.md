# 게시판 성능 개선 ON/OFF 하네스

## 목적

동일 스테이징 서버와 동일 데이터에서 그누보드7 7.0.4 원본 목록 경로와 성능 개선 경로를 반복 전환한다.

변경 실행 파일:

`scripts/benchmark/g7-performance-toggle.sh`

개별 `board-performance-toggle.sh`는 통합 하네스 내부 실행과 직접 `status` 진단만 허용한다.

## 기본 명령

### 개선 적용

```bash
scripts/benchmark/g7-performance-toggle.sh on --scope board
```

다음을 한 번에 수행한다.

- 검토·커밋된 optimized Git ref(기본 `HEAD`) 소스 스냅샷 업로드
- 번들·활성 `sirsoft-board`와 설치된 `sirsoft-benchmark` 작성자 사전 동기화 경로 배포
- `G7_BOARD_PERFORMANCE_VARIANT=optimized`
- 신규 인덱스가 없으면 생성, invisible이면 visible 전환
- 작성자 검색 사전이 없으면 생성하고 누락된 고유 작성자 보강
- optimized ref의 게시판·설치된 벤치마크 module 버전을 DB에 반영
- Laravel production 캐시 재생성, queue·Reverb graceful restart, PHP-FPM reload
- 게시판 첫 페이지 HTTP smoke
- 최종 상태 출력

### 빠른 원본 비교

```bash
scripts/benchmark/g7-performance-toggle.sh off --scope board
```

소스는 optimized-capable 상태로 유지하지만 실행 분기를 공식 7.0.4 원본 로직으로 바꾼다.

- 넓은 컬럼을 직접 OFFSET하는 원본 페이지네이션
- FULLTEXT·작성자·회원 조건을 하나의 OR로 평가하는 원본 통합검색
- 공지·답글 상한 없는 원본 로직
- 답글이 없어도 답글 확인 SQL을 실행하는 원본 로직
- 필터 COUNT 단기 캐시 미사용
- 목록 인덱스 두 개는 `INVISIBLE`; 작은 작성자 검색 사전은 보존하되 baseline 코드에서는 사용하지 않음

이 모드는 빠른 읽기 성능 A/B 비교용이다. invisible index도 INSERT/UPDATE 시 유지되므로 **쓰기 비용과 디스크까지 원본과 같지는 않다**.

### 현재 상태

```bash
scripts/benchmark/g7-performance-toggle.sh status --scope board --strict
```

출력 항목:

- `source`: optimized 전환 가능 소스인지 공식 7.0.4 소스인지
- `source_integrity`: 마지막 스냅샷 체크섬 일치 여부
- `runtime`: 실제 선택된 `optimized` 또는 `baseline`
- `schema`: 신규 인덱스 visible, invisible, 제거 상태
- 신규 인덱스별 visibility
- 신규 인덱스별 정확한 컬럼 순서·ASC·BTREE·non-unique·prefix 미사용 검증
- 작성자 검색 사전의 컬럼·복합 PK·collation·누락 작성자 검증 결과
- 번들 모듈과 활성 모듈 소스 일치 여부
- `sirsoft-board` DB 버전과 활성 상태
- 설치된 `sirsoft-benchmark`의 벌크 작성자 사전 동기화 코드·DB 버전 일치 여부
- PHP-FPM 상태
- 마지막 변경 시각과 하네스 상태

### 정확한 원본 복구

```bash
scripts/benchmark/g7-performance-toggle.sh restore-original --scope board --yes
```

다음을 수행한다.

- 공식 Git tag `7.0.4`에서 성능 패치 대상 파일 복원
- 공유 `config/benchmark.php`는 보존하고 게시판 환경값만 제거
- 신규 migration 파일 제거
- 신규 인덱스 두 개와 작성자 검색 사전 테이블 실제 삭제
- migration 기록 삭제
- module DB 버전 1.0.2 복원
- 성능 variant 환경값 제거

복구는 통합 하네스가 maintenance mode에서 앱 worker·cron·PHP-FPM을 모두 정지한 뒤 공식 baseline 소스와 스키마를 적용한다. strict 검증과 smoke가 통과해야 다시 공개한다.

이 상태에서 다시 `on`을 실행하면 optimized 소스와 인덱스를 재생성한다. 180만 행 테이블의 인덱스 재생성은 시간이 걸리고 metadata lock을 유발할 수 있으므로 반복 비교에는 `off`를 사용한다.

`restore-original`은 고정된 7.0.4 격리 벤치마크 환경 전용이다. 이후 모듈 기능과 함께 운영 중인 서버의 튜닝 해제에는 소스 계약을 보존하는 `off`만 사용한다.

별도 설치된 `sirsoft-benchmark` 데이터 생성 모듈은 원본 복구에서 제거하지 않는다. 대신 튜닝 직전 기준 커밋의 0.2.4 소스와 의존성으로 함께 되돌려, 7.0.4 게시판 계약과 맞지 않는 벌크 동기화 코드가 남지 않게 한다. 기준 커밋은 `G7_BOARD_PERF_BENCHMARK_BASELINE_REF` 또는 `--benchmark-baseline-ref`로 명시적으로 교체할 수 있다.

## 상태 표

| 명령 | 실행 코드 | 신규 인덱스 | 소스 | 용도 |
|---|---|---|---|---|
| `on` | optimized | visible | optimized-capable | 개선 성능 측정 |
| `off` | G7 7.0.4 baseline | invisible | optimized-capable | 빠른 읽기 A/B 비교 |
| `restore-original --yes` | G7 7.0.4 baseline | 없음 | 공식 7.0.4 게시판 | 게시판 코드·DB 정확 복구 |

## 안전장치

- 공통·게시판·쇼핑몰 전환이 겹치지 않도록 원격 전역 lock을 사용한다.
- 같은 DB 서버에 5초 이상 실행 중인 Query/Execute나 열린 InnoDB 트랜잭션이 하나라도 있으면 DDL 전에 보수적으로 중단한다. 기본 DB가 없거나 다른 연결에서 정규화된 테이블명을 쓰는 트랜잭션도 놓치지 않는다.
- DDL metadata lock 대기는 15초로 제한해 무기한 멈춤을 방지한다.
- 자동으로 장기 쿼리를 죽이지 않는다.
- 소스 전환 전 백업을 생성하고 최근 10개만 유지한다.
- 번들 모듈과 활성 모듈을 함께 교체한다.
- 원본 복구 아카이브에는 공식 게시판 7.0.4와 튜닝 직전 `sirsoft-benchmark` 스냅샷을 함께 넣어 모듈 간 계약도 원상 복구한다.
- `.env`의 기존 소유권과 권한을 유지한다.
- 인덱스는 이름뿐 아니라 컬럼 수·순서·ASC·BTREE·non-unique·prefix 미사용을 확인하고, 잘못된 동일 이름 인덱스는 `on`에서 재생성한다.
- 통합 전환은 실행 중 benchmark job을 거부하고, 앱 systemd unit·cron·PHP-FPM을 정지한 뒤 기본 930초 drain을 통과해야 소스와 DDL을 변경한다.
- 전환 후 `config`, `route`, `view`, `hooks` 캐시를 재생성하고 maintenance 상태에서 strict 검증한 뒤 worker·cron 재시작과 HTTP smoke를 수행한다.
- exact restore는 `--yes` 없이는 실행되지 않는다.

## 측정 주의

2026-07-15 하네스 초기판은 `optimize:clear` 후 production 캐시를 재생성하지 않았습니다. 초기판으로 `on/off` 전환한 뒤 측정한 A/B는 양쪽 모두 비캐시 조건의 상대 비교로만 참고하고, 운영 절대 성능 수치로 사용하지 않습니다. 현재판부터 전환마다 production 캐시를 재생성합니다.

백업 위치:

`/var/backups/gnuboard7/board-performance-harness/`

## 환경 오버라이드

공개 예시 대상은 `g7-benchmark` SSH alias와 `/var/www/gnuboard7`이다. 실제 host·경로·DB명은 로컬 환경변수로만 주입한다.

인덱스 visible/invisible 전환을 사용하는 운영 하네스는 MySQL 8.0+ 전용이다. MariaDB 지원 설치에서는 애플리케이션 코드는 사용할 수 있지만 이 하네스로 A/B 전환하지 않는다.

```bash
G7_BOARD_PERF_HOST=g7-benchmark \
G7_BOARD_PERF_ROOT=/var/www/gnuboard7 \
G7_BOARD_PERF_DB_NAME=gnuboard7 \
G7_BOARD_PERF_DB_PREFIX=g7_ \
scripts/benchmark/g7-performance-toggle.sh status --scope board --strict
```

명령 옵션으로도 `--host`, `--root`, `--app-user`, `--php-bin`, `--db`, `--db-prefix`, `--baseline`, `--optimized-ref`, `--base-url`을 지정할 수 있다. optimized 소스는 미커밋 작업 파일이 아니라 지정 Git ref에서만 생성한다.

모든 변경은 `g7-performance-toggle.sh`를 사용한다. 공유 설정 파일의 정확한 제거는 통합 `restore-original --scope all --yes`에서만 수행한다.

## 테스트 근거

타깃 테스트는 optimized와 baseline 분기를 같은 테스트 프로세스에서 모두 검증한다.

- optimized: ID-only 선조회, 공지 10건, 답글 SQL 생략, 필터 COUNT 재사용
- optimized 검색: 제목·본문 FULLTEXT, 작성자, 회원 결과를 DB 내부 ID UNION으로 분리
- 작성자 부분검색: 게시판별 고유 작성자 사전만 LIKE로 검사한 뒤 기존 `(board_id, author_name)` 인덱스로 게시글 연결
- 목록·전역검색: `COUNT(*) OVER()`로 total과 현재 페이지를 한 번에 조회해 같은 FULLTEXT 반복 실행 제거
- baseline: 넓은 OFFSET, 단일 OR 검색, 공지 전체, 답글 확인 SQL, 반복 COUNT 쿼리
- 기존 목록 분기 회귀 묶음: 75 tests, 143 assertions 통과(2026-07-15)
- 현재 하네스 mock: PASS, DB 비의존 성능 회귀: 19 tests, 51 assertions 통과
- 신규 window count·작성자 사전·상품 FULLTEXT 통합 테스트는 MySQL 전용이며 로컬 MySQL 미구동 환경에서는 실행하지 않는다.

권한·활성 모듈·언어팩과 훅 등록 로그는 게시판 축에서 분리되어 통합 하네스의 `common` 축으로 전환한다.

스테이징 왕복 검증:

| 단계 | source | runtime | schema | module | 결과 |
|---|---|---|---|---|---|
| `off` | optimized-capable | baseline | 신규 인덱스 invisible | 1.1.1 | 성공 |
| `on` | optimized-capable | optimized | 신규 인덱스 visible | 1.1.1 | 성공 |
| `restore-original --yes` | official-7.0.4 | baseline | 신규 인덱스 없음 | 1.0.2 | 성공 |
| 원본 복구 후 `on` | optimized-capable | optimized | 신규 인덱스 재생성 | 1.1.1 | 성공 |

동일 `freebd` 1,000페이지 요청은 `off`에서 11.594초, `on`에서 0.579초로 측정돼 실제 서버에서도 실행 분기가 바뀌는 것을 확인했다. 최종 서버 상태는 `on`이다.

`board_post_author_terms(board_id, author_name)`는 `(board_id, author_name)` 복합 PK를 가진 단조 증가형 검색 사전이다. ON 전환 시 기존 게시글의 고유 작성자를 `INSERT IGNORE ... SELECT DISTINCT`로 보강한다. 신규·변경 게시글은 Eloquent Observer가, raw bulk 벤치마크 적재는 완료 동기화 단계가 사전을 보강한다. 삭제된 작성자 항목이 남아도 실제 게시글과 equality join하므로 잘못된 결과는 반환하지 않는다.
