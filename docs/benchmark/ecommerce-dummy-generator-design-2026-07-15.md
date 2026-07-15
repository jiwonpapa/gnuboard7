# G7 쇼핑몰 더미데이터 생성기 확장 분석

작성일: 2026-07-15

## 결론

- 별도 모듈을 새로 만들지 않고 기존 `sirsoft-benchmark` 모듈에 `board`와 `commerce` 작업 유형을 추가한다.
- `sirsoft-ecommerce` 원본 코드는 수정하지 않는다. 벤치마크 모듈이 공개 테이블 계약과 스토리지 드라이버를 사용한다.
- 상품 1건은 상품 행만 넣어서는 부족하다. 최소한 상품, 기본 옵션, 대표 분류 피벗, 대표 이미지 행이 함께 생성되어야 상세·장바구니까지 정상 테스트할 수 있다.
- 20만 상품의 기본 이미지 방식은 `100개 물리 이미지 풀 공유 + 상품별 고유 이미지 DB 행`으로 한다. 상품별 파일 복제는 소규모 정합성 테스트용 옵션으로 제한한다.
- 상품 배치는 250/500/1000만 허용한다. 상품 행이 약 30개 컬럼이므로 기존 게시판용 2000/3000 배치는 MySQL placeholder 한도에 근접하거나 초과한다.

## 현재 스테이징 확인

| 항목 | 현재 값 |
|---|---:|
| G7 | 7.0.4 |
| `sirsoft-ecommerce` | 1.0.3, 활성 |
| `sirsoft-benchmark` | 0.1.3, 활성 |
| Queue | database |
| Storage | local |
| 상품 / 분류 / 상품 이미지 | 0 / 0 / 0 |

현재 데이터가 비어 있어 20만 상품 생성·초기화 검증을 시작하기 좋은 상태다.

## 원본 데이터 계약

| 대상 | 테이블 | 생성기 필수 처리 |
|---|---|---|
| 분류 | `ecommerce_categories` | `parent_id`, `depth`, ID가 포함된 materialized `path`, 고유한 벤치마크 slug |
| 상품 | `ecommerce_products` | 다국어 JSON, 고유 `product_code`, 가격·재고·상태·통화·SEO 동기화 필드 |
| 기본 옵션 | `ecommerce_product_options` | 상품마다 최소 1행, 기본/활성 옵션, 상품과 일치하는 가격·재고 |
| 분류 연결 | `ecommerce_product_categories` | 상품당 대표 분류 1개 이상, `is_primary=1` |
| 상품 이미지 | `ecommerce_product_images` | 상품별 고유 12자 `hash`, 스토리지 `path`, MIME·크기·가로·세로, 대표 이미지 |

근거:

- 상품 등록 서비스는 상품 생성 후 분류·옵션·이미지를 한 트랜잭션에서 연결한다: `modules/_bundled/sirsoft-ecommerce/src/Services/ProductService.php:181`
- 관리자 상품 등록은 분류와 옵션을 최소 1개 요구한다: `modules/_bundled/sirsoft-ecommerce/src/Http/Requests/Admin/StoreProductRequest.php:50`
- 장바구니는 `product_option_id`가 필수다: `modules/_bundled/sirsoft-ecommerce/database/migrations/2026_04_01_000023_create_ecommerce_carts_table.php:15`
- 분류는 생성 후 실제 ID를 포함하도록 `path`를 다시 계산한다: `modules/_bundled/sirsoft-ecommerce/src/Services/CategoryService.php:138`
- 이미지 URL은 이미지 행의 고유 hash를 사용하고 실제 파일은 모듈 스토리지에서 읽는다: `modules/_bundled/sirsoft-ecommerce/src/Services/ProductImageService.php:332`

## 기존 샘플 시더를 그대로 쓸 수 없는 이유

원본 `ProductSeeder`에는 이미지 풀과 상품 템플릿이 있으므로 사전과 이미지 처리 아이디어는 재사용할 수 있다. 그러나 대량 생성기로 직접 사용할 수는 없다.

- 실행 전에 기존 상품·주문·이미지 폴더 전체를 삭제한다.
- 상품, 옵션, 이미지가 Eloquent 단건 생성이다.
- 이미지 풀은 800x800 이미지 여러 장을 메모리에 유지한다.
- 외부 이미지 다운로드 실패 복구, Queue 중단·재개, 데이터셋 격리가 없다.
- 100개 이상을 코드상 `벌크 모드`라 부르지만 실제 상품 INSERT는 여전히 1건씩 수행한다.

근거: `modules/_bundled/sirsoft-ecommerce/database/seeders/Sample/ProductSeeder.php:490`, `:608`, `:626`, `:692`, `:1208`.

## 권장 생성 단계

