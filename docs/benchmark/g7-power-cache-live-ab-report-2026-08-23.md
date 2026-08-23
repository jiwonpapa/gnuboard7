# G7PowerCache 온라인 ON/OFF 실측 보고서

> 측정일: 2026-08-23 KST
> 대상: `https://www.g7devops.com` 온라인 테스트 서버
> 결론: 캐시 비용이 큰 카테고리 API에는 즉시 효과가 있었고, 작은 페이지 API에는 효과가 제한적이었습니다. Technical Preview 범위로 계속 운영하되 전체 사이트 캐시로 확대해서는 안 됩니다.

## 결론 먼저

| 라우트 | OFF p95 | ON p95 | p95 개선 | 처리량 개선 | PHP-FPM CPU 개선 | MySQL Questions 개선 |
|---|---:|---:|---:|---:|---:|---:|
| 카테고리 목록, 39.9KB | 225ms | 155ms | **31.1%** | **32.2%** | **37.0%** | 0.0% |
| 카테고리 상세, 1.1KB | 232ms | 142ms | **38.8%** | **41.3%** | 12.9% | **31.3%** |
| 페이지 `about`, 3.3KB | 141ms | 135ms | 4.3% | 6.0% | 4.2% | **22.1%** |

오류는 세 라우트 모두 OFF/ON 각각 80건 중 0건이었습니다. 큰 카테고리 목록은 DB 질의 수가 줄지 않아도 트리 조립·Resource 변환·JSON 직렬화를 생략해 PHP CPU와 지연시간이 크게 줄었습니다. 작은 페이지는 원본 자체가 가벼워 응답시간 ROI가 작습니다.

## 배포·운영 상태

| 항목 | 값 |
|---|---|
| 플러그인 | `g7-power_cache` 0.1.0 Technical Preview |
| 서버 선언 버전 | Gnuboard7 7.0.8 |
| PHP | 8.5.9 FPM |
| 서버 | 2 vCPU, RAM 1.9GiB, swap 1.9GiB |
| 전용 저장소 | Redis DB 7 |
| 현재 모드 | `active` |
| doctor | PASS |
| dirty / pending outbox / emergency | 0 / 0 / no |
| 플러그인 Redis 사용량 | 18 keys, 136,784 bytes |

서버 Git 기준점은 `7.0.3-dirty`로 표시되지만 런타임 `APP_VERSION`은 7.0.8이고, 7.0.8의 확장 미들웨어·동기 훅 계약이 실제 서버 코드에 존재함을 설치 전 확인했습니다. 재현 시에는 이 서버의 파일 업데이트 이력과 Git ancestry가 다르다는 점을 함께 봐야 합니다.

## ON/OFF 방법

관리자 플러그인 설정의 `mode` 또는 다음 명령으로 즉시 전환할 수 있습니다.

```bash
php artisan power-cache:mode bypass  # OFF
php artisan power-cache:mode observe # 저장 없이 적합성만 관측
php artisan power-cache:mode active  # ON, doctor 실패 시 전환 차단
php artisan power-cache:status
php artisan power-cache:doctor
```

실서버에서 다음 응답 전이를 확인했습니다.

```text
bypass: BYPASS; reason=mode
active 첫 요청: MISS-STORED; reason=cacheable
active 다음 요청: HIT; reason=fresh_generation
```

## 측정 조건

- 도구: ApacheBench 2.3
- 프로토콜: HTTPS, keep-alive
- 각 라우트: 80 requests, concurrency 4
- OFF: 플러그인을 설치·활성화한 채 `mode=bypass`
- ON: `mode=active`, Redis warm HIT
- 비교 전 각 라우트를 1회 예열
- PHP CPU: `php8.5-fpm.service`의 누적 `CPUUsageNSec` 전후 차이
- DB 부하: MySQL 전역 `Questions` 전후 차이

OFF도 같은 플러그인과 확장 게이트를 통과하므로, 플러그인 미설치 상태가 아니라 실제 운영 토글의 차이를 비교했습니다.

## 원시 결과

