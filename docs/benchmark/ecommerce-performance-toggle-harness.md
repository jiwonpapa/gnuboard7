# 쇼핑몰 성능 패치 온오프 하네스

## 목적

공식 7.0.4 원본과 쇼핑몰 성능 패치를 같은 스테이징 데이터에서 반복 비교합니다. 원본 파일을 Git 기준으로 다시 배포하므로 단순 환경변수만 끄는 방식보다 비교 경계가 명확합니다.

## 명령

```bash
# 개선 코드 + 인덱스 적용
scripts/benchmark/ecommerce-performance-toggle.sh on

# 공식 7.0.4 코드 + 인덱스 invisible
scripts/benchmark/ecommerce-performance-toggle.sh off

# 소스, 런타임, 인덱스, 활성 모듈 동기화 상태
scripts/benchmark/ecommerce-performance-toggle.sh status

# 공식 코드 복구 + 벤치마크 인덱스 삭제
scripts/benchmark/ecommerce-performance-toggle.sh restore-original --yes
```

모든 전환은 변경 전 파일을 `/home/g7devops/backups/ecommerce-performance-harness`에 보관하고, 번들/활성 모듈과 번들/활성 템플릿을 함께 동기화합니다. optimized 소스는 작업 디렉터리가 아니라 검토·커밋된 Git ref(기본 `HEAD`)에서 생성합니다. 전환 후 `config`, `route`, `view`, `hooks` 캐시를 재생성해 실제 production 조건을 유지합니다.

전체 또는 공통·게시판과 조합된 전환에는 `scripts/benchmark/g7-performance-toggle.sh`를 사용합니다. 통합 하네스는 세 영역에 하나의 원격 lock을 적용하고 캐시 재생성과 PHP-FPM reload를 한 번만 실행합니다.

## 패치 파일

| 영역 | 파일 | 핵심 변경 |
|---|---|---|
| 토글 | `config/benchmark.php` | `G7_ECOMMERCE_PERFORMANCE_VARIANT` 분기 |
| 배포 | `scripts/benchmark/ecommerce-performance-toggle.sh` | `on/off/status/restore-original` |
| 목록·검색 SQL | `modules/_bundled/sirsoft-ecommerce/src/Repositories/ProductRepository.php` | ID 우선 페이지 조회, 검색 ID UNION의 DB 내부 처리, 인기상품 집계 변경 |
| 분류 | `modules/_bundled/sirsoft-ecommerce/src/Models/Category.php` | 평면 일괄 조회 후 트리 조립, breadcrumb 조상 일괄 조회 |
| 캐시 | `modules/_bundled/sirsoft-ecommerce/src/Services/CategoryService.php` | 공개 분류 트리 60초 캐시 |
| 캐시 | `modules/_bundled/sirsoft-ecommerce/src/Services/ProductService.php` | 인기·신상품 30초 캐시 |
| 직렬화 | `modules/_bundled/sirsoft-ecommerce/src/Models/Product.php` | eager-loaded 대표 이미지 재사용 |
| 목록 컬렉션 | `modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductCollection.php` | 컬렉션과 행이 같은 Request의 권한·정렬 문맥 재사용 |
| 상품 직렬화 | `modules/_bundled/sirsoft-ecommerce/src/Http/Resources/ProductListResource.php` | 동일 요청의 권한·가격 변환 재사용, breadcrumb 중복 계산 제거 |
| 분류 직렬화 | `modules/_bundled/sirsoft-ecommerce/src/Http/Resources/PublicCategoryResource.php` | 재귀 ResourceCollection 없이 동일 트리 배열 조립 |
| API | `modules/_bundled/sirsoft-ecommerce/src/Http/Controllers/Public/ProductController.php` | storefront 통합 응답과 optimized 분류 fast path |
| 라우트 | `modules/_bundled/sirsoft-ecommerce/src/routes/api.php` | storefront 엔드포인트 |
| 목록 UI | `templates/_bundled/sirsoft-basic/layouts/shop/index.json` | 첫 진입 API 5개에서 2개로 축소 |
| 상세 UI | `templates/_bundled/sirsoft-basic/layouts/shop/show.json` | 리뷰·문의 탭 지연 조회 |
| 인덱스 | `modules/_bundled/sirsoft-benchmark/database/migrations/2026_07_15_000004_add_ecommerce_storefront_indexes.php` | 벤치마크 복합 인덱스 |

## 인덱스

| 테이블 | 인덱스 | 컬럼 |
|---|---|---|
| `g7_ecommerce_products` | `idx_ecommerce_products_public_latest` | `display_status, deleted_at, created_at, id` |
| `g7_ecommerce_products` | `idx_ecommerce_products_public_price` | `display_status, deleted_at, selling_price, id` |
| `g7_ecommerce_order_options` | `idx_ecommerce_order_options_recent_sales` | `created_at, product_id, quantity` |

## 남은 한계

- 전체 건수 COUNT와 OFFSET 페이지네이션은 유지됩니다. 상품 수가 크게 늘면 cursor 또는 집계 카운터가 필요합니다.
- 인기상품은 30초 캐시가 만료되는 첫 요청에서 집계 비용이 발생합니다. 운영 규모에서는 일별 판매 집계 테이블이 적합합니다.
- storefront 최종 payload 전체 캐시는 통화·언어·배송국가·회원 권한별 무효화 계약이 확정되지 않아 적용하지 않았습니다.
- 2 vCPU, 10 VU에서 CPU busy 평균이 목록 78.87%, 상세 76.31%라 초기 운영은 가능하지만 고부하 여유는 제한적입니다.
