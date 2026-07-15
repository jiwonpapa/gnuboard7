# 그누보드7 게시판 목록 병목 분석

분석 일자: 2026-07-15
대상: 그누보드7 7.0.3, `sirsoft-board` 원본 코드 및 라이브 스테이징

## 결론

병목은 OFFSET 하나가 아니다.

- 깊은 페이지: OFFSET과 **목록 전체 컬럼의 조기 row lookup**이 결합된 것이 가장 큰 병목이다.
- 첫 페이지: 주 목록 SQL보다 **요청당 26 SELECT, 권한 조회, 관계 eager loading, Resource 직렬화** 비용이 더 크다.
- 서버: 게시글 테이블과 인덱스가 약 2.28GiB인데 InnoDB buffer pool은 384MiB라 콜드 읽기와 동시 부하에 불리하다.
- 그누보드4도 OFFSET을 사용하지만, 게시판별 테이블·저장 카운터·단순 PHP 렌더링 구조라 첫 페이지의 고정 비용이 G7보다 훨씬 작다.

## 실측 근거

### 첫 페이지

| 구간 | 결과 |
|---|---:|
| 일반글 주 SQL | 약 0.19ms |
| API 전체 응답 | 약 128ms |
| 응답 크기 | 약 28KB |
| 요청당 SELECT | 26회 |

첫 페이지에서는 게시물 120만 건 자체보다 다중 쿼리와 애플리케이션 계층 비용이 대부분이다.

SELECT 26회의 구성은 다음과 같다.

| 구분 | SELECT |
|---|---:|
| 코어 부트스트랩: ID 정책, 활성 모듈, 언어팩 | 4 |
| guest 역할·권한 | 12 |
| 게시판 조회 | 1 |
| 공지글 + 작성자 + 아바타 + 썸네일 | 4 |
| 일반글 + 작성자 + 아바타 + 썸네일 | 4 |
| 답글 존재 확인 | 1 |
| 합계 | 26 |

guest 역할은 권한 전체를 eager load한 뒤에도 각 권한마다 다시 `EXISTS`를 실행한다. 목록 응답의 abilities 생성까지 포함해 권한 관련 SELECT만 12회 발생했다.

### 120만 건 게시판 1,000페이지

동일 조건의 `EXPLAIN ANALYZE` 결과다. 캐시 상태에 따라 절대시간은 달라질 수 있지만 실행 구조 차이는 명확하다.

| 쿼리 형태 | 실행시간 |
|---|---:|
| 현재 목록 쿼리, OFFSET 19,980 | 약 11.06초 |
| 목록 복합 인덱스 강제 | 약 9.38초 |
| `id, created_at`만 covering index로 조회 | 약 11.5ms |
| ID 페이지를 먼저 구한 뒤 21건만 본문 조회 | 약 27ms |

현재 쿼리는 OFFSET으로 건너뛸 2만 건에도 제목·작성자·통계·본문 미리보기 등 실제 행을 조회한다. `title` 하나만 추가해도 covering index가 깨져 약 9.31초가 걸렸다.

즉 단순히 인덱스를 강제하는 것으로는 부족하다. **ID만 먼저 페이지네이션하고 실제 20건을 다시 조회하는 deferred join**이 필요하다.

## 코드상 병목

### 1. 넓은 목록 SELECT를 OFFSET 전에 실행

`PostRepository::paginate()`는 목록에서 20개가 넘는 컬럼과 `SUBSTRING(content, 1, 200)`을 선택한다. 정렬 인덱스에 포함되지 않은 컬럼 때문에 OFFSET으로 버리는 행까지 clustered row lookup이 발생한다.

- `modules/_bundled/sirsoft-board/src/Repositories/PostRepository.php`
- `modules/_bundled/sirsoft-board/database/migrations/2026_04_17_000004_update_indexes_in_board_tables.php`

`idx_board_posts_list_count`는 주석상 "커버링"으로 표현됐지만 실제 목록 projection 전체를 커버하지 않는다.

### 2. 공지와 일반글 관계를 각각 다시 조회

첫 페이지는 공지와 일반글을 별도 조회하고 두 그룹 모두 사용자, 아바타, 썸네일을 eager load한다. 공지가 없어도 일반글 관계 쿼리는 항상 실행된다.

공지는 개수 제한이 없어 공지 수가 많으면 첫 페이지 응답 행과 관계 쿼리 입력이 계속 커진다.

### 3. 답글 전체 트리를 depth별 반복 조회

현재 페이지 원글 20개에 연결된 답글을 depth별 `while` 쿼리로 모두 가져온다. 깊이가 늘어날 때마다 SQL이 추가되며, 각 단계에서 사용자·아바타·썸네일 관계도 다시 eager load될 수 있다.

답글이 많은 원글 하나가 목록 전체 응답 크기와 메모리를 크게 늘릴 수 있다.

### 4. guest 권한의 중복 SQL

`PermissionMiddleware`는 guest 역할과 권한 전체를 이미 `with('permissions')`로 읽은 뒤, `checkGuestPermission()`에서 관계 컬렉션을 사용하지 않고 DB `EXISTS`를 다시 실행한다.

