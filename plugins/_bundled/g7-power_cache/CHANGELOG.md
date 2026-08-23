# Changelog

## [0.2.0] - 2026-08-23

### Added

- 비회원 read 권한을 원본 미들웨어와 같은 `GuestRoleResolver`로 선검증하는 공개 게시판 목록 캐시
- 페이지 1~3, `per_page` 최대 50의 저카디널리티 hot-list 허용 정책
- PC/모바일 페이지 크기 분리 키와 상대시간·조회수 표시의 최대 60초 시계 버킷
- 게시판·글·댓글·첨부·권한·작성자 변경의 동기식 `board:all` 세대 무효화

### Changed

- 게시판 시계 버킷의 폐기 키는 10분 이내 회수하도록 정책별 보존시간을 적용
- 캐시 키 포맷을 `guest-api-v2`로 상향

## [0.1.0] - 2026-08-23

### Added

- 비회원 공개 API의 observe/active/bypass 실행 모드
- 페이지 상세 및 쇼핑몰 카테고리 공개 API의 보수적 허용목록
- 세대 벡터 검증, 분산 fill lock, 응답 저장 안전성 검사
- 캐시 HIT 직전 허용 헤더·개행·본문 크기·scope 저장물 재검증
- 카테고리 공개 응답 필터가 등록된 환경의 보수적 캐시 우회
- 운영 모드·저장소·락·복구 설정의 공개 frontend config 비노출
- 트랜잭션 아웃박스와 장애 복구 장벽
- 정상 HIT의 DB state 조회를 제거하는 전용 저장소 runtime snapshot과 커밋 전 emergency barrier
- 페이지·카테고리·상품·코어 표현 계층 변경 훅 무효화
- 모듈/플러그인 설정 초기화, 언어팩, 확장 제거·레이아웃 새로고침 훅의 site 무효화
- doctor/status/mode/purge/reconcile 운영 명령
- 적용 완료 아웃박스 및 file 저장소 만료 파일 일일 GC와 `power-cache:gc` 명령

### Compatibility

- Gnuboard7 7.0.8 이상
- 코어 공개 API를 변경하지 않는 독립 플러그인 구현
