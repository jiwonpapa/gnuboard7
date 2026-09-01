# [제안] Laravel 13 코어 전환을 검토하면 좋겠습니다

## 결론

Laravel 12는 이미 일반 버그 수정 지원이 끝났고, 보안 업데이트도 **2027년 2월 24일** 종료됩니다. 보안 지원 종료 직전에 서두르기보다, 그누보드7 코어의 Laravel 13 전환을 공식 로드맵에 포함해 호환성과 업데이트 절차를 함께 검증하면 좋겠습니다.

근거: [Laravel 공식 지원 정책](https://laravel.com/docs/12.x/releases#support-policy)

## 코어에서 필요한 변경

- 실행 조건: PHP `^8.3`, `laravel/framework ^13.0`
- 연관 패키지: Tinker 3, Boost 2, PHPUnit 12 및 `composer.lock` 갱신
- 결제·본인인증 콜백의 CSRF 미들웨어 이름 변경 반영
  - `ValidateCsrfToken` → `PreventRequestForgery`
- G7 확장 `db:seed` 명령을 Laravel 13의 `$signature` 방식으로 전환
- 기존 로그인 세션과 모델·컬렉션 캐시를 보존하도록 세션·캐시 직렬화 정책 명시
- PHPUnit 12의 Attribute 기반 데이터 공급자·별도 프로세스 실행 방식 반영
- 웹 설치기·문서·PHP 실행 파일 탐색 기준을 PHP 8.3 이상으로 상향
- 영향받는 번들 결제·본인인증 플러그인의 버전과 `requires.g7_version` 동기화
- 코어 파일과 `vendor` 교체 후 마이그레이션을 **새 PHP 프로세스**에서 실행
  - 기존 프로세스를 재사용하면 Laravel 12의 DB 연결 객체와 Laravel 13의 Migrator가 섞여 `MySqlConnection::hasDirectConnection()` 오류가 발생할 수 있음

## 완료 기준

- 개발 의존성 없는 깨끗한 `composer install --no-dev` 및 플랫폼 검사 통과
- 전체 PHP 회귀 테스트와 프론트엔드 빌드 통과
- config·route·event 캐시 재생성 통과
- 현재 공식 G7 코어 → Laravel 13 기반 차기 코어의 업데이트·롤백을 실제 설치 환경에서 검증
- 페이지빌더 등 활성 커스텀 확장이 보존되고 주요 공개 화면·API가 정상 응답

## 제안 일정

보안 지원 종료 직전의 긴급 전환을 피하도록 **2026년 안에 전환 범위와 검증 계획을 확정**하는 방향을 제안합니다.