| 라우트 | 모드 | p50 | p95 | p99 | req/s | FPM CPU / 80건 | Questions / 80건 | 건당 Questions |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 카테고리 목록 | OFF | 161ms | 225ms | 240ms | 23.47 | 5,273ms | 564 | 7.05 |
| 카테고리 목록 | ON | 121ms | 155ms | 173ms | 31.03 | 3,324ms | 564 | 7.05 |
| 카테고리 상세 | OFF | 143ms | 232ms | 265ms | 24.59 | 3,740ms | 821 | 10.26 |
| 카테고리 상세 | ON | 105ms | 142ms | 156ms | 34.75 | 3,257ms | 564 | 7.05 |
| 페이지 `about` | OFF | 108ms | 141ms | 151ms | 34.03 | 3,350ms | 724 | 9.05 |
| 페이지 `about` | ON | 104ms | 135ms | 143ms | 36.08 | 3,208ms | 564 | 7.05 |

MySQL `Questions`는 전역 카운터라 측정용 조회와 같은 시각의 외부 요청이 소량 포함될 수 있습니다. 방향성과 요청당 고정 바닥을 보는 근거로 사용했으며, 세션별 exact query profile로 과장하지 않습니다.

## 실측 중 발견해 바로 수정한 결함

초기 구현은 HIT마다 DB state table을 읽어 dirty/outbox 장벽을 확인해 세 라우트 모두 요청당 Questions가 약 10개로 늘었습니다. 지연시간만 줄고 DB 병목을 남기는 구조라 배포 완료로 판정하지 않았습니다.

수정 후에는 다음 순서로 바꿨습니다.

1. 정상 상태의 `site_id`, `runtime_epoch`, `dirty_event_id=0` snapshot을 전용 Redis에 저장
2. 변경 훅은 콘텐츠 DB 커밋 전에 Redis emergency barrier를 먼저 설정
3. 커밋 후 outbox 세대 적용·DB clean 확인·Redis snapshot 반영을 완료
4. 모든 단계가 끝난 뒤에만 emergency barrier 해제
5. 정상 HIT는 Redis snapshot·emergency·generation만 확인하고 플러그인 DB 조회는 0
6. dirty, 저장소 장애, snapshot 소실 때만 DB outbox 복구 경로 실행

독립 회귀 테스트에서 정상 HIT의 플러그인 DB query 0을 고정했고 전체 **28 tests / 254 assertions**가 통과했습니다.

## 무효화 실서버 확인

콘텐츠를 수정하지 않고 운영 명령으로 세대를 회전해 범위 격리를 확인했습니다.

| 조작 | 대상 라우트 | 비대상 라우트 | 결과 |
|---|---|---|---|
| `purge --scope=page` | 페이지가 `MISS-STORED → HIT` | 카테고리는 계속 HIT | 통과 |
| `purge --scope=category` | 카테고리가 `MISS-STORED → HIT` | 페이지는 계속 HIT | 통과 |

두 경우 모두 종료 뒤 `dirty=0`, `pending=0`, `emergency=no`, doctor PASS였습니다.

## 남은 병목과 제품 판단

정상 HIT에도 약 7 Questions/request가 남습니다. G7PowerCache가 `api, after_core`에서 동작하므로, 캐시보다 먼저 실행되는 그누7 코어 미들웨어·확장 부팅 비용은 코어 수정 없이 생략할 수 없습니다. `before_core`로 옮기면 인증·IDV·locale 처리를 우회할 수 있어 보안상 채택하지 않았습니다.

따라서 판정은 다음과 같습니다.

- **출시 가치 있음:** 비회원 공개 API 중 원본 조립·직렬화·DB 조회 비용이 큰 라우트
- **효과 제한:** 이미 100ms 안팎인 작은 JSON, 사용자별·검색·쓰기·파일 라우트
- **현재 금지:** “그누보드7 전체를 무조건 가속하는 0-query 캐시”라는 표현
- **코어 개선 ROI:** 인증·권한·IDV가 끝난 뒤 컨트롤러 직전에 실행되는 공식 `after_route_guards` seam

이번 80건 측정은 기능·방향 확인용 smoke A/B입니다. 정식 Beta 판정 전에는 혼합 라우트 15~30분, 동시성 단계 1/4/16/32, 쓰기와 purge 동시 실행, Redis 장애·복구, p99·RSS·swap·Redis ops를 같은 하네스로 반복 측정해야 합니다.
