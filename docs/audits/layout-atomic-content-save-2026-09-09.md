# 레이아웃 본문 원자 저장 회귀 수정

2026-09-09. 레이아웃 데이터 설치 연결을 위한 승인된 코어 변경입니다.

- 기존 `updateContent(id, content, newLockVersion)` 시그니처를 유지하고, 트랜잭션의 행 잠금 안에서 `newLockVersion - 1`과 현재 값을 비교합니다. 오래된 저장은 기존 ConcurrentModificationException으로 거부합니다. Model 저장 경로의 casts·timestamps·이벤트를 유지합니다.
- LayoutService는 본문·lock_version·최초 baseline·새 이력을 하나의 트랜잭션으로 처리합니다. 이력 실패 시 본문과 이미 기록한 baseline도 롤백합니다. 성공 뒤 기존 캐시 무효화·after 훅을 수행합니다.
- 전체 버전 복원도 같은 행을 잠그고 extends와 lock_version을 갱신합니다. 복원 이전 revision으로 열린 편집기가 복원 결과를 덮어쓸 수 없습니다. 복원 API 자체는 기존 전체 복원 의미를 유지하며 슬롯별 조건부 복원을 새로 제공하지 않습니다.

## 실제 검사

전용 Docker PHP 8.3.33 / MySQL 8.4의 격리 G7 복사본에서 실행했습니다. 개발·운영 DB는 사용하지 않았습니다.

```sh
php vendor/bin/phpunit tests/Feature/Api/Admin/LayoutControllerEditorSaveTest.php tests/Feature/Api/Admin/LayoutVersionIntegrationTest.php tests/Unit/Repositories/LayoutVersionRepositoryTest.php tests/Feature/Api/Admin/LayoutAtomicSaveTest.php tests/Feature/Api/Admin/LayoutConcurrentSaveTest.php --no-coverage
```

결과: **51 tests, 225 assertions 통과**. 새 회귀 5개/24 assertions를 포함합니다.

수정 전 확인: 오래된 repository 저장의 덮어쓰기, 이력 실패 후 본문 잔존, 복원 시 revision 미증가가 각각 실패했습니다. 두 독립 PHP 프로세스가 같은 revision을 읽고 명시적 barrier 후 저장하는 검사도 원본 repository에서는 둘 다 성공하여 실패했고 수정 후 한 건 성공/한 건 충돌로 통과했습니다. sleep에 기대지 않습니다.

기존 공개 메서드 시그니처·HTTP 응답 계약은 유지합니다. 번들 확장의 새 API 의존은 추가하지 않아 버전 제약 동기화 대상이 없습니다. 신규 회귀/시나리오와 수정 PHP 파일의 Pint를 확인했습니다. G7 기존 대형 Service의 본문 저장 구간만 트랜잭션으로 감쌌으며 범용 파일 분리는 하지 않았습니다.

이 결과는 template_layouts의 해당 저장/버전 복원 경로에 한합니다. template_layout_extensions, 확장 설치/업데이트의 레이아웃 동기화, 설치 모듈의 메뉴·홈 전체 실행 및 고객 슬롯 복원 완료를 뜻하지 않습니다. 코어 릴리스·배포는 수행하지 않았습니다.
