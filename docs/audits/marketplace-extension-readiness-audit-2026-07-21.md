# [P0][아키텍처] 마켓플레이스 전 코어 무수정 확장 API 확정 필요

> **결론**
> 그누보드7이 모듈·플러그인 마켓플레이스를 운영하려면, 제3자 개발자가 코어·기본 모듈·템플릿을 수정하지 않고 제품을 설치·배포할 수 있어야 합니다. 현재는 패키지를 분리해 설치하는 기반은 있지만, 게시판·쇼핑몰·템플릿이 서로의 구체 구현과 URL·DB 구조를 직접 아는 부분이 남아 있습니다. 특히 업로더·썸네일·이미지 최적화처럼 사이트 전체에 적용돼야 하는 플러그인은 설치만으로 모든 화면과 모듈을 바꿀 수 없습니다. **마켓 화면보다 장기 호환되는 코어 확장 API와 성능 기준을 먼저 확정해야 합니다.**

| 항목 | 판정 |
|---|---|
| 우선순위 | **P0 — 마켓 개발 전 최우선** |
| 현재 상태 | 독립 모듈 개발은 가능하지만 기존 기능의 설치형 교체는 미준비 |
| 핵심 위험 | 제3자 개발자가 모듈·템플릿별 패치를 떠안아야 함 |
| 제품 영향 | 플러그인 공급 부족, 업데이트 호환성 저하, 마켓 신뢰 하락 |
| 감사 기준 | `fcaacad8d16d47a8b5bcee65990869992de0a0d8` · 정적 코드 검토 |

