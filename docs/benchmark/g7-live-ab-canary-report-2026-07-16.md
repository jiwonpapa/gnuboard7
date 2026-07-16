# G7 실서버 A/B 안전 Canary 보고서 (2026-07-16)

## 결론

- 현재 `2 vCPU / 2GB RAM / PHP-FPM max_children=6` 서버에서 **5 VU는 적정 기본값이 아니다**.
- `1 VU`, 5초당 route matrix 1개로 제한한 canary도 baseline의 게시판·전역 검색 진입 시 MySQL `FULLTEXT initialization`이 메모리와 swap을 급격히 사용해 안전장치가 중단했다.
- 일반 홈·게시판 목록/내용/페이징·쇼핑몰 경로는 정상 응답했다. 병목은 VU 자체보다 baseline의 위험 검색 경로다.
- baseline이 중단돼 optimized 부하는 실행하지 않았으며, 전후 성능 비교 보고서는 의도적으로 만들지 않았다.
- 하네스는 MySQL 제한을 원복하고 최종 튜닝 ON, 유지보수 해제, 서비스·HTTP smoke 정상까지 복구했다.

## 서버와 실행 조건

| 항목 | 값 |
|---|---:|
| 서버 | 2 vCPU, RAM 1.9GB, swap 1.9GB |
| PHP-FPM | `pm.max_children=6` |
| 실행 커밋 | `c275b41b` |
| 반복 | OFF/ON 각 1회 예정 |
| 일반 부하 | 1 VU, 5초당 matrix 1개, 5초 |
| 위험 부하 | 1 VU 단건 |
| 깊은 페이지 | 2페이지 |
| MySQL SELECT 제한 | 3,000ms |
| 실행 전 상태 | `overall=optimized`, load `0.07`, MemAvailable 약 592MB, swap 0 |

## baseline 관측

일반 경로 matrix는 k6 constant-arrival의 0초 시작 특성 때문에 2회 예약됐다. 일반 경로 42요청과 깊은 페이지 1요청, 총 43요청이 완료됐다.

| 경로 | baseline p95 |
|---|---:|
| 홈 | 314.76ms |
| 게시판 목록 1페이지 | 90.21ms |
| 게시판 목록 2페이지 | 92.07ms |
| 게시글 내용 | 76.09ms |
| 게시글 이전·다음 | 61.00ms |
| 게시판 깊은 페이지 2 | 93.93ms |
| 쇼핑 목록 1페이지 | 159.04ms |
| 쇼핑 목록 2페이지 | 175.57ms |
| 쇼핑 검색 1페이지 | 192.34ms |
| 쇼핑 검색 2페이지 | 211.88ms |
| 쇼핑 분류 | 468.71ms |
| 쇼핑 인기 상품 | 458.16ms |

완료된 43요청의 HTTP 오류율은 0%, dropped iteration은 0이었다. 게시판 검색과 전역 검색은 응답을 완료하기 전에 안전장치가 실행을 중단했다.

## 중단 원인

17초 시점에 다음 변화가 감지됐다.

| 지표 | 시작 | 중단 시점 |
|---|---:|---:|
| 호스트 busy | 24.0% | 61.611% |
| MySQL CPU | 3.5% | 40.284% |
| MemAvailable | 553MB | 111MB |
| swap 사용 | 0MB | 156MB |

하네스는 `mem_available_immediate`로 k6를 즉시 중단했다. 이후 DB에서 `FULLTEXT initialization` 상태의 검색이 잠시 계속되면서 외부 관측상 MemAvailable 최저 약 74MB, swap 사용 약 775MB, MySQL RSS 약 1.23GB까지 증가했다.

`@@GLOBAL.max_execution_time=3000`은 이 FULLTEXT 초기화 작업을 3초 안에 끝내지 못했다. 따라서 전역 SELECT 제한만으로 baseline 대용량 검색을 안전하게 보장할 수 없다.

## 복구 결과

- 잔류 검색은 별도 강제 종료 전에 자연 종료됐다. `KILL QUERY 741` 시도는 `Unknown thread id`로 실제 쿼리를 종료하지 않았다.
- MySQL `max_execution_time`: `0`으로 원복 확인
- A/B 원격 잠금: 제거 확인
- 최종 상태: `overall=optimized`
- 모듈: board `1.1.2`, benchmark `0.2.5`, ecommerce `1.0.4`
- 유지보수: 해제
- Nginx, MySQL, PHP-FPM, queue, reverb: active
- 홈·게시판 목록·쇼핑 목록 smoke: HTTP 200

복구 직후 CPU와 I/O는 유휴 상태로 돌아왔지만 swap 약 775MB와 MySQL RSS 약 1.23GB가 남았다. 추가 부하 시험은 중단했다.

## 판정과 후속 조치

1. 운영 서버 기본 A/B에서는 깊은 페이지·게시판 검색·전역 검색을 제외한다.
2. 안전 기본값은 `1 VU`, 5초당 matrix 1개로 유지한다.
3. 3 VU와 5 VU 단계는 메모리·swap이 실행 전 수준으로 회복되고 hot-only 1 VU가 통과한 뒤에만 검토한다.
4. 위험 검색은 운영 서버가 아니라 동일 데이터 복제 환경에서 별도 측정한다.
5. 운영 서버에서 꼭 검색을 측정할 경우 DB 세션 식별과 강제 종료가 가능한 전용 실행 방식이 필요하다.
6. 이번 결과로는 **5 VU 부하 시험 진행 불가**, **전후 성능 개선률 산출 불가**로 판정한다.

## 원시 증거

- `storage/app/benchmark/reports/g7-ab-20260716-161654/g7-ab-benchmark.log`
- `storage/app/benchmark/reports/g7-ab-20260716-161654/runs/baseline-1-cpu.csv`
- `storage/app/benchmark/reports/g7-ab-20260716-161654/runs/baseline-1-cpu.log`
- `storage/app/benchmark/reports/g7-ab-20260716-161654/runs/baseline-1-k6.log`
- `storage/app/benchmark/reports/g7-ab-20260716-161654/runs/baseline-1-k6-summary.json`
