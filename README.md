# Gnuboard7 7.0.6 Performance Lab

공식 그누보드7 `7.0.6` 소스와 성능 개선을 기준으로, 더미데이터·A/B 하네스와 `7.0.5`에서 수행한 성능 실험 자료를 공개하는 비공식 연구 포크입니다.

[![Upstream](https://img.shields.io/badge/upstream-Gnuboard7%207.0.6-2563eb)](https://github.com/gnuboard/g7/tree/7.0.6)
[![Status](https://img.shields.io/badge/status-experimental-f59e0b)](https://github.com/jiwonpapa/gnuboard7/tree/codex/7.0.6-performance-lab)
[![Benchmark](https://img.shields.io/badge/benchmark-v0.4.1-7c3aed)](https://github.com/jiwonpapa/gnuboard7/tree/codex/7.0.6-performance-lab/modules/_bundled/sirsoft-benchmark)
[![License](https://img.shields.io/badge/license-MIT-16a34a)](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/LICENSE)

> [!IMPORTANT]
> 이 저장소는 `gnuboard/g7`의 공식 배포판이나 공식 지원 채널이 아닙니다. 현재 브랜치는 정식 릴리스가 아니라 성능 연구·검증용 `Experimental / Performance Lab`입니다.

> [!NOTE]
> `7.0.6`에는 공식 목록·검색·게시판·쇼핑 성능 개선이 포함됐습니다. 이 브랜치는 충돌하는 `7.0.5` 코어 튜닝을 재적용하지 않고 공식 구현을 채택했습니다. 기존 튜닝 코드와 Manticore 직결 시험은 [`codex/7.0.5-performance-lab`](https://github.com/jiwonpapa/gnuboard7/tree/codex/7.0.5-performance-lab)에 보존되어 있습니다.

## 저장소 목적

이 저장소는 문서만 모아 둔 보고서 저장소가 아닙니다. 튜닝이 코어·게시판·쇼핑몰·DB 인덱스·벤치마크 도구에 걸쳐 있으므로 공식 원본 소스와 변경 코드를 함께 공개합니다.

- 동일 서버·동일 데이터·동일 부하에서 수행한 공식 `7.0.5`와 튜닝 상태 비교 자료 보존
- 공식 `7.0.6`의 게시판·쇼핑몰·공통 요청 경로 개선을 새 기준선으로 채택
- CPU·RSS·가용 메모리·swap을 함께 기록하는 A/B 하네스 제공
- 성능 ON/OFF와 공식 원본 물리 원복 절차 제공
- 현실·성장·병리 데이터셋 생성과 대량 초기화 도구 제공
- 네이티브 MySQL FULLTEXT의 한계와 외부 검색 인덱스 대안성 검증
- 외부 개발자가 파일·라인·측정값을 재검토할 수 있는 코드 지도 공개

원본 프로젝트 소개·일반 기능·공식 설치 지원은 [gnuboard/g7](https://github.com/gnuboard/g7)을 기준으로 확인해 주십시오.

## 현재 공개 상태

| 항목 | 상태 | 경계 |
|---|---|---|
| 전체 G7 7.0.6 기반 소스 | 공개 | 공식 태그 `7.0.6`을 병합한 기준선 |
| 공식 목록·검색 성능 개선 | 업스트림 반영 | 이 브랜치에서 별도 코어 패치를 중복 적용하지 않음 |
| 기존 7.0.5 튜닝 | 이력 보존 | 수치·코드 지도는 7.0.5 결과이며 7.0.6 결과로 재표기하지 않음 |
| `sirsoft-benchmark` v0.4.1 | 7.0.6 호환성 검증 | 게시판·이커머스 생성/초기화 및 공식 `g7:bench` 화면 프로파일 확인 |
| 더미데이터 대량 초기화 | 로컬 계약 검증 | MySQL 8.4에서 게시글·댓글·상품·분류·브랜드 생성 후 잔여 행 없이 초기화 |
| 성능 A/B·자원 하네스 | 7.0.5 이력 | 7.0.6 재측정 전에는 수치 비교에 사용하지 않음 |
| Manticore 연결 | 7.0.5 대안 시험 | 7.0.6 브랜치에는 직결 코드를 재적용하지 않음 |
| 배포·스테이징 스크립트 | 공개 | 환경별 비밀값과 서버 설정은 저장소에 포함하지 않음 |
| 태그형 정식 릴리스·ZIP | 미배포 | 안정화 gate 통과 후 별도 릴리스 예정 |
| 실서비스 인증 | 미완료 | 주문·결제·배송·쓰기·동시 색인 부하 미검증 |

## 7.0.5에서 구현·검증한 작업

아래 항목과 실측값은 `7.0.5` 연구 결과입니다. `7.0.6`은 같은 문제 영역에 공식 구현을 도입했으므로 새 기준선에서 다시 계측해야 합니다.

### 공통 요청 경로

- 훅 로그 I/O 축약
- guest 역할·권한 반복 조회 감소
- 활성 모듈과 언어팩 중복 조회 제거
- 요청 범위 캐시와 명시적인 캐시 수명 적용

### 게시판

- 목록 컬럼 축소와 ID-first pagination
- 현재 페이지 ID만 조회한 뒤 필요한 관계만 hydration
- 게시판·정렬 조건에 맞는 복합 인덱스 추가
- 중복 count 제거와 bounded count/fallback
- 광범위 검색의 동시성 제한과 결과 정확도 메타 제공
- `total_relation`, `total_is_exact`, `search_truncated` 응답 계약 추가

### 쇼핑몰

- 분산된 홈 데이터를 storefront 응답으로 조립
- 상품 목록 ID-first 조회와 관계 hydration 축소
- 카테고리 ancestor 일괄 조회와 tree 캐시
- 인기상품 correlated subquery를 derived aggregation으로 변경
- 상품·카테고리·storefront 쿼리용 인덱스 보강

### 더미데이터·초기화

- 게시판·회원·댓글·상품 대량 생성
- bulk insert와 단계별 진행률 기록
- 웹 세션에서 대량 삭제를 기다리지 않는 queue 초기화
- 20,000행 cursor chunk, 중단·재개, 완료 작업 no-op
- 대상 게시판명·slug·ID·예상/실제 삭제량 표시
- 5초 순차 polling으로 중복 요청과 화면 깜빡임 방지

### 검색 시험

- 네이티브 MySQL FULLTEXT exact count의 메모리·정확성 사고 재현
- Manticore에서 count와 현재 페이지 ID만 가져오는 읽기 비교
- MySQL/Manticore 연결만 전환하는 검색 하네스
- 외부 인덱스 장애 시 기존 MySQL 경로로 복귀하며, 게시판 검색은 bounded fallback으로 처리

G7은 이미 Laravel Scout custom engine 확장점을 제공합니다. 따라서 이 저장소는 별도 검색 driver/registry 신설을 제안하지 않습니다. Manticore 결과는 `7.0.5`에서 대안성을 확인한 이력이며 Scout adapter, 증분 색인, freshness, 장애 전환까지 제품화한 결과가 아닙니다.

## 실측 요약

동일한 4 vCPU·8GB VM에서 각 데이터셋의 동일 스냅샷을 수동 전환해 상태별 1회, 15 RPS·5분으로 비교했습니다.

| 데이터 | 지표 | 공식 7.0.5 | 튜닝 | 변화 |
|---|---|---:|---:|---:|
| R | 전체 p95 | 107.900ms | 64.966ms | -39.79% |
| R | 호스트 CPU | 19.767% | 13.031% | -34.08% |
| R | MySQL CPU | 5.242% | 1.364% | -73.98% |
| G | 전체 p95 | 225.161ms | 49.947ms | -77.82% |
| G | 호스트 CPU | 27.465% | 12.775% | -53.49% |
| G | MySQL CPU | 12.643% | 1.695% | -86.59% |

네 phase 모두 HTTP 오류·응답 의미 오류·iteration drop·swap은 0이었습니다. G 튜닝 상태의 단일 30 RPS·15분 시험은 27,001 GET, p95 `65.119ms`, 오류·drop·swap 0으로 통과했습니다.

이 수치는 상태별 단일 run의 읽기 중심 관측입니다. 반복 분산, 실행 순서 효과, 30분 steady, 2시간 soak, 주문·결제·재고 쓰기 부하는 아직 검증하지 않았습니다. 4 vCPU·8GB는 현재 시험 규모의 보수적 시작 권장안이지 G7 공식 최소사양이나 용량 인증이 아닙니다.

## 네이티브 검색 판정

대량·광범위 검색에서 공식 MySQL 통합검색은 HTTP 200이어도 게시글을 누락하거나 게시판 검색이 HTTP 500으로 실패했습니다. 별도 관측에서는 게시글 678,866건에 매칭되는 exact count 한 번으로 `mysqld` RSS가 약 903MB 증가했습니다.

Manticore 읽기 시험은 현재 시험 색인 기준으로 R 48,468건을 82.912ms, G 194,062건을 94.247ms 중앙값에 반환했습니다. 이는 외부 검색 인덱스가 대안이 될 가능성을 확인한 결과일 뿐 특정 검색엔진 도입 권고나 운영 완료 증거가 아닙니다.

## 사용 전 필수 주의

> [!CAUTION]
> `sirsoft-benchmark`, 더미 생성, 초기화, A/B 전환 스크립트는 운영 데이터가 없는 격리 VM에서만 사용하십시오. 운영 DB에서 실행하면 대량 데이터 생성·삭제와 인덱스 변경이 발생할 수 있습니다.

- `g7-performance-toggle.sh`의 소스 archive와 수치는 `7.0.5` 전용 이력입니다. `7.0.6` 서버에서 `on`, `off`, `restore-original`을 실행하지 마십시오.
- 기존 검증 VM에 `3379ed93`로 배포한 toggle manifest는 benchmark v0.2.6, 최종 운영 모듈은 v0.3.2라 `status --strict`에 source drift가 남아 있습니다.
- 해당 기존 VM에서 toggle을 다시 실행하면 benchmark 모듈이 이전 버전으로 돌아갈 수 있으므로 manifest 재고정 전 재실행을 금지합니다. 신규 clone은 별도 스냅샷과 strict 검증을 거쳐야 합니다.
- `off`는 비교용 논리 기준선이며 완전한 물리 원복이 아닙니다.
- `restore-original`은 인덱스를 제거하므로 사전 VM/DB 스냅샷과 명시적 검토가 필요합니다.
- 공식 코어 업데이트는 이 포크의 변경 파일을 덮을 수 있습니다.
- 전체 Laravel DB test suite는 전용 test DB 부재로 완료되지 않았습니다.
- 인기상품 집계는 주문 데이터 0건 조건이라 구조만 확인한 `CODE_ONLY`입니다.

## 설치와 확인

현재 `7.0.6` 브랜치를 확인하려면 다음과 같이 clone합니다.

```bash
git clone --branch codex/7.0.6-performance-lab https://github.com/jiwonpapa/gnuboard7.git
cd gnuboard7
```

일반 설치 절차는 [INSTALL.md](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/INSTALL.md)를 따릅니다. 실환경 값은 `.env.example`을 복사한 로컬 `.env`에만 기록하고 커밋하지 마십시오.

하네스 사용법은 먼저 help와 문서를 확인하십시오.

```bash
scripts/benchmark/g7-performance-toggle.sh --help
scripts/benchmark/g7-ab-benchmark.sh --help
scripts/benchmark/g7-search-backend-toggle.sh --help
```

실행 대상 SSH host, app root, DB명, URL은 환경변수 또는 명령행 인자로만 전달해야 합니다. 저장소의 스크립트나 문서에 실제 서버 정보를 하드코딩하지 마십시오.

## 주요 문서

- [성능 튜닝 상세 코드 지도·재현 가이드](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/docs/benchmark/g7-7.0.5-performance-tuning-code-map-and-implementation-prompt-2026-07-21.md)
- [게시판 공개용 성능 튜닝 코드 지도](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/docs/benchmark/g7-7.0.5-performance-tuning-code-map-board-post-2026-07-21.md)
- [VM 성능·검색·서버 사양 초기 조사](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/docs/benchmark/g7-7.0.5-vm-performance-report-2026-07-21.md)
- [통합 성능 전환 하네스](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/docs/benchmark/g7-performance-toggle-harness.md)
- [게시판 성능 분석](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/docs/benchmark/board-list-bottleneck-analysis-2026-07-15.md)
- [쇼핑몰 상품 병목 분석](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/docs/benchmark/ecommerce-product-bottleneck-analysis-2026-07-15.md)

## 배포 예정과 남은 작업

정식 태그·배포 ZIP·독립 업데이트 채널은 아직 제공하지 않습니다. 다음 gate를 완료한 뒤 첫 실험 릴리스를 판단합니다.

1. 공식 7.0.6 기준으로 자원 하네스 재검증
2. 공식 7.0.6 네이티브 통합검색·목록 개선을 동일 R/G 데이터로 재측정
3. 주문·결제·배송·재고 데이터 생성기와 실쓰기 부하 추가
4. 동일 R/G 스냅샷의 30분 steady·2시간 soak·spike/breakpoint 실행
5. 공식 7.0.6 검색 결과가 운영 목표를 충족하지 못할 때만 Scout custom engine 실험 재개
6. 공개 배포용 changelog, 버전, 설치·원복 gate 확정

G7MediaBooster 등 별도 플러그인·제품은 이 저장소에 합치지 않으며 각 제품 저장소에서 독립 배포합니다.

## 민감정보와 공개 정책

이 저장소는 다음 파일을 배포하지 않습니다.

- `.env*` 실환경 파일, API 키, 토큰, 서비스 계정 JSON
- SSH 개인키, 인증서 개인키, keystore
- DB dump, 로컬 SQLite/DB, 백업 파일
- benchmark 원시 JSON·CSV·프로세스 로그
- VM 이미지, 디스크 snapshot, 내부 서버 설정
- Playwright 인증 상태와 브라우저 실행 산출물

`.gitignore`는 아직 추적되지 않은 파일만 보호합니다. 비밀값을 한 번이라도 커밋했다면 ignore 추가로 해결되지 않으므로 즉시 키를 폐기·재발급하고 Git 이력을 별도로 정리해야 합니다.

공개 가능한 설정은 `*.example` 파일에 placeholder만 기록하고, 실제 host·계정·DB명·URL은 로컬 환경변수로 주입합니다.

## 업스트림 관리

권장 원격 구성은 다음과 같습니다.

| 원격 | 용도 |
|---|---|
| `origin` | `https://github.com/jiwonpapa/gnuboard7.git` |
| `upstream` | `https://github.com/gnuboard/g7.git` |

업스트림 태그를 확인할 때는 다음처럼 동기화합니다.

```bash
git remote add upstream https://github.com/gnuboard/g7.git
git fetch upstream --tags
git log --oneline 7.0.6..codex/7.0.6-performance-lab
```

업스트림 변경을 이 포크에 반영할 때는 성능 기준선·toggle manifest·DB migration·A/B 결과가 함께 달라지는지 먼저 검토해야 합니다.

## 라이선스와 저작권

- 원본 그누보드7: [SIRSOFT / gnuboard/g7](https://github.com/gnuboard/g7)
- 기준 버전: 공식 `7.0.6`
- 라이선스: [MIT](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.6-performance-lab/LICENSE)
- 이 저장소의 추가 변경과 보고서는 공식 G7 릴리스가 아닙니다.

원본 저작권과 `LICENSE`를 유지하며, 포크 변경에 대한 이슈와 검증은 이 저장소에서 별도로 관리합니다.