관리자 모듈·플러그인·템플릿 화면에 비활성화된 `marketplace_button`이 존재하므로, 본 이슈는 제3자 마켓플레이스 도입 계획을 전제로 합니다. [`admin_plugin_list.json:260-263`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/templates/_bundled/sirsoft-admin_basic/layouts/admin_plugin_list.json#L260-L263)

## 이 판단이 맞는가

**대체로 맞습니다.** 마켓플레이스는 판매 화면이 아니라 개발자 공급망입니다. 개발자가 하나의 공개 API만 구현해 여러 사이트에 배포할 수 있어야 상품이 쌓입니다. 반대로 게시판·쇼핑몰·템플릿마다 별도 수정이 필요하면 개발·테스트·고객지원 비용이 반복되고, 코어 업데이트마다 호환성 위험이 커집니다. 이 구조에서는 무료 플러그인도 유지하기 어렵고 상용 플러그인은 더 만들기 어렵습니다.

다만 세 가지는 구분해야 합니다.

- 자체 API·UI를 모두 가진 독립 모듈의 수동 배포는 현재도 가능합니다. 이 이슈가 P0라는 판정은 미디어·에디터·결제처럼 **기존 기능을 설치만으로 확장·교체하는 마켓**을 목표로 할 때 적용됩니다.
- `API 확정`은 영구 동결이 아니라 공개 범위, 버전 규칙, 호환 기간, 폐기 절차와 자동 호환성 테스트를 확정한다는 뜻입니다.
- 전면 성능 튜닝 전체를 최고 P0로 볼 근거는 아직 부족합니다. 대신 **성능 기준선·허용 예산·회귀 차단은 P0로 즉시 만들고, 확장 API 설계·기본 모듈 전환과 병행해 측정된 병목만 최적화**해야 합니다. 곧 교체할 구체 구현을 먼저 튜닝하면 재작업이 발생합니다.

따라서 권장 순서는 다음과 같습니다.

1. 코어 확장 API와 모듈 경계를 확정합니다.
2. 설치·활성화·비활성화·업데이트와 패키지 신뢰 기준을 확정합니다.
3. 게시판·쇼핑몰·기본 템플릿도 그 API만 사용하도록 전환합니다.
4. 같은 서버·데이터·부하 조건의 성능 기준과 허용 퇴행 범위를 CI에 고정합니다.
5. 실제 외부 플러그인으로 코어 무수정 전체 흐름을 검증합니다.
6. 그 뒤 마켓 카탈로그·구매·배포 기능을 엽니다.

## 현재 가장 심각한 문제

### 1. 분리된 패키지와 교체 가능한 모듈은 다르다

모듈·플러그인 디렉터리가 분리돼 있다는 사실만으로 추상화가 끝난 것은 아닙니다. 기본 사용자 템플릿은 `sirsoft-board`, `sirsoft-ecommerce`, `sirsoft-page`를 필수 모듈로 직접 지정합니다.

- [`sirsoft-basic/template.json:25-34`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/templates/_bundled/sirsoft-basic/template.json#L25-L34)

이커머스 모듈은 manifest에 다른 모듈 의존성을 선언하지 않았지만, 상품문의 Listener는 `sirsoft-board.post.after_delete` 훅을 직접 구독합니다. 이는 모듈 간 숨은 의존입니다. [`module.json:12-17`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/modules/_bundled/sirsoft-ecommerce/module.json#L12-L17), [`ProductInquiryBoardListener.php:36-47`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/modules/_bundled/sirsoft-ecommerce/src/Listeners/ProductInquiryBoardListener.php#L36-L47)

결제 플러그인도 공통 주문·결제 API 대신 이커머스 주문·결제 테이블을 직접 조회합니다.

- [`sirsoft-pay_kginicis/AdminTransactionController.php:48-54`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/plugins/_bundled/sirsoft-pay_kginicis/src/Controllers/AdminTransactionController.php#L48-L54)

따라서 별도 쇼핑몰 모듈을 만들어도 기본 템플릿과 기존 결제 플러그인이 자동으로 새 쇼핑몰을 사용하지 않습니다. 모듈 파일은 분리돼 있지만 생태계 차원의 교체 API는 부족합니다.

특정 쇼핑몰 전용 결제 플러그인이 해당 쇼핑몰의 **공개 API**에 의존하는 것은 정상입니다. 심각한 문제는 내부 Model·DB 테이블·고정 URL을 직접 사용하거나, 기본 템플릿이 여러 모듈의 구체 식별자를 필수로 요구하는 것입니다.

### 2. 실제 업로더·썸네일 서버가 설치만으로 전체 적용되지 않는다

외부 업로더·썸네일 서버를 플러그인으로 만들어도 게시판, 페이지, 상품, 카테고리, 리뷰가 서로 다른 업로드 서비스와 훅을 사용합니다.

- 코어 첨부: [`AttachmentService.php:47-68`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/app/Services/AttachmentService.php#L47-L68)
- 게시판 첨부: [`sirsoft-board/AttachmentService.php:51-76`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/modules/_bundled/sirsoft-board/src/Services/AttachmentService.php#L51-L76)
- 상품 이미지: [`ProductImageService.php:54-86`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/modules/_bundled/sirsoft-ecommerce/src/Services/ProductImageService.php#L54-L86)
- 상품 리뷰 이미지: [`ProductReviewImageService.php:48-75`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/modules/_bundled/sirsoft-ecommerce/src/Services/ProductReviewImageService.php#L48-L75)

화면도 게시판·쇼핑몰 업로드 URL을 직접 지정합니다.

- 게시판 작성 화면: [`_post_form.json:660-682`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/templates/_bundled/sirsoft-basic/layouts/partials/board/form/_post_form.json#L660-L682)
- 상품 이미지 화면: [`_partial_image_upload.json:80-103`](https://github.com/jiwonpapa/gnuboard7/blob/fcaacad8d16d47a8b5bcee65990869992de0a0d8/modules/_bundled/sirsoft-ecommerce/resources/layouts/admin/partials/admin_ecommerce_product_form/_partial_image_upload.json#L80-L103)

이 때문에 코어 파일을 수정하지 않더라도 기본 템플릿과 게시판·쇼핑몰 모듈을 수정하거나, 각 내부 구조에 맞춘 별도 패치를 계속 유지해야 합니다. **마켓에서 기대하는 “설치 → Provider 선택 → 사이트 전체 적용”이 아닙니다.**

### 3. 기본 모듈이 공개 API를 우회하면 추상화는 작동하지 않는다

코어에 Provider 인터페이스만 추가해서는 부족합니다. 게시판·쇼핑몰·페이지·기본 템플릿이 파일 저장, 이미지 URL, 주문, 결제를 직접 처리하면 플러그인은 다시 각 구현을 따라가야 합니다.

**문제는 훅의 개수가 아니라, 코어·모듈·템플릿이 동일한 공개 API를 반드시 사용하도록 보장되어 있지 않다는 점입니다.**

필요한 구조는 다음과 같습니다.

`제3자 플러그인 → 코어 공개 확장 API → 게시판·페이지·쇼핑몰·모든 템플릿`

코어와 모든 기본 모듈이 같은 API를 의무적으로 사용하고, 이를 우회하는 직접 참조를 CI에서 차단해야 합니다.

## WordPress 유명 플러그인을 G7에 적용한다면

| 대표 사례 | WordPress | 현재 G7 판정 |
|---|---|---|
| [Smush 이미지 최적화](https://wordpress.org/plugins/wp-smushit/) | 공통 이미지 처리 Filter와 Attachment API를 통해 게시물·테마·WooCommerce에 적용 | 하나의 MediaProvider만으로 게시판·페이지·상품·리뷰·템플릿 전체 교체 불가 |
| [WPBakery 페이지 빌더](https://codecanyon.net/item/wpbakery-page-builder-for-wordpress/242431) | 플러그인 설치로 편집·출력 기능 확장 | `html_editor` 교체점은 있으나 직접 `HtmlEditor/HtmlContent`를 쓰는 화면까지 강제하지 못해 부분 가능 |
| [Stripe for WooCommerce](https://woocommerce.com/products/stripe/) | WooCommerce 주문·결제 흐름에 플러그인으로 연결 | 번들 쇼핑몰 안의 결제수단 추가는 가능하지만, 기존 PG가 이커머스 구현·테이블에 직접 의존해 대체 쇼핑몰에서는 재사용 어려움 |
| [Bookly 예약](https://codecanyon.net/item/bookly-booking-plugin-responsive-appointment-booking-and-scheduling/7226091) | 예약 기능을 독립 플러그인으로 설치하고 결제·알림과 연동 | 독립 예약 모듈은 만들 수 있으나 공통 예약·결제·콘텐츠 API가 없어 통합마다 별도 연결 필요 |
| [Yoast SEO](https://wordpress.org/plugins/wordpress-seo/) | 공통 메타·사이트맵 훅으로 사이트 전체 확장 | G7은 `SeoRendererInterface`, `SitemapContributorInterface`가 있어 상대적으로 준비된 영역 |

WordPress의 핵심은 플러그인 수가 아니라 **코어와 WooCommerce·테마가 같은 공통 API를 사용한다는 점**입니다. G7도 기본 모듈부터 이 원칙을 지켜야 제3자 플러그인이 설치만으로 작동합니다.

위 비교는 각 제품의 공식 설치 흐름 기준입니다. 개별 테마나 다른 플러그인의 비표준 구현까지 항상 호환된다는 뜻은 아닙니다.

## 왜 P0이며 ROI가 높은가

- 하나의 공통 API가 미디어, 에디터, 예약, 결제, SEO, 자동화 등 여러 상품 카테고리를 동시에 엽니다.
- 지금 경계를 확정하면 기본 모듈 수가 늘기 전에 직접 결합을 제거할 수 있습니다. 늦을수록 이전 비용과 호환성 부채가 커집니다.
- 개발자 한 명이 여러 고객에게 같은 패키지를 판매할 수 있어야 공급자가 붙습니다.
- 사용자는 코어 업데이트와 플러그인 업데이트를 독립적으로 할 수 있어야 유료 상품을 신뢰합니다.
- 마켓 UI를 먼저 만들어도 설치 후 충돌하거나 소스 수정이 필요하면 상품 공급과 재구매가 생기지 않습니다.

이 작업은 단일 기능 추가가 아니라 **외부 개발자 수와 제품 출시 속도를 함께 늘리는 기반 투자**입니다. 마켓플레이스 계획이 있다면 가장 높은 ROI의 선행 과제 중 하나로 보는 것이 타당합니다.

## P0에서 확정할 최소 범위

1. **확장 API 정책**
   - 공개 API 범위, 버전 규칙, 호환 기간, 폐기 절차
   - 확장이 제공·요구하는 기능과 기본 Provider 선택 방식
   - 확장 개발 문서에서 코어·기본 모듈·템플릿 직접 수정을 요구하지 않는 원칙

2. **우선 공개 API**
   - 미디어: 업로드, 변환, 썸네일, URL, 기존 이미지 재생성, 업로더 UI
   - 콘텐츠: 게시판 읽기·쓰기·렌더링
   - 쇼핑몰: 상품, 주문, 결제, 환불
   - 편집기·폼·블록 등록
   - 예약 실행·예약 게시·작업 재시도

3. **기본 모듈 전환**
   - 게시판·쇼핑몰·페이지·기본 템플릿도 위 API만 사용
   - 다른 모듈의 내부 Model·Service·테이블·URL 직접 참조 금지
   - 꼭 필요한 결합은 별도 연결 플러그인으로 분리

4. **안전한 설치 수명주기**
   - 설치·활성화·비활성화·삭제·업데이트 상태를 모든 Route·Hook·Job에 동일 적용
   - 패키지 서명, 의존 버전, 업데이트 실패 복구

5. **호환성과 성능 자동 검증**
   - 과거 버전 플러그인 호환성 테스트
   - 모듈 조합별 설치·활성화·비활성화 테스트
   - 같은 서버·데이터·부하 조건의 응답시간·메모리 기준
   - 확장 API 도입 전후 성능 퇴행 차단

## 완료 기준

다음 시험을 통과하기 전에는 범용 마켓 준비 완료로 판정하지 않습니다.

- [ ] 외부 MediaProvider 하나를 설치하고 관리자에서 한 번 선택하면 코어·게시판·페이지·상품·리뷰의 업로드와 목록·상세 이미지가 모두 바뀝니다.
- [ ] 위 시험에서 코어·모듈·템플릿 수정이 0건입니다.
- [ ] 대체 게시판 모듈을 설치해도 기본 템플릿이 구체 모듈 ID 변경 없이 작동합니다.
- [ ] 대체 쇼핑몰 모듈에서도 기존 결제 플러그인이 공개 주문·결제 API만으로 작동합니다.
- [ ] 코어 업데이트 시 지원 중인 기존 플러그인의 호환성 테스트가 통과합니다.
- [ ] 비활성화된 플러그인의 Route·Hook·Job이 실행되지 않고, 의존 버전이 맞지 않는 패키지는 설치되지 않습니다.
- [ ] 확장 API를 거치는 주요 요청이 정한 성능 기준을 넘지 않습니다.
- [ ] CI가 다른 모듈의 내부 클래스·테이블·URL 직접 참조를 차단합니다.

## 최종 제안

**코어 확장 API 확정, 기본 모듈의 직접 결합 제거, 안전한 설치 수명주기를 마켓플레이스 선행 P0로 지정해야 합니다.** 성능은 전면 튜닝이 아니라 같은 P0 트랙에서 기준선·예산·회귀 차단을 먼저 만들고, 확인된 병목만 병행 개선해야 합니다. 이후 실제 업로더·썸네일 Provider를 기준 플러그인으로 만들어 코어·게시판·쇼핑몰·템플릿 수정 0건을 증명한 뒤 마켓 기능 개발로 넘어가는 순서가 적절합니다.
