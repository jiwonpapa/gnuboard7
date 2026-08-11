# PHP-FPM vs Laravel Octane(RoadRunner·FrankenPHP) 실서버 공개 A/B 검증 보고

## 결론

그누보드7은 **RoadRunner와 FrankenPHP worker mode를 모두 Laravel Octane 선택 기능으로 지원할 수 있지만, 아직 PHP-FPM을 기본값으로 대체하면 안 됩니다.** 자유게시판 50,002건 상태에서 `g7devops.com`의 공개 HTTPS 경로를 실제 전환해 최대 6 worker·5 VU로 비교했습니다. PHP-FPM 대비 RoadRunner는 평균 응답시간 20.2~57.8%, FrankenPHP는 25.6~56.1% 감소했습니다. 처리량은 각각 25.2~137.3%, 34.2~128.0% 증가했고 모든 요청 검사가 통과했습니다.

FrankenPHP는 RoadRunner보다 다섯 경로 중 네 경로에서 평균 응답과 처리량이 좋았지만, 쇼핑몰 화면 p95는 155.71→239.16ms로 RoadRunner보다 나빴습니다. 또한 두 시험은 순차 실행한 15초 단기 측정이고 공유 VPS의 CPU steal이 관측됐으며, FrankenPHP 내장 PHP 8.5.9와 PHP-FPM·RoadRunner의 PHP 8.5.8도 패치 버전이 다릅니다. 따라서 이번 결과로 FrankenPHP를 절대 우위나 운영 기본값으로 확정할 수는 없습니다.

시험이 끝난 뒤 PHP-FPM으로 복구했으며 Nginx·Composer 체크섬, 5개 공개 경로, 서비스, 실행 프로세스와 포트를 확인했습니다. 운영 서버에 Octane·FrankenPHP 프로세스와 시험 포트는 남아 있지 않습니다. 판정은 `두 서버 모두 선택 설치 가능`, `기본 전환 보류`입니다.