| 단계 | 처리 |
|---|---|
| planning | 예상 행 수, 배치 수, 이미지 저장량, 분류 분포 계산 |
| image_pool | 사진 100개를 480x480 WebP로 준비하고 이커머스 모듈 스토리지에 저장 |
| categories | 2~3단계 분류 트리 생성, `depth/path` 검증 |
| brands | 선택 옵션으로 0~100개 브랜드 생성 |
| products | 상품 배치마다 상품·기본옵션·분류피벗·이미지행을 함께 생성 |
| verifying | 실제 개수, 누락 옵션, 누락 대표 분류, 깨진 이미지 경로 표본 검사 |
| completed | 처리량, 소요시간, DB 행 수, 이미지 저장량 기록 |

## 상품 배치 처리

상품 500건 기준 한 번의 처리 순서는 다음과 같다.

1. seed와 순번으로 상품 데이터 500건을 메모리에서 만든다.
2. `BMJ{job_id}-{sequence}` 형식의 고유 `product_code`로 상품을 bulk insert 한다.
3. 방금 사용한 product code 500개로 ID를 다시 조회한다. auto-increment 연속 범위는 신뢰하지 않는다.
4. 기본 옵션 500건, 대표 분류 피벗 500건, 이미지 행 약 475~650건을 각각 bulk insert 한다.
5. 이 묶음만 트랜잭션으로 커밋한다.
6. 진행률과 heartbeat를 저장하고 중단 플래그를 다시 확인한다.

`product_code`, 이미지 hash, 옵션 코드는 job UUID와 sequence에서 결정적으로 생성한다. 같은 seed로 재실행할 때 내용과 분포는 같고, job ID가 달라 기존 데이터와 충돌하지 않는다.

## 이미지 전략

### 기본: shared pool

- 원격 사진은 최초 100장만 받는다. URL은 코드에 고정해 SSRF 입력을 만들지 않는다.
- 다운로드 직후 480x480 WebP 품질 60~70으로 재인코딩한다.
- 네트워크 실패 시 GD로 만든 로컬 대체 이미지를 사용해 작업 자체는 계속한다.
- 100장 전체를 메모리에 쌓지 않고 10장 단위로 내려받아 즉시 스토리지에 쓴다.
- 각 상품 이미지 행은 고유 hash를 갖되 실제 `path`는 job 전용 100개 풀 파일 중 하나를 가리킨다.
- 기본 이미지 분포는 상품 95%에 이미지 제공, 80%는 1장, 15%는 2장, 5%는 3장이다.

예상치는 25KB 사진 기준이다.

| 방식 | 20만 상품 물리 파일 | 대략적 파일 용량 | 용도 |
|---|---:|---:|---|
| shared pool | 100개 | 약 2.5MB | 기본, 목록·상세·이미지 API 부하 테스트 |
| per-product copy | 19만~25만개 | 약 4.8~6.3GB | 파일시스템·S3 쓰기까지 포함한 소규모 테스트 |

shared pool은 상품 이미지 한 건을 관리자에서 개별 삭제하면 공유 원본 파일까지 삭제할 수 있다. 따라서 이 모드는 벤치마크 데이터셋 전용 초기화만 지원하고, 개별 이미지 관리 테스트에는 `per-product copy` 모드를 사용해야 한다.

## 기본 UI 옵션

| 필드 | 권장값 |
|---|---|
| workload | 게시판 / 쇼핑몰 |
| total_products | 500, 1천, 5천, 1만, 5만, 10만, 20만 select |
| total_categories | 20, 50, 100, 200, 500 select |
| category_depth | 2 / 3 |
| category_distribution | 균등 / 편중 / 극단 편중 |
| total_brands | 0, 20, 50, 100 |
| image_pool_size | 20, 50, 100 |
| image_coverage | 0%, 50%, 90%, 95%, 100% |
| max_images_per_product | 1, 2, 3 |
| image_mode | shared pool / per-product copy |
| batch_size | 250, 500, 1000 |
| chunk_size | 2500, 5000, 10000 |
| seed / dry_run | 기존 기능 유지 |

분류 기본 구조는 10개 루트, 30개 중분류, 60개 소분류의 총 100개다. 상품은 소분류에 우선 배치하고, 기본 분포는 상위 10% 분류에 전체 상품의 약 60%가 몰리는 편중형으로 한다.

## 진행률과 Queue

- 웹 요청은 작업 등록과 조회만 수행한다.
- 기존 `RunGenerationJob`의 다음 chunk 재디스패치 구조는 재사용한다.
- 쇼핑몰 단계는 큰 트랜잭션으로 감싸지 않고 batch별 트랜잭션과 heartbeat를 사용한다.
- UI는 실행 중에만 2초 주기로 조회하고 `stopped/completed/failed`가 되면 즉시 polling을 종료한다.
- Queue 한 번이 5천 상품을 처리하더라도 500건마다 진행률이 DB에 커밋되므로 화면에서 연속 증가를 확인할 수 있다.
- 중단은 최대 한 batch 뒤에 반영된다.

## 재개와 초기화

