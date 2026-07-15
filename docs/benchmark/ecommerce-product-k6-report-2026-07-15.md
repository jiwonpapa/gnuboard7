# 쇼핑몰 상품 목록·상세 k6 성능 보고

> SQL·코드 경로·PHP-FPM 대기열까지 포함한 상세 원인 분석은 [ecommerce-product-bottleneck-analysis-2026-07-15.md](ecommerce-product-bottleneck-analysis-2026-07-15.md)를 참고합니다.

## 2만 건 동일 조건 A/B 결과

공식 7.0.4 원본(`off`)과 개선 패치(`on`)를 같은 서버, 같은 데이터, 10 VU, 30초 조건으로 분리 측정했습니다. 상품은 전체 20,000건, 공개 목록 대상 18,988건입니다.

| 화면 | 상태 | 최초 API 수 | 전체 API 평균 | 전체 API p95 | 가장 느린 API p95 | 최대 | 화면 반복 | CPU busy 평균 | 오류 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 목록 | 원본 | 5 | 5.38s | 7.61s | 8.48s | 9.45s | 41 | 99.96% | 0% |
| 목록 | 개선 | 2 | 327ms | 861ms | 1.17s | 2.24s | 224 | 78.87% | 0% |
| 상세 | 원본 | 5 | 2.12s | 3.99s | 4.46s | 5.94s | 69 | 89.28% | 0% |
| 상세 | 개선 | 3 | 249ms | 644ms | 913ms | 1.99s | 234 | 76.31% | 0% |

- 목록 평균은 93.9%, p95는 88.7% 감소했고 화면 처리량은 5.5배 증가했습니다.
- 상세 평균은 88.2%, p95는 83.9% 감소했고 화면 처리량은 3.4배 증가했습니다.
- CPU busy는 목록 21.1%p, 상세 13.0%p 감소했습니다.
- 개선 상태는 10 VU 지속 부하에서도 목록 21.1%, 상세 23.7%의 CPU idle을 남겼습니다.
- 오류율은 양쪽 모두 0%였습니다.

판정은 **초기 운영 가능, 추가 여유 필요**입니다. 전체 API 요청 기준 상세 p95 800ms 목표는 충족했고 목록은 861ms로 61ms 초과했습니다. 실제 화면 체감에 가까운 가장 느린 API p95는 목록 1.17초, 상세 913ms입니다. CPU 70% 이하 목표는 충족하지 못했지만, 이 테스트는 10명이 1초 간격으로 같은 화면을 계속 다시 여는 지속 부하라 초기 운영의 일반 탐색보다 강합니다. 2 vCPU·2GB 서버로 소규모 초기 운영은 가능하되, 트래픽 증가 전 추가 최적화와 알람 설정이 필요합니다.

## 서버 설정 판정

| 항목 | 값 | 판정 |
|---|---|---|
| CPU / RAM | 2 vCPU / 1.9GiB, swap 1.9GiB | 초기 운영 가능, 고부하 여유는 작음 |
| PHP-FPM | 8.5.8, dynamic, max_children 6, memory_limit 256M | 2 vCPU·현재 메모리에 적정 |
| OPcache | 활성, 128MB | 정상 |
| Laravel cache/session/queue | Redis | 정상 |
| Laravel production cache | config/routes/views/hooks 생성 | 정상 복구 |
| MySQL | 8.4.10, buffer pool 384MB, max_connections 20 | 현재 FPM 규모에 적정 |
| MySQL buffer hit | 약 99.8% | 디스크 I/O 병목 아님 |
| Nginx | worker 2, gzip on, keepalive 20s | 정상 |
| 부하 중 steal / iowait | 사실상 0% | 호스트·디스크 문제 아님 |

초기 하네스가 `optimize:clear` 후 production 캐시를 재생성하지 않아 첫 A/B 절대값이 오염됐습니다. 해당 결과는 폐기했고, 하네스를 수정한 뒤 config/routes/views/hooks 캐시가 생성된 상태에서 위 표 전체를 다시 측정했습니다.

## 개선 범위

- 목록 화면의 분류·최근·인기·신상품을 `/api/modules/sirsoft-ecommerce/storefront` 응답으로 통합했습니다.
- 상세의 리뷰와 문의는 탭을 열 때만 조회하도록 변경했습니다.
- 카테고리 재귀 N+1, 상품 이미지·breadcrumb·권한 N+1을 일괄 조회와 요청 단위 재사용으로 줄였습니다.
- 인기상품 상관 서브쿼리를 최근 주문 집계 서브쿼리로 바꾸고 분류·인기·신상품에 30~60초 캐시를 적용했습니다.
- 상품 목록 관계 로드는 페이지 ID를 먼저 정한 뒤 해당 행에만 수행합니다.
- 공개 상품 최신순·가격순, 최근 주문 집계용 MySQL 복합 인덱스 3개를 추가했습니다.

## 온오프 하네스

```bash
scripts/benchmark/ecommerce-performance-toggle.sh on
scripts/benchmark/ecommerce-performance-toggle.sh off
scripts/benchmark/ecommerce-performance-toggle.sh status
scripts/benchmark/ecommerce-performance-toggle.sh restore-original --yes
```

`off`는 공식 7.0.4 파일을 재배포하고 벤치마크 인덱스를 invisible로 전환합니다. `restore-original --yes`는 공식 파일 복구와 인덱스 삭제까지 수행합니다. 모든 전환은 production 캐시를 재생성합니다. 현재 스테이징은 `on`, 인덱스 3개 `VISIBLE` 상태입니다.

## 검증 자료

- k6 스크립트: `modules/_bundled/sirsoft-benchmark/tests/k6/ecommerce-products.js`
- 최종 원시 요약: `/tmp/g7-ecommerce-ab-20k/baseline-cached`, `/tmp/g7-ecommerce-ab-20k/optimized-cached`
- PHP 문법, JSON 문법, Bash 문법, k6 inspect, 실제 API 3종 smoke가 통과했습니다.
- 로컬 PHPUnit은 저장소에 `.env.testing`이 없어 실행하지 못했습니다.
