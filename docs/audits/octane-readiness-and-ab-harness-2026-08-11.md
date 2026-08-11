# Laravel Octane 실서버 공개 A/B 검증 보고

## 결론

그누보드7은 **RoadRunner 기반 Laravel Octane을 선택 기능으로 지원할 수 있지만, 아직 PHP-FPM을 기본값으로 대체하면 안 됩니다.** 자유게시판 50,002건 상태에서 `g7devops.com`의 공개 HTTPS 경로를 실제 전환해 5 VU로 다시 비교한 결과, 다섯 경로 모두 평균 응답시간은 24.7~49.7% 감소하고 처리량은 32.5~98.9% 증가했습니다.

다만 게시판 첫 페이지 API의 p95는 평균 응답과 처리량 개선에도 12.2% 악화됐습니다. 또한 복구 과정에서 Nginx를 PHP-FPM으로 먼저 전환한 뒤 Composer가 `vendor`를 원복하는 짧은 구간에 공개 요청 1건이 실패했습니다. Octane 성능과 별개로, 무중단 복구 순서를 고치기 전에는 기본 전환할 수 없습니다.

시험이 끝난 뒤 PHP-FPM으로 복구했으며 Nginx·Composer·임시 소스 체크섬, 공개 응답, 서비스, 실행 프로세스와 포트를 확인했습니다. 운영 서버에 Octane은 남아 있지 않습니다. 판정은 `선택 설치 가능`, `기본 전환 보류`입니다.

