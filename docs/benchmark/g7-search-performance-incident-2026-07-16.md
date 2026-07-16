# G7 검색 성능 사고 및 안전 튜닝 보고서

## 결론

튜닝 ON 상태의 게시판·통합검색이 대용량 데이터에서 안전하지 않았다. 원인은 서버 사양만이 아니라 검색 SQL의 무제한 결과 물질화와 MySQL FULLTEXT 메모리 기본값이 결합된 설계 회귀다.

실서버 부하 테스트는 중단했다. 운영 보호 조치와 로컬 회귀 검증을 우선하며, 실서버는 자원 게이트를 통과할 때만 단일 요청으로 검증한다.

## 실측 환경과 사고 증거

- 서버: 2 vCPU, RAM 약 2GB, swap 약 2GB
- `g7_board_posts`: 약 174만 행 추정, 데이터 약 1.2GB, 인덱스 약 1.1GB
- 자유게시판: 약 120만 건
- FULLTEXT: `ft_board_posts_title_content(title, content)` 존재
- 튜닝 상태: common/board/ecommerce 모두 `optimized`
- 검색 SQL: 각각 153초와 51초 동안 실행
- 당시 MySQL RSS: 약 1.34GB, 가용 메모리 약 100MB, swap 사용 약 1.37GB
- 장기 실행 FULLTEXT 검색 1건을 `KILL QUERY`로 종료한 뒤 5초 초과 검색 0건 확인

## 원인

1. 검색 목록의 `COUNT(*) OVER()`가 페이지 `LIMIT` 전에 전체 일치 집합을 계산했다.
2. 통합검색은 `board_posts.*`와 LONGTEXT를 window count·정렬 과정에 함께 올렸다.
3. 게시판 기본 `all` 검색이 FULLTEXT·작성자·회원 검색을 제한 없이 `UNION DISTINCT`한 뒤 다시 목록과 조인했다.
4. 작성자·회원 검색의 선행 와일드카드 `%keyword%`는 B-tree 인덱스로 범위를 좁힐 수 없다.
5. MySQL `innodb_ft_result_cache_limit`가 2,000,000,000 bytes였다. MySQL은 FULLTEXT 중간·최종 결과를 메모리에서 처리하므로 2GB 서버에 같은 크기의 쿼리별 상한은 안전하지 않다.
6. `relevance` 정렬이 실제로는 `created_at DESC`로 처리돼 관련도 계약도 지켜지지 않았다.
7. 32MiB 보호 적용 뒤 고빈도 ngram 검색어는 SQL `LIMIT`보다 먼저 FULLTEXT 내부 결과 캐시를 채워 MySQL errno 188(`FTS query exceeds result cache limit`)을 반환했고, 게시판 컨트롤러가 이를 일반 500으로 숨겼다.

MySQL 공식 문서는 `innodb_ft_result_cache_limit`가 쿼리·스레드별 FULLTEXT 결과 메모리 상한이며, 대규모 결과의 과도한 메모리 사용을 막는 용도라고 설명한다. 이 값은 Global/Dynamic 변수다.

- https://dev.mysql.com/doc/refman/8.0/en/innodb-parameters.html
- https://bugs.mysql.com/106569

## 즉시 보호 조치

- 실서버 FULLTEXT 결과 캐시 상한을 32MiB(`33554432`)로 동적 적용했다.
- 검색 부하·VU 테스트를 전면 중단했다.
- ON/OFF 비교에서 알고리즘만 전환하고, 메모리 상한·동시 실행 제한·요청 제한은 양쪽에 공통 적용한다.
- `restore-original --yes`만 기존 서버 값을 복구할 수 있게 한다.

## 수정 설계

- 동기 검색에서 window count와 무제한 exact count를 제거한다.
- ID와 정렬키만 `perPage + 1`건 조회한 뒤 선택된 ID만 PK로 hydration한다.
- 다음 페이지 존재 여부는 sentinel 1건으로 판정한다.
- 제한을 넘는 결과는 정확한 전체 개수 대신 하한과 `total_is_exact=false`를 반환한다.
- `all`·`title_content`·`author` 검색의 각 branch 후보 수와 접근 가능 페이지를 동기 검색 cap 안으로 제한한다.
- 사용자 입력의 BOOLEAN 연산자를 제거하고 빈 토큰은 즉시 0건 처리한다.
- 검색 동시 실행은 1개로 제한하며 대기시키지 않고 빠르게 실패시킨다.
- 통합검색 훅도 동시 실행 제한의 429를 삼키지 않고 그대로 반환한다.
- 공개 통합검색과 사용자·관리자 게시판 검색에는 별도 10회/분 rate limit을 적용한다.
- 1,000건 cap 판정용 sentinel은 응답 결과와 다음 페이지에 노출하지 않는다.
- FULLTEXT 상한은 `SET PERSIST` 성공을 필수로 하며 비영속 fallback은 허용하지 않는다.
- errno 188만 식별해 최근 eligible ID 1,000건을 먼저 확정하고, 해당 PK 안에서만 제목·본문 LIKE fallback을 수행한다.
- 상한을 넘긴 검색어는 SHA-256 키로 10분간 기억해 같은 FULLTEXT 실패와 32MiB 할당을 반복하지 않는다.
- fallback 결과는 `total_is_exact=false`, `total_relation=gte`로 완전 검색이 아님을 표시하며 통합검색은 `search_truncated=true`도 반환한다.
- 일반 DB 오류는 fallback으로 숨기지 않고 그대로 보고하며, 사용자·관리자 목록 컨트롤러는 최종 500 전에 예외를 기록한다.

## 운영 검증 정책

현재 서버는 가용 메모리가 안전선보다 낮아 A/B 부하 검증 대상이 아니다. 다음 조건을 모두 만족하기 전에는 실서버 검색 요청을 자동 실행하지 않는다.

- `MemAvailable >= 384MB`
- swap 증가 및 swap-in/out 없음
- 장기 실행 검색 쿼리 0건
- 서비스·maintenance·튜닝 strict status 정상
- `search.fallback_scan_cap=1000`, `search.safety_guard=enabled`
- VU 1, 요청 1회, SQL/HTTP 시간 제한 적용

조건을 만족하지 않으면 로컬 테스트와 정적 SQL 검증 결과만 보고한다. 5 VU 검색 테스트는 이 서버에서 금지한다.