Laravel Octane은 Laravel을 요청마다 다시 부팅하지 않고 메모리에 올린 애플리케이션 worker가 여러 요청을 처리하는 방식입니다. 부팅 비용이 줄어드는 대신 요청별 상태 누수, 메모리 증가, 배포 후 worker 재적용을 관리해야 합니다. [Laravel Octane 공식 문서](https://laravel.com/docs/12.x/octane), [FrankenPHP worker mode 공식 문서](https://frankenphp.dev/docs/worker/), [RoadRunner 운영 지침](https://docs.roadrunner.dev/docs/app-server/production)

**Octane은 독립 HTTP 서버가 아니므로 단독 실행·성능 측정이 불가능합니다.** RoadRunner, FrankenPHP, Swoole 같은 실행 서버 중 하나가 반드시 필요합니다. 이 보고서에서 기존에 `Octane`으로 표기한 수치는 정확히는 `Octane + RoadRunner` 결과입니다.

## 동일 조건의 공개 실서버 3방식 비교

### 서버 사양·실행 구성

| 항목 | PHP-FPM 기준 | 초기 보고의 `Octane` | 추가 FrankenPHP 시험 |
|---|---|---|---|
| 정확한 실행 구성 | Nginx → PHP-FPM | **Nginx → Octane → RoadRunner** | **Nginx → Octane → FrankenPHP(Caddy)** |
| 서버 | `g7devops.com` Linux 공유 VPS, 2 vCPU·2GB | 좌측과 동일 | 좌측과 동일 |
| 웹 앞단·TLS | Nginx·기존 HTTPS | 좌측과 동일 | 좌측과 동일 |
| 애플리케이션 | Laravel 12.62.0·동일 운영 소스 | 좌측과 동일 | 좌측과 동일 |
| PHP | 8.5.8 | 8.5.8 | 내장 PHP 8.5.9 |
| 서버 버전 | PHP-FPM 8.5.8 | RoadRunner 임시 실행본 | FrankenPHP 1.12.7·Caddy 2.11.4 |
| 프로세스 | 동적, `pm.max_children=6` | 고정 6 worker | 고정 6 worker |
| worker 재시작 | PHP-FPM 관리 | `max-requests=500` | `max-requests=500` |
| 측정 결과 | 기준선 | 아래 실측 | 아래 실측 |

공통 데이터는 자유게시판 50,002건·댓글 62,853건입니다. 각 경로를 5 VU로 15초간 측정했고, 모든 응답의 HTTP 200·본문 존재·API `success=true`를 검사했습니다. 측정 시각은 PHP-FPM·RoadRunner 2026-08-11 15:27~15:37 KST, FrankenPHP 16:10~16:13 KST입니다.

### 3개 실행 구성 성능 비교

각 수치는 `평균 응답 ms / p95 ms / 처리량 req/s`입니다. 응답시간은 낮을수록, 처리량은 높을수록 좋습니다.

| 경로 | PHP-FPM 기준 | 초기 Octane<br>(Octane + RoadRunner) | PHP-FPM 대비 개선<br>(평균 / p95 / 처리량) | Octane + FrankenPHP | PHP-FPM 대비 개선<br>(평균 / p95 / 처리량) | FrankenPHP vs 초기 Octane |
|---|---:|---:|---:|---:|---:|---|
| 메인 `/` | 199.24 / 248.89 / 24.90 | 99.20 / 124.86 / 50.03 | **50.2% / 49.8% / +100.9%** | **87.85 / 106.16 / 56.55** | **55.9% / 57.3% / +127.1%** | 평균 11.4%·p95 15.0% 빠름, 처리량 13.0% 높음 |
| 게시판 화면 `/board/freebd` | 209.55 / 323.27 / 23.67 | 120.64 / 208.65 / 41.20 | **42.4% / 35.5% / +74.1%** | **92.00 / 138.24 / 53.97** | **56.1% / 57.2% / +128.0%** | 평균 23.7%·p95 33.7% 빠름, 처리량 31.0% 높음 |
| 게시판 API 첫 페이지 | 226.83 / 275.41 / 21.91 | 152.53 / 203.21 / 32.60 | **32.8% / 26.2% / +48.8%** | **132.92 / 166.48 / 37.42** | **41.4% / 39.6% / +70.8%** | 평균 12.9%·p95 18.1% 빠름, 처리량 14.8% 높음 |
| 쇼핑몰 화면 `/shop/products` | 247.40 / 523.24 / 20.06 | **104.35 / 155.71 / 47.61** | **57.8% / 70.2% / +137.3%** | 110.76 / 239.16 / 44.89 | **55.2% / 54.3% / +123.7%** | FrankenPHP가 평균 6.1%·p95 53.6% 느림, 처리량 5.7% 낮음 |
| 상품 API 첫 페이지 | 400.13 / 516.48 / 12.44 | 319.12 / 433.00 / 15.57 | **20.2% / 16.2% / +25.2%** | **297.65 / 431.85 / 16.69** | **25.6% / 16.4% / +34.2%** | 평균 6.7%·p95 0.3% 빠름, 처리량 7.2% 높음 |

| PHP-FPM 대비 5개 경로 단순 평균 | Octane + RoadRunner | Octane + FrankenPHP |
|---|---:|---:|
| 평균 응답시간 감소 | 40.7% | **46.8%** |
| p95 감소 | 39.6% | **45.0%** |
| 처리량 증가 | 77.3% | **96.8%** |

이 단순 평균은 경로별 실제 트래픽 비중을 반영하지 않은 참고치입니다. FrankenPHP는 5개 경로 중 4개에서 평균 응답과 처리량이 우세했지만 쇼핑몰 p95가 크게 악화됐고, 내장 PHP·Caddy·DB socket을 별도로 관리해야 합니다. 따라서 현재 결과만으로 RoadRunner에서 FrankenPHP로 바꿀 근거는 부족합니다.

세 방식 모두 응답 실패 0건, check 성공률 100%였습니다. 메인 화면은 SEO cache가 적용된 실제 운영 상태를 그대로 비교했습니다. 이전 10만 건 이상 데이터 상태에서 얻은 결과는 이번 50,002건 재시험으로 대체하며 현재 판단 근거로 사용하지 않습니다.

이전 시험은 PHP-FPM 최대 6 worker와 Octane 2 worker를 비교해 동시성 조건이 달랐습니다. 이번 결과가 같은 최대 worker 수로 다시 측정한 현재 성능 근거이며, 이전 게시판 API p95 악화 수치는 폐기합니다.

다만 worker 수만 같을 뿐 메모리 사용 방식까지 같지는 않습니다. PHP-FPM은 요청량에 따라 자식 프로세스를 늘리지만 Octane은 6개를 계속 유지합니다. RoadRunner 프로세스 트리 RSS는 약 531MB였습니다. FrankenPHP는 Caddy·PHP 통합 프로세스가 부하 중 약 246~294MB, Artisan 실행 프로세스가 약 103MB로 합계 약 349~397MB였습니다. FrankenPHP 측정 중 `vmstat` 최저 여유 메모리는 약 212MB였고 swap 입출력과 평균 3.4%·최대 69% CPU steal이 관측됐습니다. 이 2GB 공유 VPS에서 6 worker를 운영 기본값으로 확정할 근거는 아닙니다.

RoadRunner 게시판 화면의 p99는 396.27→569.45ms, 상품 API 최대값은 632.74→981.09ms로 악화됐습니다. FrankenPHP도 메인 최대값은 295.34→352.60ms, 쇼핑몰 최대값은 876.25→888.41ms로 소폭 증가했습니다. p95까지는 모든 경로가 PHP-FPM보다 개선됐지만, 짧은 시험의 꼬리 지연이므로 장시간 반복 측정이 필요합니다.

### 공개 복구 중 확인된 문제

첫 2-worker 시험에서는 공개 경로를 PHP-FPM으로 먼저 되돌린 뒤 Composer가 `vendor`를 원복하는 짧은 구간에 공개 요청 1건이 실패했습니다. 이번 6-worker 시험은 라이브 `vendor`를 수정하지 않는 별도 임시 실행본을 사용하고, `PHP-FPM 기동·확인 → Nginx 전환 → 기존 연결 종료 대기 → Octane 종료` 순서로 복구했습니다. 유효한 RoadRunner·FrankenPHP 부하와 복구 구간의 신규 PHP·Nginx 오류는 0건이었습니다.

FrankenPHP 사전 시도에서는 두 운영 차이를 확인했습니다. 내장 PHP의 기본 MySQL socket은 `/tmp/mysql.sock`이어서 서버의 `/var/run/mysqld/mysqld.sock`을 명시해야 했고, Caddy 사이트 주소를 `127.0.0.1` 호스트로 고정하면 Nginx가 전달한 `www.g7devops.com` Host가 매칭되지 않아 빈 `200`이 반환됐습니다. 이 시도는 즉시 중단·복구하고 결과에서 제외했습니다. 최종 시험은 Caddy listener만 loopback에 묶고 모든 Host를 받도록 했으며, 상태 코드와 본문/API 의미를 함께 검사했습니다.

## 기능·reload·복구 결과

| 검증 | 결과 |
|---|---|
| 공개 `/` | 200 |
| 공개 `/admin` | 200 |
| 공개 게시판 목록 API | 200 |
| 미인증 관리자 API | 401 |
| RoadRunner 공개 경로 증명 | 모든 시나리오에서 `X-G7-Runtime: octane-public-test` 확인 |
| FrankenPHP 공개 경로 증명 | 5개 경로에서 `X-G7-Runtime: frankenphp-public-test`와 정상 본문/API 확인 |
| 플러그인 변경 hook | RoadRunner에서 정상 실행 |
| worker 재적용 | RoadRunner PID `23771, 23800 → 25177, 25178` |
| FrankenPHP worker 재적용 | 하네스 지원 추가, 실제 플러그인 설치 중 재적용은 후속 검증 |
| 재적용 후 공개 요청 | 200 |
| RoadRunner·FrankenPHP 유효 부하·복구 중 신규 PHP·Nginx 오류 | 0 |
| 6-worker 임시 실행본 복구 중 공개 오류 | 0 |
| 첫 2-worker 시험의 Composer 원복 구간 공개 오류 | 1건 — 별도 실행본 방식으로 재발 방지 |
| PHP-FPM 복구 후 공개 요청 | 200 |
| Nginx 원본 체크섬 | 일치 |
| 운영 Composer 체크섬 | 일치 |
| 운영 소스·`vendor` | 수정하지 않음 — 별도 임시 실행본 사용 |
| 시험 포트·Octane·FrankenPHP 프로세스 | 잔여 없음 |

복구 후 Nginx, MySQL, PHP-FPM, Redis, Queue, Reverb는 `active`, Scheduler는 예약 작업 실행 중 정상 `activating` 상태임을 확인했습니다.

## 작성한 A/B 하네스

[`scripts/benchmark/octane-ab-harness.sh`](../../scripts/benchmark/octane-ab-harness.sh)는 다음을 자동화합니다.

1. 실행 도구, DB, 포트와 애플리케이션 부팅 상태를 사전 확인합니다.
2. Composer, `.env`의 Octane 서버 설정, RoadRunner·FrankenPHP 파일과 Laravel 캐시를 체크섬과 함께 보관합니다.
3. `--server roadrunner|frankenphp`를 선택해 동일 기능·부하로 PHP 기본 실행 방식과 Octane을 비교합니다.
4. 상태 코드, 콘텐츠 유형, 본문, p95·p99·처리량·메모리·신규 오류를 검사합니다.
5. 확장 변경 hook 이후 RoadRunner는 worker PID 교체, FrankenPHP는 Caddy worker reload 수락·worker 수·응답을 검사합니다.
6. 성공·실패·중단과 관계없이 원래 상태로 복구합니다. 중단된 실행은 `restore`로 다시 복구할 수 있습니다.

```bash
# 사전 점검
scripts/benchmark/octane-ab-harness.sh doctor

# 짧은 A/B와 확장 변경 후 worker 재적용 검증
scripts/benchmark/octane-ab-harness.sh run \
  --workers 1 --vus 1 --duration 15s \
  --performance-path /api/modules/sirsoft-board/boards \
  --reload-probe

# FrankenPHP worker mode 비교
scripts/benchmark/octane-ab-harness.sh run \
  --server frankenphp --workers 2 --vus 5 --duration 15s \
  --request-host www.example.test \
  --performance-path /api/modules/sirsoft-board/boards

# 중단된 실행 복구
scripts/benchmark/octane-ab-harness.sh restore --run-dir <결과_디렉터리>
```

하네스 작성과 실서버 실행 과정에서 확장 autoload 재생성 누락, PHP 8.5 정적 trait 경고, 잘못된 RoadRunner worker PID 탐지 문제를 발견해 보완했습니다. FrankenPHP에는 loopback 전용 Caddyfile, Host 독립 라우팅, 내장 PHP 확장 검사와 MySQL socket 호환 처리를 추가했습니다. 준비 완료 판정도 상태 코드뿐 아니라 응답 본문까지 확인하며, 완료 요청 0건·요청 실패를 통과시키지 않습니다.

## 그누보드7에 반영한 호환 처리

- Octane 요청 시작 시 요청별 hook 실행 상태와 게스트 권한 캐시를 초기화합니다.
- 게시판 응답의 게스트 권한 조회값을 요청을 넘는 정적 상태에 남기지 않습니다.
- 쇼핑몰 통화 설정처럼 의도적으로 재사용하는 값은 설정 변경 hook이 worker 재적용을 요청해 갱신합니다.
- 모듈·플러그인·템플릿·언어팩 설치·업데이트·활성화·비활성화·삭제 후 worker 재적용을 예약합니다.
- 코어·모듈·플러그인 설정 변경도 같은 재적용 흐름을 사용합니다.
- 현재 요청이나 설치 명령을 끊지 않도록 작업 종료 시 한 번만 재적용합니다.
- Octane이 설치되지 않았거나 실행 중이 아니면 기존 PHP-FPM에 아무 작업도 하지 않습니다.

## 운영 배포 구성

RoadRunner는 서버의 기존 PHP를 그대로 사용해 운영 구성이 단순합니다. FrankenPHP는 이번 단기 실측에서 대체로 더 빨랐지만 자체 PHP·Caddy 바이너리의 버전, 확장, DB socket까지 별도로 관리해야 합니다.

```bash
composer require laravel/octane spiral/roadrunner-cli spiral/roadrunner-http
php artisan octane:install --server=roadrunner
php artisan extension:update-autoload
./vendor/bin/rr get-binary
```

```bash
composer require laravel/octane
php artisan octane:install --server=frankenphp
php artisan extension:update-autoload
```

### Nginx와 SSL

앞단 Nginx는 그대로 둘 수 있습니다. 기존 인증서와 TLS 설정, HTTP→HTTPS 이동, 정적 파일 처리는 Nginx가 담당하고 동적 요청만 `http://127.0.0.1:<Octane 포트>`로 전달합니다. 따라서 FrankenPHP 내부 서버에 인증서를 다시 설치할 필요가 없습니다.

FrankenPHP 기본 Caddyfile의 HTTP 사이트 주소는 모든 Host를 받아야 하며, listener만 `bind 127.0.0.1`로 제한해야 합니다. `127.0.0.1:<포트>`를 사이트 주소로 직접 쓰면 실제 도메인 Host가 매칭되지 않을 수 있습니다. Nginx는 `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`, `X-Forwarded-Port`를 전달합니다.

운영 구성은 다음 원칙을 따라야 합니다.

- Octane HTTP 포트와 FrankenPHP 관리 포트는 모두 loopback에만 열고 외부 방화벽에서도 차단합니다.
- FrankenPHP 내장 PHP에 `pdo_mysql`, `redis`, `mbstring`, `intl`, `gd`, `curl`, `openssl`, `zip`, `pcntl`, `sodium`, `fileinfo`가 있는지 검사합니다.
- MySQL이 `localhost` socket 연결을 쓰면 내장 PHP의 기본 socket과 서버 socket이 같은지 확인하고 `DB_SOCKET`을 명시합니다.
- FrankenPHP 바이너리 버전과 SHA-256을 고정하고, PHP 패치 버전 차이까지 릴리스 기록에 남깁니다.
- systemd에서 전용 사용자, `Restart=always`, 메모리·작업 수 제한과 health check를 설정합니다.
- worker 수는 CPU 수나 PHP-FPM 설정을 그대로 복사하지 말고 실측 메모리를 기준으로 정합니다. 이 2GB 서버의 6-worker 시험은 성능은 좋았지만 swap 입출력이 발생했으므로 더 낮은 worker 수도 함께 비교해야 합니다.
- Queue, Scheduler, Reverb는 Octane과 별도 서비스로 유지합니다.
- 코어·확장 배포는 `코드 반영 → 마이그레이션 → 캐시·확장 autoload 생성 → octane:reload → 본문/API 공개 smoke` 순서로 처리합니다. 모듈·플러그인·템플릿·언어팩 변경 hook도 같은 reload를 예약합니다.
- 확장 일괄 업데이트는 병렬 실행하지 않습니다. 이번 작업 전 발생한 서버 장애는 Octane이 아니라 병렬 확장 업데이트가 MySQL `max_connections=20`을 초과한 것이 원인이었습니다.

## 공식 기본 지원 전 남은 검증

- 로그인 사용자 간 세션·권한·언어·통화 상태 누수 0건
- 게시글 쓰기·첨부, 상품·장바구니·주문·결제 통보, 에디터 업로드
- FrankenPHP에서 실제 플러그인 설치·업데이트 중 동시 요청과 다중 worker 전체 교체
- 게시판·상품 API와 화면의 p99·최대 응답 단발성 지연 재현 여부
- 공개 Nginx 전환·복구 계층을 정식 하네스에 편입하고 중단 상황에서도 자동 복구되는지 검증
- 동일 PHP 패치 버전에서 실행 순서를 섞은 5회 이상 반복 비교
- 최소 30분 이상의 메모리 증가·worker recycle·DB 재연결 관찰
- 대용량 업로드, 외부 API 지연, 스트리밍과 시간 제한
- systemd 자동 복구와 실제 이전 버전 rollback

따라서 권장 결정은 **Octane을 선택 설치 기능으로 제공하고, 위 통합 시험을 CI와 운영 하네스에 추가한 뒤 기본 지원 여부를 결정하는 것**입니다.