Laravel Octane은 Laravel을 요청마다 다시 부팅하지 않고 메모리에 올린 애플리케이션 worker가 여러 요청을 처리하는 방식입니다. 부팅 비용이 줄어드는 대신 요청별 상태 누수, 메모리 증가, 배포 후 worker 재적용을 관리해야 합니다. [Laravel Octane 공식 문서](https://laravel.com/docs/12.x/octane), [RoadRunner 운영 지침](https://docs.roadrunner.dev/docs/app-server/production)

## 공개 실서버 5 VU 비교

- 측정 시각: 2026-08-11 14:55~15:04 KST
- 서버: `g7devops.com`, Linux, PHP 8.5.8, Laravel 12.62.0
- 비교: 동일 서버·도메인·TLS·Nginx·DB에서 현재 PHP-FPM과 RoadRunner Octane
- 데이터: 자유게시판 50,002건, 댓글 62,840건
- 현재 PHP-FPM: 최대 6 worker
- Octane: 2 worker, `max-requests=500`
- 부하: 각 경로 5 VU, 15초. 모든 부하 응답의 상태 200·본문 존재와 전후 API `success=true` 검사

| 경로 | 평균 응답 PHP-FPM → Octane | 평균 개선 | p95 PHP-FPM → Octane | p95 개선 | 처리량 PHP-FPM → Octane | 처리량 증가 |
|---|---:|---:|---:|---:|---:|---:|
| 메인 `/` | 193.46 → 114.13ms | **41.0%** | 237.56 → 157.10ms | **33.9%** | 25.64 → 43.44 req/s | **69.4%** |
| 게시판 화면 `/board/freebd` | 222.65 → 112.05ms | **49.7%** | 399.23 → 137.52ms | **65.6%** | 22.31 → 44.25 req/s | **98.4%** |
| 게시판 API 첫 페이지 | 221.99 → 164.57ms | **25.9%** | 269.99 → 303.04ms | **-12.2%** | 22.41 → 30.11 req/s | **34.4%** |
| 쇼핑몰 화면 `/shop/products` | 201.89 → 101.55ms | **49.7%** | 322.08 → 121.75ms | **62.2%** | 24.58 → 48.89 req/s | **98.9%** |
| 상품 API 첫 페이지 | 374.33 → 282.02ms | **24.7%** | 472.22 → 333.08ms | **29.5%** | 13.26 → 17.57 req/s | **32.5%** |

`평균 개선`과 `p95 개선`은 `(PHP-FPM - Octane) / PHP-FPM`, `처리량 증가`는 `(Octane / PHP-FPM) - 1`로 계산했습니다. 따라서 게시판 API p95의 `-12.2%`는 개선이 아니라 12.2% 악화입니다. 다섯 경로의 단순 평균은 평균 응답시간 38.2% 감소, p95 35.8% 감소, 처리량 66.7% 증가입니다. 서로 다른 경로의 단순 평균이므로 실제 트래픽 비중을 반영한 종합 점수는 아닙니다.

양쪽 모두 응답 실패 0건, check 성공률 100%였습니다. 메인 화면은 SEO cache가 적용된 실제 운영 상태를 그대로 비교했습니다. 이전 10만 건 이상 데이터 상태에서 얻은 결과는 이번 50,002건 재시험으로 대체하며 현재 판단 근거로 사용하지 않습니다.

현재 PHP-FPM은 최대 6개 요청을 병렬 처리하지만 Octane은 서버 메모리를 고려해 2 worker로 제한했습니다. 따라서 이 결과는 동일 worker 수의 엔진 비교가 아니라 **현재 운영 구성과 이 서버에서 안전하게 적용 가능한 Octane 구성의 실제 비교**입니다. Octane 기능 검증 시 2 worker를 포함한 프로세스 RSS는 약 316MB였고, 부하 종료 시 DB 연결은 8/20이었습니다.

### 공개 복구 중 확인된 문제

부하 측정 구간의 신규 PHP·Nginx 오류는 0건이었습니다. 그러나 공개 경로를 PHP-FPM으로 먼저 되돌린 뒤 Composer가 `vendor`를 원복하는 동안 의존성 파일이 순간적으로 사라져 공개 메인 요청 1건이 실패했습니다. 최종 복구 후 모든 경로는 다시 200이고 체크섬도 일치하지만, 공개 A/B 하네스는 `Composer 원복 완료 → PHP-FPM smoke → Nginx 전환` 순서 또는 명시적 maintenance/Blue-Green 방식으로 고쳐야 합니다.

## 기능·reload·복구 결과

| 검증 | 결과 |
|---|---|
| 공개 `/` | 200 |
| 공개 `/admin` | 200 |
| 공개 게시판 목록 API | 200 |
| 미인증 관리자 API | 401 |
| Octane 공개 경로 증명 | 모든 시나리오에서 `X-G7-Runtime: octane-public-test` 확인 |
| 플러그인 변경 hook | 정상 실행 |
| worker 재적용 | PID `23771, 23800 → 25177, 25178` |
| 재적용 후 공개 요청 | 200 |
| 부하 측정 중 신규 PHP·Nginx 오류 | 0 |
| Composer 원복 구간 공개 오류 | 1건 — 복구 순서 개선 필요 |
| PHP-FPM 복구 후 공개 요청 | 200 |
| Nginx 원본 체크섬 | 일치 |
| 운영 Composer 체크섬 | 일치 |
| 임시 적용 소스 체크섬 | 원본과 일치 |
| 시험 포트·Octane 프로세스 | 잔여 없음 |

복구 후 Nginx, MySQL, PHP-FPM, Redis, Queue, Reverb는 `active`, Scheduler는 예약 작업 실행 중 정상 `activating` 상태임을 확인했습니다.

## 작성한 A/B 하네스

[`scripts/benchmark/octane-ab-harness.sh`](../../scripts/benchmark/octane-ab-harness.sh)는 다음을 자동화합니다.

1. 실행 도구, DB, 포트와 애플리케이션 부팅 상태를 사전 확인합니다.
2. Composer, Octane 설정, RoadRunner 파일과 Laravel 캐시를 체크섬과 함께 보관합니다.
3. 동일 기능·부하로 PHP 기본 실행 방식과 Octane을 비교합니다.
4. 상태 코드, 콘텐츠 유형, 본문, p95·p99·처리량·메모리·신규 오류를 검사합니다.
5. 확장 변경 hook이 실제 Octane worker를 교체하고 다시 응답하는지 검사합니다.
6. 성공·실패·중단과 관계없이 원래 상태로 복구합니다. 중단된 실행은 `restore`로 다시 복구할 수 있습니다.

```bash
# 사전 점검
scripts/benchmark/octane-ab-harness.sh doctor

# 짧은 A/B와 확장 변경 후 worker 재적용 검증
scripts/benchmark/octane-ab-harness.sh run \
  --workers 1 --vus 1 --duration 15s \
  --performance-path /api/modules/sirsoft-board/boards \
  --reload-probe

# 중단된 실행 복구
scripts/benchmark/octane-ab-harness.sh restore --run-dir <결과_디렉터리>
```

하네스 작성과 실서버 실행 과정에서 확장 autoload 재생성 누락, PHP 8.5 정적 trait 경고, 잘못된 RoadRunner worker PID 탐지 문제를 발견해 보완했습니다. 완료 요청이 0개인 부하 시험이 성공으로 보이지 않도록 `http_reqs > 0`과 요청 실패율 0 조건도 추가했습니다.

## 그누보드7에 반영한 호환 처리

- Octane 요청 시작 시 요청별 hook 실행 상태와 게스트 권한 캐시를 초기화합니다.
- 게시판 응답의 게스트 권한 조회값을 요청을 넘는 정적 상태에 남기지 않습니다.
- 쇼핑몰 통화 설정처럼 의도적으로 재사용하는 값은 설정 변경 hook이 worker 재적용을 요청해 갱신합니다.
- 모듈·플러그인·템플릿·언어팩 설치·업데이트·활성화·비활성화·삭제 후 worker 재적용을 예약합니다.
- 코어·모듈·플러그인 설정 변경도 같은 재적용 흐름을 사용합니다.
- 현재 요청이나 설치 명령을 끊지 않도록 작업 종료 시 한 번만 재적용합니다.
- Octane이 설치되지 않았거나 실행 중이 아니면 기존 PHP-FPM에 아무 작업도 하지 않습니다.

## 운영 배포 구성

RoadRunner는 PHP 확장 없이 실행할 수 있어 기본 후보로 적합합니다.

```bash
composer require laravel/octane spiral/roadrunner-cli spiral/roadrunner-http
php artisan octane:install --server=roadrunner
php artisan extension:update-autoload
./vendor/bin/rr get-binary
```

운영 구성은 다음 원칙을 따라야 합니다.

- Octane은 `127.0.0.1`에만 열고 Nginx가 HTTPS와 프록시 헤더를 담당합니다.
- systemd에서 전용 사용자, `Restart=always`, 메모리·작업 수 제한과 health check를 설정합니다.
- worker 수는 CPU 수가 아니라 실측 메모리를 기준으로 시작합니다. 2GB 서버는 1 worker부터 검증해야 합니다.
- Queue, Scheduler, Reverb는 Octane과 별도 서비스로 유지합니다.
- 코어 배포는 `코드 반영 → 마이그레이션 → 캐시·확장 autoload 생성 → octane:reload → 공개 smoke` 순서로 처리합니다.
- 확장 일괄 업데이트는 병렬 실행하지 않습니다. 이번 작업 전 발생한 서버 장애는 Octane이 아니라 병렬 확장 업데이트가 MySQL `max_connections=20`을 초과한 것이 원인이었습니다.

## 공식 기본 지원 전 남은 검증

- 로그인 사용자 간 세션·권한·언어·통화 상태 누수 0건
- 게시글 쓰기·첨부, 상품·장바구니·주문·결제 통보, 에디터 업로드
- 확장 설치·업데이트 도중 동시 요청과 다중 worker 전체 교체
- 게시판 첫 페이지 API의 p95 꼬리 지연 안정화
- Composer 원복이 끝난 뒤 공개 경로를 전환하는 무중단 복구 절차
- 최소 30분 이상의 메모리 증가·worker recycle·DB 재연결 관찰
- 대용량 업로드, 외부 API 지연, 스트리밍과 시간 제한
- systemd 자동 복구와 실제 이전 버전 rollback

따라서 권장 결정은 **Octane을 선택 설치 기능으로 제공하고, 위 통합 시험을 CI와 운영 하네스에 추가한 뒤 기본 지원 여부를 결정하는 것**입니다.