`PostCollection`은 목록 abilities를 만들기 위해 권한을 9종 이상 개별 확인한다. 라우트의 `posts.read` 검사와 목록 abilities의 `posts.read`도 중복된다.

- `app/Http/Middleware/PermissionMiddleware.php`
- `modules/_bundled/sirsoft-board/src/Http/Resources/PostCollection.php`

### 5. 목록에 과한 데이터와 관계 로딩

목록은 사용자 전체 컬럼, 아바타, 썸네일, 이메일, 상태, 본문 미리보기를 반환한다. 기본 테이블형 목록에서 사용하지 않는 데이터도 게시판 타입과 무관하게 조회한다.

이는 첫 페이지 DB round trip, Eloquent 모델 생성, JSON 직렬화, 네트워크 전송 비용을 늘린다.

### 6. 필터 목록은 전체 COUNT 재실행

기본 목록 total은 캐시되므로 매번 COUNT하지 않는다. 하지만 검색·카테고리·상태·작성자·기간 필터가 있으면 캐시를 사용하지 않고 실제 COUNT를 실행한다.

- `modules/_bundled/sirsoft-board/src/Services/PostService.php`

따라서 기본 목록보다 검색·필터 목록이 훨씬 불리하다.

### 7. 메모리 대비 큰 통합 테이블

InnoDB persistent stats 기준 게시글 테이블은 약 174만 행이다.

| 구성 | 크기 |
|---|---:|
| clustered data | 약 1.18GiB |
| secondary indexes | 약 1.10GiB |
| 합계 | 약 2.28GiB |
| InnoDB buffer pool | 384MiB |

게시글 테이블 하나도 buffer pool보다 약 6배 크다. 통합 테이블 자체가 잘못이라는 뜻은 아니지만, deep OFFSET의 비커버링 row lookup과 결합하면 랜덤 I/O와 캐시 축출 비용이 커진다.

## 그누보드4와 비교

그누보드4 원본 목록도 OFFSET을 사용하므로 깊은 페이지 확장성이 좋은 구조는 아니다. 다만 첫 페이지 비용은 훨씬 단순하다.

| 항목 | 그누보드4 | 그누보드7 |
|---|---|---|
| 게시글 저장 | 게시판별 `g4_write_*` 테이블 | 통합 `g7_board_posts` |
| 기본 total | `bo_count_write` 저장값 | 기본 목록 캐시, 필터 시 COUNT |
| 기본 목록 | 게시판 테이블의 단일 `SELECT *` | 공지·일반·관계·답글·권한 등 26 SELECT |
| 작성자 | 게시글 행에 이름·이메일 저장 | 사용자 및 아바타 관계 조회 |
| 댓글 수 | 게시글의 `wr_comment` | 게시글의 `comments_count` |
| 렌더링 | PHP에서 HTML 직접 렌더링 | REST JSON + JSON UI 클라이언트 렌더링 |
| 깊은 페이지 | OFFSET 한계 존재 | OFFSET + 넓은 row lookup으로 더 불리 |

그누보드4 원본 근거:

- [gnuboard4/bbs/list.php](https://github.com/gnuboard/gnuboard4/blob/master/bbs/list.php)
- [gnuboard4/adm/sql_write.sql](https://github.com/gnuboard/gnuboard4/blob/master/adm/sql_write.sql)

따라서 "G4보다 느린 것 같다"는 체감은 타당하다. G7의 기능이 많아서 어느 정도 고정 비용은 생기지만, 첫 페이지 26 SELECT와 deep OFFSET 전의 wide row lookup까지 필수 비용이라고 보기는 어렵다.

## 개선 우선순위

1. 깊은 페이지는 ID-only deferred join 또는 커서 페이지네이션으로 변경한다.
2. 100페이지 정도까지 기존 페이지 번호를 유지하고 이후 커서 방식으로 전환하는 하이브리드 방식을 검토한다.
3. guest 권한은 이미 로드한 권한 컬렉션에서 일괄 판정하고, 라우트와 Resource의 중복 검사를 제거한다.
4. 목록 projection을 기본형·카드형으로 분리하고 본문 미리보기, 아바타, 썸네일을 필요한 화면에서만 조회한다.
5. 공지 최대 개수와 목록에 포함할 답글 수를 제한하거나 답글을 별도 API로 지연 로딩한다.
6. 필터 COUNT는 조건별 단기 캐시 또는 별도 집계 전략을 사용한다.
7. 성능 회귀 기준에 첫 페이지 쿼리 수, p95, deep page SQL 시간을 함께 넣는다.

## 최종 판단

- 첫 페이지 병목: OFFSET이 아니라 26개 SQL과 애플리케이션 계층 fan-out이 핵심이다.
- 깊은 페이지 병목: OFFSET 자체보다 OFFSET 전에 넓은 실제 행을 계속 조회하는 방식이 치명적이다.
- 인덱스만 추가해서 해결될 문제는 아니다.
- G4도 대용량 deep page는 한계가 있지만, 현재 G7 목록 경로는 G4보다 고정 비용과 쿼리 수가 지나치게 크다.
