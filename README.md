![JW SOFT — Gnuboard7 Performance Lab · Benchmark · Tuning · Extensions](https://raw.githubusercontent.com/jiwonpapa/gnuboard7/refs/heads/codex/7.0.8-performance-lab/docs/assets/jwsoft-g7-performance-lab-intro.png)

# Gnuboard7 7.0.8 Performance Lab

공식 그누보드7 `7.0.8` 소스를 기준으로 더미데이터·A/B 하네스와 `7.0.5`에서 수행한 성능 실험 자료를 공개하는 비공식 연구 포크입니다.

[![Upstream](https://img.shields.io/badge/upstream-Gnuboard7%207.0.8-2563eb)](https://github.com/gnuboard/g7/tree/7.0.8)
[![Status](https://img.shields.io/badge/status-experimental-f59e0b)](https://github.com/jiwonpapa/gnuboard7/tree/codex/7.0.8-performance-lab)
[![Benchmark](https://img.shields.io/badge/benchmark-v0.6.0-7c3aed)](https://github.com/jiwonpapa/gnuboard7/tree/codex/7.0.8-performance-lab/modules/_bundled/sirsoft-benchmark)
[![License](https://img.shields.io/badge/license-MIT-16a34a)](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/LICENSE)

> [!IMPORTANT]
> 이 저장소는 `gnuboard/g7`의 공식 배포판이나 공식 지원 채널이 아닙니다. 정식 릴리스가 아닌 성능 연구·검증용 `Experimental / Performance Lab`입니다.

> [!NOTE]
> `7.0.8`의 공식 변경과 누적 보안·검색·스토리지 개선을 새 기준선으로 채택했습니다. 충돌하는 `7.0.5` 코어 튜닝은 재적용하지 않으며, 기존 코드와 Manticore 직결 시험은 [`codex/7.0.5-performance-lab`](https://github.com/jiwonpapa/gnuboard7/tree/codex/7.0.5-performance-lab)에 보존되어 있습니다.

## 저장소 목적

- 공식 `7.0.8` 전체 소스와 성능 연구 도구를 함께 공개
- 동일 서버·동일 데이터·동일 부하에서 수행한 공식 `7.0.5`와 튜닝 상태 비교 자료 보존
- CPU·RSS·가용 메모리·swap을 함께 기록하는 A/B 하네스 제공
- 현실·성장·병리 데이터셋 생성과 큐 기반 대량 초기화 제공
- 네이티브 MySQL FULLTEXT 한계와 외부 검색 인덱스 대안성 검증
- 외부 개발자가 파일·라인·측정값을 재검토할 수 있는 코드 지도 공개

원본 프로젝트 소개·일반 기능·공식 설치 지원은 [gnuboard/g7](https://github.com/gnuboard/g7)을 기준으로 확인해 주십시오.

## 현재 공개 상태

| 항목 | 상태 | 경계 |
|---|---|---|
| 전체 G7 7.0.8 기반 소스 | 공개 | 공식 태그 `7.0.8` 병합 |
| 공식 보안·검색·스토리지 수정 | 업스트림 반영 | 별도 코어 패치를 중복 적용하지 않음 |
| 확장 업데이트 검색 점검 | 명시 실행 전용 | 기본 업데이트에서 대용량 FULLTEXT 초기화 방지 |
| 기존 7.0.5 튜닝 | 이력 보존 | 7.0.8 결과로 재표기하지 않음 |
| `sirsoft-benchmark` v0.6.0 | 7.0.8 호환 | 게시판·이커머스 생성/초기화 및 `g7:bench` 연동 |
| 더미데이터 대량 초기화 | 격리 DB 전용 | queue·cursor chunk·중단·재개·진행 UI 포함 |
| 성능 A/B·자원 하네스 | 7.0.5 이력 | 7.0.8 재측정 전에는 수치 비교에 사용하지 않음 |
| Manticore 연결 | 7.0.5 대안 시험 | 7.0.8 브랜치에는 직결 코드를 재적용하지 않음 |
| 태그형 정식 릴리스·ZIP | 미배포 | 안정화 gate 통과 후 판단 |

## 7.0.5에서 구현·검증한 작업

아래 구현과 실측값은 `7.0.5` 연구 결과입니다. `7.0.8` 결과가 아닙니다.

### 공통·게시판·쇼핑몰

- 훅 로그 I/O, guest 권한, 활성 확장·언어팩 반복 조회 축약
- 게시글 목록 컬럼 축소, ID-first pagination, bounded count와 복합 인덱스
- 상품 목록 ID-first 조회, 카테고리 트리 캐시, 인기상품 집계 구조 개선
- 게시판·회원·댓글·상품 대량 생성과 단계별 진행률 기록
- 웹 세션에서 대량 삭제를 기다리지 않는 queue 초기화
- 20,000행 cursor chunk, 중단·재개, 대상 게시판과 예상·실제 삭제량 표시
- 5초 순차 polling으로 중복 요청과 화면 깜빡임 방지

### 검색 시험

- 네이티브 MySQL FULLTEXT exact count의 메모리·정확성 문제 재현
- Manticore에서 count와 현재 페이지 ID만 가져오는 읽기 비교
- MySQL/Manticore 연결만 전환하는 검색 하네스
- 외부 인덱스 장애 시 기존 MySQL 경로로 복귀하며 게시판 검색은 bounded fallback 처리

G7은 이미 Laravel Scout custom engine 확장점을 제공합니다. 별도 검색 driver/registry 신설을 제안하지 않습니다. Manticore 결과는 대안성을 확인한 이력이며 Scout adapter, 증분 색인, freshness, 장애 전환까지 제품화한 결과가 아닙니다.

## 실측 요약

동일한 4 vCPU·8GB VM에서 각 데이터셋의 동일 스냅샷을 상태별 1회, 15 RPS·5분으로 비교했습니다.

| 데이터 | 지표 | 공식 7.0.5 | 튜닝 | 변화 |
|---|---|---:|---:|---:|
| R | 전체 p95 | 107.900ms | 64.966ms | -39.79% |
| R | 호스트 CPU | 19.767% | 13.031% | -34.08% |
| R | MySQL CPU | 5.242% | 1.364% | -73.98% |
| G | 전체 p95 | 225.161ms | 49.947ms | -77.82% |
| G | 호스트 CPU | 27.465% | 12.775% | -53.49% |
| G | MySQL CPU | 12.643% | 1.695% | -86.59% |

네 phase 모두 HTTP 오류·응답 의미 오류·iteration drop·swap은 0이었습니다. G 튜닝 상태의 단일 30 RPS·15분 시험은 27,001 GET, p95 `65.119ms`, 오류·drop·swap 0으로 통과했습니다.

이 수치는 상태별 단일 run의 읽기 중심 관측입니다. 4 vCPU·8GB는 현재 시험 규모의 보수적 시작 권장안이지 G7 공식 최소사양이나 용량 인증이 아닙니다.

## 네이티브 검색 판정

대량·광범위 검색에서 공식 MySQL 통합검색은 HTTP 200이어도 게시글을 누락하거나 게시판 검색이 HTTP 500으로 실패했습니다. 별도 관측에서는 게시글 678,866건에 매칭되는 exact count 한 번으로 `mysqld` RSS가 약 903MB 증가했습니다.

Manticore 읽기 시험은 R 48,468건을 82.912ms, G 194,062건을 94.247ms 중앙값에 반환했습니다. 외부 검색 인덱스가 대안이 될 가능성을 확인한 결과일 뿐 특정 검색엔진 도입 권고나 운영 완료 증거가 아닙니다.

## 사용 전 필수 주의

> [!CAUTION]
> `sirsoft-benchmark`, 더미 생성, 초기화, A/B 전환 스크립트는 운영 데이터가 없는 격리 VM에서만 사용하십시오.

- `g7-performance-toggle.sh`의 소스 archive와 수치는 `7.0.5` 전용입니다. `7.0.6` 이상에서 `on`, `off`, `restore-original`을 실행하지 마십시오.
- 기존 검증 VM의 `3379ed93` manifest는 benchmark v0.2.6과 최종 v0.3.2 사이 source drift가 남아 있어 재고정 전 재실행을 금지합니다.
- `off`는 비교용 논리 기준선이며 완전한 물리 원복이 아닙니다.
- `restore-original`은 인덱스를 제거하므로 사전 VM/DB 스냅샷과 명시적 검토가 필요합니다.
- 공식 코어 업데이트는 이 포크의 변경 파일을 덮을 수 있습니다.
- 인기상품 집계는 주문 데이터 0건 조건이라 구조만 확인한 `CODE_ONLY`입니다.

## 설치와 확인

```bash
git clone --branch codex/7.0.8-performance-lab https://github.com/jiwonpapa/gnuboard7.git
cd gnuboard7
```

일반 설치 절차는 [INSTALL.md](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/INSTALL.md)를 따릅니다. 실환경 값은 `.env.example`을 복사한 로컬 `.env`에만 기록하고 커밋하지 마십시오.

```bash
scripts/benchmark/g7-performance-toggle.sh --help
scripts/benchmark/g7-ab-benchmark.sh --help
scripts/benchmark/g7-search-backend-toggle.sh --help
```

실행 대상 SSH host, app root, DB명, URL은 환경변수 또는 명령행 인자로만 전달하십시오.

## 주요 문서

- [성능 튜닝 상세 코드 지도·재현 가이드](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/g7-7.0.5-performance-tuning-code-map-and-implementation-prompt-2026-07-21.md)
- [게시판 공개용 성능 튜닝 코드 지도](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/g7-7.0.5-performance-tuning-code-map-board-post-2026-07-21.md)
- [VM 성능·검색·서버 사양 초기 조사](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/g7-7.0.5-vm-performance-report-2026-07-21.md)
- [통합 성능 전환 하네스](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/g7-performance-toggle-harness.md)
- [게시판 성능 분석](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/board-list-bottleneck-analysis-2026-07-15.md)
- [쇼핑몰 상품 병목 분석](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/docs/benchmark/ecommerce-product-bottleneck-analysis-2026-07-15.md)

## 남은 검증

1. 공식 7.0.8 네이티브 통합검색·목록을 동일 R/G 데이터로 재측정
2. 주문·결제·배송·재고 데이터 생성기와 실쓰기 부하 추가
3. 동일 R/G 스냅샷의 30분 steady·2시간 soak·spike/breakpoint 실행
4. 공식 7.0.8 검색이 운영 목표를 충족하지 못할 때만 Scout custom engine 실험 재개
5. 공개 배포용 changelog, 버전, 설치·원복 gate 확정

G7MediaBooster 등 별도 플러그인·제품은 각 제품 저장소에서 독립 배포합니다.

## 민감정보와 공개 정책

이 저장소는 `.env*` 실환경 파일, API 키, 개인키, 인증서, DB dump, 백업, 원시 benchmark, VM 이미지, 내부 서버 설정, Playwright 인증 상태를 배포하지 않습니다.

`.gitignore`는 미추적 파일만 보호합니다. 비밀값을 커밋했다면 키를 폐기·재발급하고 Git 이력을 별도로 정리해야 합니다.

## 업스트림 관리

| 원격 | 용도 |
|---|---|
| `origin` | `https://github.com/jiwonpapa/gnuboard7.git` |
| `upstream` | `https://github.com/gnuboard/g7.git` |

```bash
git remote add upstream https://github.com/gnuboard/g7.git
git fetch upstream --tags
git log --oneline 7.0.8..codex/7.0.8-performance-lab
```

업스트림 변경을 반영할 때는 성능 기준선·toggle manifest·DB migration·A/B 결과가 함께 달라지는지 검토해야 합니다.

## 라이선스와 저작권

- 원본 그누보드7: [SIRSOFT / gnuboard/g7](https://github.com/gnuboard/g7)
- 기준 버전: 공식 `7.0.8`
- 라이선스: [MIT](https://github.com/jiwonpapa/gnuboard7/blob/codex/7.0.8-performance-lab/LICENSE)
- 이 저장소의 추가 변경과 보고서는 공식 G7 릴리스가 아닙니다.

원본 저작권과 `LICENSE`를 유지하며, 포크 변경 검증은 이 저장소에서 별도로 관리합니다.