- 상품 식별: `product_code LIKE 'BMJ{job_id}-%'`
- 분류 식별: `slug LIKE 'bmj-{job_id}-%'`
- 이미지 풀: `images/benchmark/job-{job_id}/pool/`
- 피벗과 옵션은 deterministic key와 `insertOrIgnore/upsert`로 재개 시 중복을 막는다.
- 초기화는 상품 ID를 1000개씩 읽어 관련 행과 상품을 제거한 뒤 분류를 depth 역순으로 제거한다.
- 주문 이력이 생긴 더미 상품은 자동 삭제하지 않는다. 초기화 시작 전 `ecommerce_order_options` 참조를 검사하고 해당 job을 명시적으로 차단한다.
- 다른 일반 상품, 분류, 이미지 폴더는 prefix가 다르므로 건드리지 않는다.

## 변경 대상

원본 `sirsoft-ecommerce`에는 변경이 없다. 변경은 `sirsoft-benchmark`와 벤치마크 전용 마이그레이션에 한정한다.

### 주요 수정 파일

- `modules/_bundled/sirsoft-benchmark/module.json`: ecommerce 1.0.3 의존성, 0.2.0 버전
- `modules/_bundled/sirsoft-benchmark/src/Enums/GenerationStage.php`: 쇼핑몰 단계 추가
- `modules/_bundled/sirsoft-benchmark/src/Services/GenerationJobService.php`: workload별 옵션·계획·dispatch
- `modules/_bundled/sirsoft-benchmark/src/Services/DummyDataGenerationService.php`: board/commerce 실행 분기
- `modules/_bundled/sirsoft-benchmark/src/Services/Support/ProgressReporter.php`: workload별 가중치
- `modules/_bundled/sirsoft-benchmark/src/Services/DummyDataResetService.php`: commerce 초기화 분기
- `modules/_bundled/sirsoft-benchmark/src/Http/Controllers/Admin/GenerationJobController.php`: commerce 설정·통계 응답
- `modules/_bundled/sirsoft-benchmark/resources/layouts/admin/admin_benchmark_dashboard.json`: 게시판/쇼핑몰 탭과 필드

### 주요 신규 파일

- `CommerceDatasetPlanner`
- `CommerceGenerationService`
- `CategoryGenerator`
- `BrandGenerator`
- `ProductGenerator`
- `ProductOptionGenerator`
- `ProductImageGenerator`
- `CommerceImagePoolService`
- `CommerceDatasetResetService`
- 상품명·설명·분류명용 소형 로컬 사전 JSON
- workload와 commerce 카운터를 추가하는 generation_jobs 마이그레이션

## 성능상 핵심 주의점

- `ecommerce_products`는 일반 인덱스 외에 name/description FULLTEXT 인덱스도 있어 INSERT가 게시글보다 무겁다.
- 20만 상품 기본 구성은 상품 20만 + 옵션 20만 + 분류 피벗 20만 이상 + 이미지 약 19만~25만으로 총 80만 행 전후다.
- 공개 상품 목록은 length-aware `paginate()`, 이미지·분류·브랜드 eager load, 리뷰 count/avg를 수행한다. 더미 생성 후 첫 페이지·깊은 페이지·분류 필터를 따로 측정해야 한다.
- 분류 트리는 depth별 재귀 조회와 `withCount('products')`를 사용한다. 편중 분류 20만 건에서 별도 병목이 나올 가능성이 있다.
- 이미지 요청은 hash 조회 후 PHP가 모듈 스토리지 파일을 스트리밍한다. 상품 DB 테스트와 이미지 API 동시 부하 테스트를 분리해야 원인을 구분할 수 있다.
- 벤치마크 목적상 원본 인덱스 비활성화나 FULLTEXT 제거는 기본 생성 과정에서 하지 않는다.

## 구현 난이도와 예상 기간

기존 Queue·상태·중단·로그 구조가 있어 처음부터 만드는 작업은 아니다. 다만 옵션 정합성, 이미지 스토리지, 재개·초기화까지 포함하면 난이도는 중상이다.

| 범위 | 예상 |
|---|---:|
| 분류·상품·기본옵션·피벗 bulk 생성 | 1~2일 |
| 이미지 풀·스토리지·초기화 | 1일 |
| 관리자 UI·진행률·dry-run·테스트 | 1일 |
| 스테이징 20만 건 생성/초기화/성능 검증 | 1일 |

동작 초안은 3일 안팎, 20만 건 생성과 안전한 초기화까지 검증된 1차 버전은 4~5일이 현실적이다. 주문·리뷰·문의 더미는 이번 범위에서 제외하고 후속 단계로 분리한다.

## 완료 기준

- 기존 일반 상품과 분류를 보존한 채 500/1만/20만 상품 생성 성공
- 모든 생성 상품에 대표 분류, 기본 옵션, 정상 응답하는 대표 이미지 존재
- 같은 seed의 이름·가격·분류·이미지 분포 재현
- 500건 이하 간격으로 진행률 상승, 중단 요청 1 batch 이내 반영
- 실패 후 재개 시 상품·옵션·이미지 중복 없음
- 초기화 후 해당 job 데이터와 이미지 풀만 0건, 기존 데이터 변화 없음
- 상품 목록, 상품 상세, 장바구니 추가, 이미지 API 200 smoke test 통과
